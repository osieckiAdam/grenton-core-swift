import Foundation
import GrentonRuntime

/// Test doubles for the `session` profile (conformance.md §4b): a clock that
/// only moves when told to, and a transport that records what the session
/// sends and delivers what the scenario injects. No protocol logic here.

// MARK: - Virtual clock

/// Time stands still until `advance(by:)`. Sleepers whose deadline passes
/// are resumed in deadline order; a cancelled sleep throws, like
/// `Task.sleep`.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (lhs: Instant, rhs: Instant) -> Bool { lhs.offset < rhs.offset }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return current
    }

    var minimumResolution: Duration { .zero }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                if deadline <= current {
                    lock.unlock()
                    continuation.resume()
                } else if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else {
                    sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                    lock.unlock()
                }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
        }
    }

    func advance(by duration: Duration) {
        lock.lock()
        current = current.advanced(by: duration)
        let due = sleepers.filter { $0.value.deadline <= current }.sorted { $0.value.deadline < $1.value.deadline }
        for (id, _) in due { sleepers[id] = nil }
        lock.unlock()
        for (_, sleeper) in due { sleeper.continuation.resume() }
    }
}

// MARK: - Scripted transport

/// One socket the session opened. What it sends goes to the transport's
/// outbox; `deliver` hands it a datagram as if from the CLU.
final class ScriptedSocket: UdpSocket, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    let serial: Int
    private let continuation: AsyncStream<Data>.Continuation
    private let transport: ScriptedTransport
    private let lock = NSLock()
    private var closed = false

    init(serial: Int, transport: ScriptedTransport) {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream(bufferingPolicy: .unbounded) { continuation = $0 }
        self.continuation = continuation
        self.serial = serial
        self.transport = transport
    }

    var isClosed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return closed
    }

    func send(_ datagram: Data) async throws {
        guard !isClosed else { throw TransportError.connectionFailed("closed") }
        transport.record(datagram, from: self)
    }

    func deliver(_ datagram: Data) {
        guard !isClosed else { return }
        continuation.yield(datagram)
    }

    /// The transport fails: the session's receive loop ends, but the socket
    /// was not closed by the session (conformance.md §4b `fail`).
    func fail() {
        continuation.finish()
    }

    func close() {
        lock.lock()
        closed = true
        lock.unlock()
        continuation.finish()
    }
}

final class ScriptedTransport: UdpSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var opened = 0
    private var outbox: [(socket: ScriptedSocket, datagram: Data)] = []

    func open(host: String, port: Int) async throws -> any UdpSocket {
        lock.withLock {
            opened += 1
            return ScriptedSocket(serial: opened, transport: self)
        }
    }

    func record(_ datagram: Data, from socket: ScriptedSocket) {
        lock.lock()
        outbox.append((socket, datagram))
        lock.unlock()
    }

    /// The oldest datagram not yet taken, waiting up to `wait` of real time.
    func nextSent(wait: Duration = .seconds(2)) async -> (socket: ScriptedSocket, datagram: Data)? {
        let deadline = ContinuousClock.now.advanced(by: wait)
        while ContinuousClock.now < deadline {
            if let first = takeFirst() { return first }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return takeFirst()
    }

    private func takeFirst() -> (socket: ScriptedSocket, datagram: Data)? {
        lock.withLock { outbox.isEmpty ? nil : outbox.removeFirst() }
    }

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return outbox.count
    }
}
