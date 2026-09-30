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
            responseTimeout: timeout)
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

    @Test func restartAfterStopRestoresSubscriptions() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(2))
        #expect(await fake.registrations.count == 1)

        await session.stop()
        // Restart: the retained desired set re-registers on the first ping.
        await session.start()
        #expect(await session.state == .ready)
        #expect(await fake.registrations.count == 2)
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
