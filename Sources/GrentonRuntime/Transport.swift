import Foundation
import Network

/// UDP transport boundary (spec §7.1). Each socket owns its own ephemeral
/// local port — the foundation of chunk-report routing — and delivers
/// incoming datagrams as a single-consumer stream read exclusively by the
/// session's router (Swift plan §4.3).
public protocol UdpSocket: Sendable {
    var incoming: AsyncStream<Data> { get }
    /// The bound local UDP port, once known (diagnostics). The CLU pushes
    /// unsolicited clientReports to the port a registration came from.
    var localPort: Int? { get }
    func send(_ datagram: Data) async throws
    func close()
}

public extension UdpSocket {
    var localPort: Int? { nil }
}

/// Opens the UDP connections to the CLUs. Supply your own only to change the transport.
public protocol UdpSocketFactory: Sendable {
    func open(host: String, port: Int) async throws -> any UdpSocket
}

func validatePort(_ port: Int) throws -> NWEndpoint.Port {
    guard (1...65535).contains(port), let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else {
        throw TransportError.invalidPort(port)
    }
    return nwPort
}

// MARK: - Connected-UDP mode (default)

// Default production factory: one connected `NWConnection` per socket.
// Connected UDP binds an ephemeral local port per connection and filters
// the sender to the peer (spec Δ §7.1). For multi-homed CLUs that report
// from a different source address, use `AnySourceUdpSocketFactory`.
/// The default transport: one connected UDP socket per connection, which only accepts datagrams from its CLU.
///
/// If a CLU answers from a different address than the one in the interface, use ``AnySourceUdpSocketFactory``.
public struct NetworkUdpSocketFactory: UdpSocketFactory {
    /// Upper bound on connection setup. A connection that never leaves
    /// `.preparing` would otherwise suspend the open forever; failing fast
    /// lets the session degrade and retry (spec §5.4.5).
    public var openTimeout: Duration

    public init(openTimeout: Duration = .seconds(10)) {
        self.openTimeout = openTimeout
    }

    public func open(host: String, port: Int) async throws -> any UdpSocket {
        let nwPort = try validatePort(port)
        let connection = NWConnection(
            host: NWEndpoint.Host(host), port: nwPort, using: .udp)
        return try await withThrowingTaskGroup(of: (any UdpSocket).self) { group in
            group.addTask {
                try await NetworkUdpSocket.start(connection)
            }
            group.addTask { [openTimeout] in
                try await Task.sleep(for: openTimeout)
                connection.cancel()   // resolves the start gate with .cancelled
                throw TransportError.connectionFailed("open timed out")
            }
            defer { group.cancelAll() }
            guard let socket = try await group.next() else {
                throw TransportError.connectionFailed("open produced no socket")
            }
            return socket
        }
    }
}

/// Resolves a state-handler continuation exactly once; `.waiting` counts
/// as failure (spec §5.4.5: fail fast, the session's ping loop retries)
/// and caller cancellation cancels the connection.
private final class ReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false

    func resolveOnce(_ body: () -> Void) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        body()
        return true
    }

    var isResolved: Bool {
        lock.lock()
        defer { lock.unlock() }
        return resumed
    }
}

public final class NetworkUdpSocket: UdpSocket, @unchecked Sendable {
    public let incoming: AsyncStream<Data>

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let incomingContinuation: AsyncStream<Data>.Continuation

    private init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue = queue
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.incomingContinuation = continuation
    }

    static func start(_ connection: NWConnection) async throws -> NetworkUdpSocket {
        let queue = DispatchQueue(label: "grenton.udp.socket")
        let socket = NetworkUdpSocket(connection: connection, queue: queue)
        let gate = ReadyGate()

        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                connection.stateUpdateHandler = { [weak socket] state in
                    switch state {
                    case .ready:
                        _ = gate.resolveOnce { cont.resume() }
                    case .waiting(let error):
                        // Fail fast instead of suspending indefinitely; the
                        // session treats this as degraded and retries.
                        let resolved = gate.resolveOnce {
                            cont.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                        }
                        if resolved { connection.cancel() }
                    case .failed(let error):
                        if !gate.resolveOnce({
                            cont.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                        }) {
                            socket?.incomingContinuation.finish()
                        }
                    case .cancelled:
                        if !gate.resolveOnce({
                            cont.resume(throwing: CancellationError())
                        }) {
                            socket?.incomingContinuation.finish()
                        }
                    default:
                        break
                    }
                }
                connection.start(queue: queue)
            }
        } onCancel: {
            // Triggers `.cancelled`, which resolves the gate if still open.
            connection.cancel()
        }

        socket.receiveNext()
        return socket
    }

    private func receiveNext() {
        connection.receiveMessage { [weak self] data, _, _, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                self.incomingContinuation.yield(data)
            }
            if error == nil {
                self.receiveNext()
            } else {
                self.incomingContinuation.finish()
            }
        }
    }

    public var localPort: Int? {
        if case .hostPort(_, let port)? = connection.currentPath?.localEndpoint {
            return Int(port.rawValue)
        }
        return nil
    }

    public func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
            connection.send(content: datagram, completion: .contentProcessed { error in
                if let error {
                    cont.resume(throwing: TransportError.connectionFailed(String(describing: error)))
                } else {
                    cont.resume()
                }
            })
        }
    }

    public func close() {
        connection.cancel()
        incomingContinuation.finish()
    }
}

