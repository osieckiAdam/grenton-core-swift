import Testing
import Foundation
import GrentonModel
import GrentonRuntime
import GrentonTestSupport
@testable import GrentonDevices

/// End-to-end facade behaviour over FakeClu: fixture interface → devices
/// → sessions → registration → reports → entity state → commands.
@Suite struct SystemTests {

    func makeSystem(
        pingInterval: Duration = .seconds(60),
        registerInterval: Duration = .seconds(60)
    ) throws -> (GrentonSystem, FakeClu) {
        let url = try #require(Bundle.module.url(
            forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let interface = try MobileInterfaceDTO.decode(from: Data(contentsOf: url))
        let cipher = try AesCbcCipher(encryption: interface.encryption)
        let fake = FakeClu(cipher: cipher)
        let system = try GrentonSystem(
            interface: interface,
            socketFactory: InMemoryUdpSocketFactory(fake: fake),
            pingInterval: pingInterval,
            registerInterval: registerInterval,
            responseTimeout: .seconds(2))
        return (system, fake)
    }

    func toggle(in system: GrentonSystem) throws -> ToggleEntity {
        let entity = try #require(system.entities.first { $0.id == "w-onoff_0" })
        guard case .toggle(let toggle) = entity else {
            throw GrentonModelError.unknownDiscriminator("expected toggle")
        }
        return toggle
    }

    @Test func startRegistersAndAppliesInitialValues() async throws {
        let (system, fake) = try makeSystem()
        // Deterministic initial values: "ON" for every subscribed key.
        await fake.setRegistrationValues { _, count in
            (0..<count).map { _ in "\"ON\"" }
        }

        await system.start()
        defer { Task { await system.stop() } }

        let payloads = await fake.receivedPayloads
        #expect(payloads.contains("checkAlive()"))
        #expect(payloads.contains { $0.hasPrefix("SYSTEM:clientRegister(") })

        // Initial registration values flow into entity state.
        let toggle = try toggle(in: system)
        #expect(toggle.isOn == true)

        let states = await system.sessionStates()
        #expect(states["CLU_501234567"] == .ready)
        await system.stop()
    }

    @Test func reportsFlowIntoEntities() async throws {
        let (system, fake) = try makeSystem()
        await system.start()

        let toggle = try toggle(in: system)
        let stream = toggle.updates()
        var iterator = stream.makeAsyncIterator()

        // The toggle's key position within its registration chunk: find
        // the registration and the index of DOU8272/0 in the store order.
        let order = system.store.subscriptionOrder(cluId: "CLU_501234567")
        let keyIndex = try #require(order.firstIndex(
            of: .attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")))
        // Fixture has < 30 keys → single chunk, registration 0.
        var values = order.map { _ in "0" }
        values[keyIndex] = "\"ON\""
        await fake.sendReport(registrationIndex: 0, values: values)

        _ = await iterator.next()
        #expect(toggle.isOn == true)
        await system.stop()
    }

    @Test func commandsRouteToTheOwningClu() async throws {
        let (system, fake) = try makeSystem()
        await system.start()

        let toggle = try toggle(in: system)
        try await toggle.turnOn()
        let payloads = await fake.receivedPayloads
        #expect(payloads.contains("DOU8272:set(0,\"1\")"))
        await system.stop()
    }

    @Test func fetchReadsOnceAndStoresEvenUnwatchedKeys() async throws {
        let (system, fake) = try makeSystem()
        await system.start()
        defer { Task { await system.stop() } }
        await fake.setFetchValues { count in (0..<count).map { _ in "\"ON\"" } }

        let watched = ValueRef.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")
        let unwatched = ValueRef.attribute(cluId: "CLU_501234567", objectName: "NOPE_0000", index: "0")
        let foreign = ValueRef.attribute(cluId: "CLU_UNKNOWN", objectName: "X", index: "0")
        let slots = await system.fetch([unwatched, foreign, watched])

        #expect(slots == [.value(.string("ON")), .failed, .value(.string("ON"))])
        let fetches = await fake.fetches
        #expect(fetches == ["SYSTEM:fetchValues({{NOPE_0000,0},{DOU8272,0}})"])
        #expect(system.store.value(for: unwatched) == .string("ON"))
        #expect(try toggle(in: system).isOn == true)
        // A one-shot read registers nothing.
        #expect(system.store.subscriptionOrder(cluId: "CLU_501234567").contains(unwatched) == false)
        let registrations = await fake.registrations.count
        #expect(registrations == 1)
        await system.stop()
    }

