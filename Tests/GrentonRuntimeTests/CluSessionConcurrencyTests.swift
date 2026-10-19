import Testing
import Foundation
import GrentonModel
import GrentonTestSupport
@testable import GrentonRuntime

/// Adversarial concurrency scenarios from the milestone-4 review round:
/// stop-during-open, concurrent pings, gate cancellation, and degraded
/// recovery with re-registration.
@Suite struct CluSessionConcurrencyTests {

    static let keyB64 = "AAECAwQFBgcICQoLDA0ODw=="
    static let ivB64 = "EBESExQVFhcYGRobHB0eHw=="

    func makeFixture(
        timeout: Duration = .seconds(2),
        openDelay: Duration? = nil
    ) throws -> (FakeClu, CluSession) {
        let cipher = try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64)
        let fake = FakeClu(cipher: cipher)
        let session = CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher,
            socketFactory: InMemoryUdpSocketFactory(fake: fake, openDelay: openDelay),
            responseTimeout: timeout,
            registerFrameLimit: 309)   // 30 of the `{OBJ,n}` keys per chunk
        return (fake, session)
    }

    func attributeKeys(_ count: Int) -> [ValueRef] {
        (0..<count).map { .attribute(cluId: "CLU_1", objectName: "OBJ", index: String($0)) }
    }

    @Test func stopInterruptsInFlightSocketOpen() async throws {
        // Socket open hangs for 10 s; stop() must cancel it and return
        // promptly instead of waiting the delay out.
        let (_, session) = try makeFixture(openDelay: .seconds(10))
        async let started: Void = session.start()

        try await Task.sleep(for: .milliseconds(50))
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            await session.stop()
        }
        #expect(elapsed < .seconds(2))
        #expect(await session.state == .stopped)
        _ = await started
    }

    @Test func concurrentPingsShareOneMainSocket() async throws {
        let (fake, session) = try makeFixture(openDelay: .milliseconds(50))

        // Both pings race the (delayed) main-socket open. Single-flight
        // open must install exactly one socket; the shared keepAliveId
        // guard keeps the second ping from racing the first request.
        async let first = session.ping()
        async let second = session.ping()
        let results = await (first, second)
        #expect(results.0 || results.1)

        #expect(await fake.openedSockets.count == 1)
        // Session is healthy afterwards.
        #expect(await session.ping())
        #expect(await session.state == .ready)
        await session.stop()
    }

    @Test func cancelledGateWaiterNeverRunsItsOperation() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(300))
        await session.start()
        // First register hangs until its timeout, holding the gate.
        await fake.setSilenced { $0.hasPrefix("SYSTEM:clientRegister(") }

        let victimKeys = attributeKeys(1)
        async let blocker = session.register(attributeKeys(2))

        try await Task.sleep(for: .milliseconds(50))
        let cancelled = Task { await session.register(victimKeys) }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()

        let cancelledSlots = await cancelled.value
        #expect(cancelledSlots == [.failed])

        _ = await blocker
        // The cancelled caller's registration was never sent: only the
        // blocker's single 2-key registration reached the fake.
        let registerPayloads = await fake.receivedPayloads.filter { $0.hasPrefix("SYSTEM:clientRegister(") }
        #expect(registerPayloads.count == 1)
        #expect(FakeClu.parseRegistration(registerPayloads[0]).keyCount == 2)
        await session.stop()
    }

    @Test func degradedRecoveryReregistersBeforeReady() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(100))
        await session.start()
        _ = await session.register(attributeKeys(3))
        #expect(await fake.registrations.count == 1)

        let stream = await session.reports()
        var iterator = stream.makeAsyncIterator()

        // CLU goes silent → ping degrades the session.
        await fake.setSilenced { _ in true }
        await session.ping()
        #expect(await session.state == .degraded)

        // CLU comes back → next ping must re-register the desired keys
        // and resynchronise consumers through the report pipeline.
        await fake.setSilenced { _ in false }
        let ok = await session.ping()
        #expect(ok)
        #expect(await session.state == .ready)
        #expect(await fake.registrations.count == 2)

        let recoveryReport = try #require(await iterator.next())
        #expect(recoveryReport.keys == attributeKeys(3))
        #expect(recoveryReport.slots.count == 3)
        #expect(!recoveryReport.slots.contains(.failed))
        await session.stop()
    }

    @Test func restartAfterStopStartsWithoutSubscriptions() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(2))
        #expect(await fake.registrations.count == 1)

        await session.stop()
        #expect(await fake.destroyedNumbers == [1])
        // Restart: the caller registers again (spec §5.4.5); nothing is
        // restored on its own.
        await session.start()
        #expect(await session.state == .ready)
        #expect(await fake.registrations.count == 1)
        _ = await session.register(attributeKeys(2))
        #expect(await fake.registrations.last?.sessionId == 1)   // numbering restarts
        await session.stop()
    }

    @Test func startRacingStopWaitsForTheTeardown() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(35))
        // stop() suspends while sending its destroys; a start() issued once
        // stop() has begun must not ping the socket being torn down.
        let stopping = Task { await session.stop() }
        while await session.state != .stopped { await Task.yield() }
        await session.start()
        await stopping.value
        #expect(await fake.destroyedNumbers == [1, 2])
        #expect(await session.state == .ready)
        #expect(await fake.openedSockets.count == 2)
        #expect(await fake.openedSockets.first?.isClosed == true)
        // The new run works on its new socket.
        #expect(await session.ping())
        await session.stop()
    }

    @Test func concurrentStopsJoinOneTeardown() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(3))
        async let first: Void = session.stop()
        async let second: Void = session.stop()
        _ = await (first, second)
        #expect(await fake.destroyedNumbers == [1])
        #expect(await session.state == .stopped)
        #expect(await fake.openedSockets.allSatisfy { $0.isClosed })
    }

    @Test func emptyRegistrationThenStopDestroysEachNumberOnce() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(35))
        async let emptied = session.register([])
        async let stopped: Void = session.stop()
        _ = await (emptied, stopped)
        // Whichever runs first, every number is destroyed exactly once
        // while the socket is still open.
        #expect(await fake.destroyedNumbers.sorted() == [1, 2])
    }

    @Test func aRegistrationQueuedBeforeStopIsForgotten() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(300))
        await session.start()
        await fake.setSilenced { $0.hasPrefix("SYSTEM:clientRegister(") }
        // A hangs on the silent CLU and holds the gate; B queues behind it.
        let first = Task { await session.register(attributeKeys(2)) }
        try await Task.sleep(for: .milliseconds(30))
        let second = Task { await session.register(attributeKeys(3)) }
        try await Task.sleep(for: .milliseconds(30))
        await session.stop()
        _ = await (first.value, second.value)
        await fake.setSilenced { _ in false }

        // After a restart and a failed-then-good ping, nothing is restored
        // on its own: B never reaches the CLU.
        await session.start()
        await fake.setSilenced { $0 == "checkAlive()" }
        _ = await session.ping()
        await fake.setSilenced { _ in false }
        _ = await session.ping()
        #expect(await fake.receivedPayloads.filter { $0.hasPrefix("SYSTEM:clientRegister(0,0,1,{{OBJ,0},{OBJ,1},{OBJ,2}})") }.isEmpty)
        await session.stop()
    }

    @Test func stateStoreOrderingUnderConcurrentWriters() async throws {
        let store = StateStore()
        let key = ValueRef.variable(cluId: "CLU_1", name: "x")
        store.registerKey(key)

        let stream = store.changes()
        // Two writers hammer the same key; every observed event must chain:
        // its oldValue equals the previous event's newValue (commit order
        // == emission order, spec §5.6).
        // 40 total events < the 64-event stream buffer: nothing drops, so
        // the full chain must be observable.
        await withTaskGroup(of: Void.self) { group in
            for writer in 0..<2 {
                group.addTask {
                    for i in 0..<20 {
                        store.updateKeys([key], [.value(.int(Int64(writer * 1000 + i)))])
                    }
                }
            }
        }

        var previous: GrentonValue? = nil
        var count = 0
        for await change in stream {
            #expect(change.oldValue == previous)
            previous = change.newValue
            count += 1
            if change.newValue == store.value(for: key) && count >= 2 { break }
        }
        #expect(count >= 2)
    }
}