// MARK: - Any-source mode (fallback, spec §7.1)

// Fallback transport for CLUs that answer or report from a different
// source address/port than the one registrations are sent to.
//
// Implementation note: a single UNCONNECTED BSD socket, not
// `NWListener` + connected `NWConnection` on a shared port — with
// SO_REUSEPORT the kernel distributes foreign-source datagrams between
// the two sockets nondeterministically, silently dropping the ones hashed
// to the connected socket. One unconnected socket receives every datagram
// addressed to its port and sends from that same port (the protocol
// requirement: reports return to the registration's source port).
/// A transport that accepts a CLU's answers from any address, for CLUs with more than one network address.
public struct AnySourceUdpSocketFactory: UdpSocketFactory {
    public init() {}

    public func open(host: String, port: Int) async throws -> any UdpSocket {
        _ = try validatePort(port)
        return try PosixUdpSocket(host: host, port: UInt16(port))
    }
}

public final class PosixUdpSocket: UdpSocket, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    public private(set) var localPort: Int?

    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let fileDescriptor: Int32
    private let peerAddress: sockaddr_in
    private let readSource: any DispatchSourceRead
    private let queue = DispatchQueue(label: "grenton.udp.posix")
    private let lock = NSLock()
    private var closed = false

    init(host: String, port: UInt16) throws {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else {
            throw TransportError.connectionFailed("socket(): errno \(errno)")
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)

        // Bind to an ephemeral port — the socket's identity for routing.
        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = 0
        local.sin_addr = in_addr(s_addr: INADDR_ANY)
        let bindResult = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            Darwin.close(fd)
            throw TransportError.connectionFailed("bind(): errno \(errno)")
        }

        var bound = sockaddr_in()
        var boundLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &boundLength)
            }
        }
        self.localPort = nameResult == 0 ? Int(UInt16(bigEndian: bound.sin_port)) : nil

        var peer = sockaddr_in()
        peer.sin_family = sa_family_t(AF_INET)
        peer.sin_port = port.bigEndian
        if inet_pton(AF_INET, host, &peer.sin_addr) != 1 {
            var hints = addrinfo()
            hints.ai_family = AF_INET
            hints.ai_socktype = SOCK_DGRAM
            var results: UnsafeMutablePointer<addrinfo>? = nil
            let status = getaddrinfo(host, nil, &hints, &results)
            defer { if let results { freeaddrinfo(results) } }
            guard status == 0,
                  let address = results?.pointee.ai_addr?
                      .withMemoryRebound(to: sockaddr_in.self, capacity: 1, { $0.pointee })
            else {
                Darwin.close(fd)
                throw TransportError.connectionFailed("cannot resolve host \(host)")
            }
            peer.sin_addr = address.sin_addr
        }
        self.peerAddress = peer
        self.fileDescriptor = fd

        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream(bufferingPolicy: .bufferingNewest(256)) { continuation = $0 }
        self.incomingContinuation = continuation

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        self.readSource = source
        source.setEventHandler { [weak self] in
            self?.drainReadableDatagrams()
        }
        source.setCancelHandler {
            Darwin.close(fd)
        }
        source.resume()
    }

    private func drainReadableDatagrams() {
        var buffer = [UInt8](repeating: 0, count: 65_535)
        while true {
            let received = recv(fileDescriptor, &buffer, buffer.count, 0)
            if received > 0 {
                incomingContinuation.yield(Data(buffer[0..<received]))
            } else {
                break   // EWOULDBLOCK or error — wait for the next event
            }
        }
    }

    private var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    public func send(_ datagram: Data) async throws {
        guard !isClosed else { throw TransportError.connectionFailed("closed") }

        var peer = peerAddress
        let sent = datagram.withUnsafeBytes { bytes in
            withUnsafePointer(to: &peer) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fileDescriptor, bytes.baseAddress, datagram.count, 0,
                           $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent == datagram.count else {
            throw TransportError.connectionFailed("sendto(): errno \(errno)")
        }
    }

    public func close() {
        lock.lock()
        guard !closed else {
            lock.unlock()
            return
        }
        closed = true
        lock.unlock()

        readSource.cancel()   // cancel handler closes the fd
        incomingContinuation.finish()
    }
}
