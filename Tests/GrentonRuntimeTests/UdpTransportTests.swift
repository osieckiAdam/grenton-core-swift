import Testing
import Foundation
import Network
@testable import GrentonRuntime

/// Integration test of the real transports against UDP echo listeners on
/// the loopback interface. Protocol behaviour is covered by the FakeClu
/// suite; this verifies the transports themselves: connect, send, receive
/// on the socket's ephemeral port, close.
///
/// Real UDP means a datagram can, rarely, be dropped — every receive is
/// therefore bounded by a timeout so a drop fails the single test instead
/// of hanging the whole suite.
@Suite struct UdpTransportTests {

    /// Bounded receive: `nil` when nothing arrived within the deadline.
    func nextDatagram(
        from socket: any UdpSocket, within timeout: Duration = .seconds(3)
    ) async -> Data? {
        await withTaskGroup(of: Data?.self) { group in
            group.addTask {
                var iterator = socket.incoming.makeAsyncIterator()
                return await iterator.next()
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// UDP may (rarely, even on loopback) drop a datagram — retry the
    /// send a few times with a bounded receive before giving up.
    func exchange(
        _ message: Data, over socket: any UdpSocket, attempts: Int = 3
    ) async throws -> Data? {
        for _ in 0..<attempts {
            try await socket.send(message)
            if let received = await nextDatagram(from: socket, within: .seconds(2)) {
                return received
            }
        }
        return nil
    }

    final class EchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "grenton.test.echo")

        init() throws {
            listener = try NWListener(using: .udp, on: .any)
            listener.newConnectionHandler = { [queue] connection in
                connection.start(queue: queue)
                Self.pump(connection)
            }
        }

        static func pump(_ connection: NWConnection) {
            connection.receiveMessage { data, _, _, error in
                if let data, !data.isEmpty {
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
                if error == nil {
                    pump(connection)
                }
            }
        }

        func start() async throws -> Int {
            try await withCheckedThrowingContinuation { cont in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready:
                        if !resumed {
                            resumed = true
                            cont.resume(returning: Int(listener.port?.rawValue ?? 0))
                        }
                    case .waiting(let error), .failed(let error):
                        // .waiting included: an unresumed continuation here
                        // would hang the entire suite.
                        if !resumed {
                            resumed = true
                            cont.resume(throwing: error)
                        }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() {
            listener.cancel()
        }
    }

    @Test func sendsAndReceivesOverLoopback() async throws {
        let server = try EchoServer()
        let port = try await server.start()
        defer { server.stop() }

        let socket = try await NetworkUdpSocketFactory().open(host: "127.0.0.1", port: port)
        defer { socket.close() }

        let message = Data("grenton-transport-test".utf8)
        #expect(try await exchange(message, over: socket) == message)
    }

    // The contract CluSession relies on (Transport.swift): close() ends the
    // incoming stream, so a router task waiting on it finishes instead of
    // living on with the socket.
    @Test(arguments: [false, true])
    func closeEndsTheIncomingStream(anySource: Bool) async throws {
        let factory: any UdpSocketFactory = anySource ? AnySourceUdpSocketFactory() : NetworkUdpSocketFactory()
        let socket = try await factory.open(host: "127.0.0.1", port: 9)
        let reader = Task { () -> Bool in
            for await _ in socket.incoming {}
            return true
        }
        try await Task.sleep(for: .milliseconds(50))
        socket.close()
        let finished = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await reader.value }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(finished, "incoming did not end within 2 s of close()")
    }

    @Test func distinctSocketsGetDistinctLocalPorts() async throws {
        let server = try EchoServer()
        let port = try await server.start()
        defer { server.stop() }

        let factory = NetworkUdpSocketFactory()
        let first = try await factory.open(host: "127.0.0.1", port: port)
        let second = try await factory.open(host: "127.0.0.1", port: port)
        defer { first.close(); second.close() }

        // Send from both; each must receive its own echo — proving separate
        // local ports (the foundation of chunk routing, spec §5.4.2).
        #expect(try await exchange(Data("one".utf8), over: first) == Data("one".utf8))
        #expect(try await exchange(Data("two".utf8), over: second) == Data("two".utf8))
    }

    @Test(arguments: [0, -5, 70000])
    func rejectsInvalidPorts(port: Int) async {
        await #expect(throws: TransportError.invalidPort(port)) {
            _ = try await NetworkUdpSocketFactory().open(host: "127.0.0.1", port: port)
        }
    }

    /// Replies from a DIFFERENT local port than the one the request was
    /// sent to — a connected socket drops these; the listener-mode socket
    /// must receive them (spec §7.1 fallback for multi-homed CLUs).
    final class ForeignSourceEchoServer: @unchecked Sendable {
        private let listener: NWListener
        private let queue = DispatchQueue(label: "grenton.test.foreign-echo")
        // Diagnostics (test-only): what the server actually saw.
        static let diagLock = NSLock()
        nonisolated(unsafe) static var diag: [String] = []
        static func note(_ line: String) {
            diagLock.lock()
            diag.append(line)
            diagLock.unlock()
        }
        static func dumpDiag() -> String {
            diagLock.lock()
            defer { diagLock.unlock() }
            return diag.joined(separator: " | ")
        }

        init() throws {
            listener = try NWListener(using: .udp, on: .any)
            listener.newConnectionHandler = { [queue] inbound in
                Self.note("inbound from \(inbound.endpoint)")
                inbound.start(queue: queue)
                Self.pump(inbound, queue: queue)
            }
        }

        /// Re-arms after every datagram — the client retries lost
        /// exchanges, so every retry must get a fresh reply.
        /// The listener may represent an IPv4 peer as a mapped-IPv6
        /// endpoint (`::ffff:127.0.0.1`); replying to that form from a
        /// fresh connection silently goes nowhere. Normalize to plain
        /// IPv4 loopback + the peer's port.
        static func replyEndpoint(for inbound: NWConnection) -> NWEndpoint {
            if case .hostPort(_, let port) = inbound.endpoint {
                return .hostPort(host: "127.0.0.1", port: port)
            }
            return inbound.endpoint
        }

        static func pump(_ inbound: NWConnection, queue: DispatchQueue) {
            inbound.receiveMessage { data, _, _, error in
                if let data, !data.isEmpty {
                    // Reply from a FRESH ephemeral port. A raw BSD socket,
                    // not NWConnection: rapid per-reply NWConnections on
                    // loopback intermittently hit EADDRINUSE or stall in
                    // .preparing, which is exactly the flake this suite
                    // once had.
                    if case .hostPort(_, let port) = inbound.endpoint,
                       let reply = try? PosixUdpSocket(host: "127.0.0.1", port: port.rawValue) {
                        Self.note("got \(data.count)B, replying to port \(port)")
                        Task {
                            try? await reply.send(data)
                            reply.close()
                        }
                    } else {
                        Self.note("got \(data.count)B, cannot build reply socket")
                    }
                }
                if let error {
                    Self.note("inbound recv error \(error)")
                } else {
                    pump(inbound, queue: queue)
                }
            }
        }

        func start() async throws -> Int {
            try await withCheckedThrowingContinuation { cont in
                nonisolated(unsafe) var resumed = false
                listener.stateUpdateHandler = { [listener] state in
                    switch state {
                    case .ready:
                        if !resumed { resumed = true; cont.resume(returning: Int(listener.port?.rawValue ?? 0)) }
                    case .failed(let error):
                        if !resumed { resumed = true; cont.resume(throwing: error) }
                    default:
                        break
                    }
                }
                listener.start(queue: queue)
            }
        }

        func stop() { listener.cancel() }
    }

    @Test func anySourceModeReceivesFromForeignSourcePort() async throws {
        let server = try ForeignSourceEchoServer()
        let port = try await server.start()
        defer { server.stop() }

        let socket = try await AnySourceUdpSocketFactory().open(host: "127.0.0.1", port: port)
        defer { socket.close() }

        let message = Data("foreign-source-test".utf8)
        let received = try await exchange(message, over: socket)
        if received != message {
            Issue.record("foreign-source exchange failed; server diag: \(ForeignSourceEchoServer.dumpDiag())")
        }
        #expect(received == message)
    }

    @Test func anySourceModeAlsoReceivesDirectReplies() async throws {
        // Same-source replies (the normal case) must work in this mode too.
        let server = try EchoServer()
        let port = try await server.start()
        defer { server.stop() }

        let socket = try await AnySourceUdpSocketFactory().open(host: "127.0.0.1", port: port)
        defer { socket.close() }

        let message = Data("direct-reply-test".utf8)
        #expect(try await exchange(message, over: socket) == message)
    }
}
