import Foundation
import GrentonModel
import GrentonRuntime

/// In-memory UDP socket pair: `send` delivers to the fake CLU, the fake
/// delivers responses back via `deliver`. One instance = one ephemeral
/// "port"; the session uses one per CLU and routes notifications by
/// subscription number (spec §5.4).
public final class InMemoryUdpSocket: UdpSocket, @unchecked Sendable {
    public let incoming: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    private let onSend: @Sendable (Data, InMemoryUdpSocket) async -> Void
    private let lock = NSLock()
    private var closed = false

    public init(onSend: @escaping @Sendable (Data, InMemoryUdpSocket) async -> Void) {
        var continuation: AsyncStream<Data>.Continuation!
        self.incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        self.onSend = onSend
    }

    public var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    public func send(_ datagram: Data) async throws {
        guard !isClosed else { throw TransportError.connectionFailed("closed") }
        await onSend(datagram, self)
    }

    public func deliver(_ datagram: Data) {
        guard !isClosed else { return }
        continuation.yield(datagram)
    }

    public func close() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }
}

public struct InMemoryUdpSocketFactory: UdpSocketFactory {
    public let fake: FakeClu
    public var failOpens: Bool = false
    /// Artificial open latency — cancellation-aware via Task.sleep, used
    /// by stop-during-open and concurrent-ping tests.
    public var openDelay: Duration? = nil

    public init(fake: FakeClu, failOpens: Bool = false, openDelay: Duration? = nil) {
        self.fake = fake
        self.failOpens = failOpens
        self.openDelay = openDelay
    }

    public func open(host: String, port: Int) async throws -> any UdpSocket {
        guard !failOpens else { throw TransportError.connectionFailed("test") }
        if let openDelay {
            try await Task.sleep(for: openDelay)
        }
        return await fake.openSocket()
    }
}