/// A transport whose sends never finish until the socket is closed.
private final class HangingSocket: UdpSocket, @unchecked Sendable {
    let incoming: AsyncStream<Data>
    private let incomingContinuation: AsyncStream<Data>.Continuation
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, any Error>] = []
    private var closed = false
    var isClosed: Bool { lock.withLock { closed } }

    init() {
        var continuation: AsyncStream<Data>.Continuation!
        incoming = AsyncStream { continuation = $0 }
        incomingContinuation = continuation
    }

    func send(_ datagram: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            lock.lock()
            if closed {
                lock.unlock()
                continuation.resume(throwing: TransportError.connectionFailed("closed"))
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func close() {
        lock.lock()
        closed = true
        let stuck = waiting
        waiting = []
        lock.unlock()
        stuck.forEach { $0.resume(throwing: TransportError.connectionFailed("closed")) }
        incomingContinuation.finish()
    }
}

private final class HangingSocketFactory: UdpSocketFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var opened: [HangingSocket] = []
    var sockets: [HangingSocket] { lock.withLock { opened } }

    func open(host: String, port: Int) async throws -> any UdpSocket {
        let socket = HangingSocket()
        lock.withLock { opened.append(socket) }
        return socket
    }
}

@Suite struct CluSessionHangingTransportTests {
    @Test func stopIsNotBlockedByASendThatNeverFinishes() async throws {
        let cipher = try AesCbcCipher(keyBase64: "AAECAwQFBgcICQoLDA0ODw==", ivBase64: "EBESExQVFhcYGRobHB0eHw==")
        let session = CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher, socketFactory: HangingSocketFactory(),
            responseTimeout: .milliseconds(100))
        await session.start()   // the ping's send hangs → timeout → degraded
        #expect(await session.state == .degraded)
        let slots = await session.register([.attribute(cluId: "CLU_1", objectName: "OBJ", index: "0")])
        #expect(slots == [.failed])

        // Two sends are stuck in the transport; stop() may wait for them at
        // most one response timeout, then closes the socket.
        let started = ContinuousClock.now
        await session.stop()
        #expect(ContinuousClock.now - started < .seconds(2))
        #expect(await session.state == .stopped)
    }

    @Test func aDestroyBehindAStuckSendDropsTheSocketInstead() async throws {
        let cipher = try AesCbcCipher(keyBase64: "AAECAwQFBgcICQoLDA0ODw==", ivBase64: "EBESExQVFhcYGRobHB0eHw==")
        let factory = HangingSocketFactory()
        let session = CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher, socketFactory: factory,
            responseTimeout: .milliseconds(100))
        await session.start()
        _ = await session.register([.attribute(cluId: "CLU_1", objectName: "OBJ", index: "0")])
        // Its registration send is still stuck: the destroy of number 1 could
        // overtake it, so the session drops the socket rather than send it.
        _ = await session.register([])
        #expect(factory.sockets.first?.isClosed == true)
        #expect(await session.state == .degraded)
        await session.stop()
    }
}