    @Test func unknownCluIsRejected() async throws {
        let (system, _) = try makeSystem()
        await system.start()
        let foreign = ActionRef(
            cluId: "CLU_UNKNOWN", objectName: "X", event: .click,
            call: .script, value: "")
        await #expect(throws: SessionError.notConnected) {
            try await system.execute(foreign)
        }
        await system.stop()
    }

    @Test func stopStartCycleKeepsWorking() async throws {
        let (system, fake) = try makeSystem()
        await system.start()
        await system.stop()
        #expect(await system.sessionStates()["CLU_501234567"] == .stopped)

        await system.start()
        #expect(await system.sessionStates()["CLU_501234567"] == .ready)
        // Two lifecycles → at least two registrations reached the fake.
        let registrations = await fake.registrations
        #expect(registrations.count >= 2)
        await system.stop()
    }

    @Test func pingLoopKeepsPinging() async throws {
        let (system, fake) = try makeSystem(pingInterval: .milliseconds(80))
        await system.start()
        try await Task.sleep(for: .milliseconds(300))
        let pings = await fake.receivedPayloads.filter { $0 == "checkAlive()" }
        #expect(pings.count >= 2)
        await system.stop()
    }

    @Test func commandsBeforeStartFailCleanly() async throws {
        let (system, _) = try makeSystem()
        let toggle = try toggle(in: system)
        await #expect(throws: SessionError.notConnected) {
            try await toggle.turnOn()
        }
    }

    @Test func overlappingStartStopIsSerialized() async throws {
        let (system, fake) = try makeSystem(pingInterval: .milliseconds(60))
        // Hammer the lifecycle concurrently; the gate must serialize it.
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<4 {
                group.addTask { await system.start() }
                group.addTask { await system.stop() }
            }
        }
        await system.stop()

        // Whatever interleaving happened, a stopped system must go quiet:
        // no zombie ping loop may keep hitting the fake.
        let before = await fake.receivedPayloads.count
        try await Task.sleep(for: .milliseconds(250))
        let after = await fake.receivedPayloads.count
        #expect(after == before)

        // ...and a fresh start still works.
        await system.start()
        #expect(await system.sessionStates()["CLU_501234567"] == .ready)
        await system.stop()
    }

    @Test func registerLoopResynchronisesPeriodically() async throws {
        let (system, fake) = try makeSystem(registerInterval: .milliseconds(100))
        await system.start()
        let initial = await fake.registrations.count
        try await Task.sleep(for: .milliseconds(350))
        let later = await fake.registrations.count
        #expect(later > initial)
        await system.stop()
    }

    @Test func degradedStartRecoversSubscriptionsOnPing() async throws {
        let (system, fake) = try makeSystem(pingInterval: .milliseconds(80))
        // CLU unreachable during startup: initial ping and registration fail.
        await fake.setSilenced { _ in true }
        await system.start()
        #expect(await system.sessionStates()["CLU_501234567"] == .degraded)
        #expect(await fake.registrations.isEmpty)

        // CLU comes back → the ping loop must recover AND re-register
        // (spec §5.4.5) without any external help.
        await fake.setSilenced { _ in false }
        try await Task.sleep(for: .milliseconds(400))
        #expect(await system.sessionStates()["CLU_501234567"] == .ready)
        #expect(await fake.registrations.count >= 1)
        await system.stop()
    }

    @Test func refreshSubscriptionsRegistersImmediately() async throws {
        let (system, fake) = try makeSystem()
        await system.start()
        let initial = await fake.registrations.count

        system.store.registerKey(
            .variable(cluId: "CLU_501234567", name: "x_new_runtime_key"))
        await system.refreshSubscriptions()

        let registrations = await fake.registrations
        #expect(registrations.count == initial + 1)
        #expect(registrations.last?.payload.contains("\"x_new_runtime_key\"") == true)
        await system.stop()
    }
}