/// Protocol simulator per spec §9.4: answers pings, registrations, and
/// actions; can go silent per payload predicate; can emit unsolicited
/// clientReport notifications, carrying the registration's subscription
/// number, to the socket a registration came from.
public actor FakeClu {
    public struct Registration: Sendable {
        public let sessionId: Int
        public let keyCount: Int
        public let payload: String
        public let socket: InMemoryUdpSocket
    }

    public let cipher: AesCbcCipher
    public private(set) var receivedPayloads: [String] = []
    public private(set) var receivedMsgIds: [String] = []
    public private(set) var registrations: [Registration] = []
    /// Subscription numbers of every `clientDestroy` received, in order.
    public private(set) var destroyedNumbers: [Int] = []
    public private(set) var openedSockets: [InMemoryUdpSocket] = []

    /// When set, register replies carry this number instead of echoing the
    /// request's — the session must not check it (spec §5.3.2 pt 1).
    public var replySessionId: Int?

    public func setReplySessionId(_ sid: Int?) {
        replySessionId = sid
    }

    /// Payloads matching this predicate get no response (timeout tests).
    public var silenced: @Sendable (String) -> Bool = { _ in false }
    /// Values (raw wire strings) returned for a registration of N keys.
    public var registrationValues: @Sendable (Int, Int) -> [String] = { registrationIndex, keyCount in
        (0..<keyCount).map { String($0) }
    }
    /// Values returned for a `fetchValues` of N keys (spec §5.3.2): `values:{…}`.
    public var fetchValues: @Sendable (Int) -> [String] = { keyCount in
        (0..<keyCount).map { String($0 + 100) }
    }
    /// Every `fetchValues` payload received, in order.
    public private(set) var fetches: [String] = []

    public func setFetchValues(_ provider: @escaping @Sendable (Int) -> [String]) {
        fetchValues = provider
    }

    public init(cipher: AesCbcCipher) {
        self.cipher = cipher
    }

    public func setSilenced(_ predicate: @escaping @Sendable (String) -> Bool) {
        silenced = predicate
    }

    public func setRegistrationValues(_ provider: @escaping @Sendable (Int, Int) -> [String]) {
        registrationValues = provider
    }

    public func openSocket() -> InMemoryUdpSocket {
        let socket = InMemoryUdpSocket { [weak self] data, socket in
            await self?.receive(data, from: socket)
        }
        openedSockets.append(socket)
        return socket
    }

    private func receive(_ data: Data, from socket: InMemoryUdpSocket) {
        guard let plaintext = cipher.decrypt(data),
              let text = String(data: plaintext, encoding: .utf8)
        else { return }

        // req::{msg_id}:{payload}
        let parts = text.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, parts[0] == "req" else { return }
        let msgId = String(parts[2])
        let payload = String(parts[3])

        receivedPayloads.append(payload)
        receivedMsgIds.append(msgId)
        guard !silenced(payload) else { return }

        if payload.hasPrefix("SYSTEM:clientRegister(") {
            let (sessionId, keyCount) = Self.parseRegistration(payload)
            let index = registrations.count
            registrations.append(Registration(
                sessionId: sessionId, keyCount: keyCount, payload: payload, socket: socket))
            let values = registrationValues(index, keyCount)
            respond("clientReport:\(replySessionId ?? sessionId):{\(values.joined(separator: ","))}",
                    msgId: msgId, to: socket)
        } else if payload.hasPrefix("SYSTEM:fetchValues(") {
            fetches.append(payload)
            let keyCount = Self.parseRegistration("SYSTEM:clientRegister(0,0,0," + payload.dropFirst("SYSTEM:fetchValues(".count)).keyCount
            respond("values:{\(fetchValues(keyCount).joined(separator: ","))}", msgId: msgId, to: socket)
        } else if payload.hasPrefix("SYSTEM:clientDestroy(") {
            let number = Int(payload.dropLast().split(separator: ",").last ?? "") ?? -1
            destroyedNumbers.append(number)
            respond("\(number)", msgId: msgId, to: socket)   // live CLUs answer the number
        } else {
            respond("ok", msgId: msgId, to: socket)
        }
    }

    private func respond(_ payload: String, msgId: String, to socket: InMemoryUdpSocket) {
        let frame = "resp:10.0.0.1:\(msgId):\(payload)"
        if let encrypted = try? cipher.encrypt(Data(frame.utf8)) {
            socket.deliver(encrypted)
        }
    }

    /// Unsolicited clientReport (msg id 00000000) to the socket that sent
    /// the given registration, with its subscription number unless another
    /// is given — the real CLU's behaviour (spec §5.3.3).
    public func sendReport(registrationIndex: Int, values: [String], sessionId: Int? = nil) {
        guard registrations.indices.contains(registrationIndex) else { return }
        let registration = registrations[registrationIndex]
        let number = sessionId ?? registration.sessionId
        let frame = "resp:10.0.0.1:00000000:clientReport:\(number):{\(values.joined(separator: ","))}"
        if let encrypted = try? cipher.encrypt(Data(frame.utf8)) {
            registration.socket.deliver(encrypted)
        }
    }

    /// Raw garbage bytes to the most recently opened socket.
    public func sendGarbageToLastSocket() {
        openedSockets.last?.deliver(Data([0xDE, 0xAD, 0xBE, 0xEF, 0x01]))
    }

    /// `SYSTEM:clientRegister(0,0,{session},{k1,...})` → (session, top-level key count).
    public static func parseRegistration(_ payload: String) -> (sessionId: Int, keyCount: Int) {
        let arguments = payload.dropFirst("SYSTEM:clientRegister(".count)
        let sessionId = Int(arguments.split(separator: ",")[2]) ?? -1

        guard let braceStart = arguments.firstIndex(of: "{"),
              let braceEnd = arguments.lastIndex(of: "}")
        else { return (sessionId, 0) }
        let inner = arguments[arguments.index(after: braceStart)..<braceEnd]
        guard !inner.isEmpty else { return (sessionId, 0) }

        var depth = 0
        var count = 1
        for character in inner {
            switch character {
            case "{": depth += 1
            case "}": depth -= 1
            case "," where depth == 0: count += 1
            default: break
            }
        }
        return (sessionId, count)
    }
}
