import Testing
import Foundation
import GrentonModel
import GrentonRuntime
@testable import GrentonDevices

/// Records executed actions instead of touching a session.
final class MockExecutor: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ActionRef] = []

    private func record(_ action: ActionRef) {
        lock.lock()
        recorded.append(action)
        lock.unlock()
    }

    func execute(_ action: ActionRef) async throws {
        record(action)
    }

    var actions: [ActionRef] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }

    var lastValue: String? { actions.last?.value }
}

/// Live-entity behaviour over a real StateStore and a mock executor: state
/// normalization on reads, value formatting on writes (spec §6.3).
@Suite struct EntityTests {

    func loadBound() throws -> (devices: [BoundDevice], store: StateStore, executor: MockExecutor) {
        let url = try #require(Bundle.module.url(
            forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let interface = try MobileInterfaceDTO.decode(from: Data(contentsOf: url))
        let store = StateStore()
        let executor = MockExecutor()
        let devices = DeviceBinder.bind(
            DeviceMapper.descriptors(for: interface),
            context: DeviceContext(store: store, executor: executor))
        return (devices, store, executor)
    }

    func entity(_ id: String, in devices: [BoundDevice]) throws -> BoundEntity {
        try #require(devices.flatMap(\.entities).first { $0.id == id })
    }

    @Test func bindingRegistersAllStateRefs() throws {
        let (_, store, _) = try loadBound()
        // Every fixture ref lives on CLU_501234567; ordering is the
        // protocol-relevant subscription order.
        let order = store.subscriptionOrder(cluId: "CLU_501234567")
        #expect(!order.isEmpty)
        // Cover contributes motion + position + tilt (fixture has lamels).
        #expect(order.contains(.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "2")))
    }

    @Test func toggleReadsAndWrites() async throws {
        let (devices, store, executor) = try loadBound()
        guard case .toggle(let toggle) = try entity("w-onoff_0", in: devices) else {
            Issue.record("expected toggle")
            return
        }

        #expect(toggle.isOn == nil)   // unknown before any report
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")],
            [.value(.string("ON"))])
        #expect(toggle.isOn == true)
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")],
            [.value(.bool(false))])
        #expect(toggle.isOn == false)

        try await toggle.turnOn()
        #expect(executor.lastValue == "1")
        try await toggle.turnOff()
        #expect(executor.lastValue == "0")
    }

    @Test func dimmerNormalizesBrightnessBothWays() async throws {
        let (devices, store, executor) = try loadBound()
        guard case .dimmableLight(let dimmer) = try entity("w-dimmer_0", in: devices) else {
            Issue.record("expected dimmer")
            return
        }
        let stateRef = ValueRef.attribute(cluId: "CLU_501234567", objectName: "DIM3333", index: "0")

        store.updateKeys([stateRef], [.value(.int(50))])
        #expect(dimmer.isOn == true)
        #expect(dimmer.brightness == 0.5)   // widget range 0...100

        store.updateKeys([stateRef], [.value(.int(0))])
        #expect(dimmer.isOn == false)

        // precision 0 → reference format "50.0" (spec §10 pt 3).
        try await dimmer.setBrightness(0.5)
        #expect(executor.lastValue == "50.0")
        try await dimmer.setBrightness(7.0)   // clamped to 1
        #expect(executor.lastValue == "100.0")
    }

    @Test func hsbLightRoundTripsChannels() async throws {
        let (devices, store, executor) = try loadBound()
        guard case .hsbLight(let led) = try entity("w-led_0", in: devices) else {
            Issue.record("expected hsbLight")
            return
        }

        // Raw device values → canonical (hue 0..360 passthrough here,
        // saturation 0..100 → 0..1, brightness 0..255 → 0..1).
        store.updateKeys(
            [
                .attribute(cluId: "CLU_501234567", objectName: "LED4444", index: "3"),
                .attribute(cluId: "CLU_501234567", objectName: "LED4444", index: "5"),
                .attribute(cluId: "CLU_501234567", objectName: "LED4444", index: "7"),
            ],
            [.value(.int(180)), .value(.int(50)), .value(.double(127.5))])
        #expect(led.hue == 180)
        #expect(led.saturation == 0.5)
        #expect(led.brightness == 0.5)

        try await led.setColor(hue: 180, saturation: 0.5)
        let values = executor.actions.suffix(2).map(\.value)
        #expect(values == ["180.0", "50.0"])   // device ranges, 2 decimals

        try await led.setBrightness(1.0)
        #expect(executor.lastValue == "255.0")
    }

    @Test func contactSensorHonorsReverseState() throws {
        let (devices, store, _) = try loadBound()
        guard case .contactSensor(let sensor) = try entity("w-contact_binary_sensor", in: devices) else {
            Issue.record("expected contactSensor")
            return
        }
        let ref = ValueRef.attribute(cluId: "CLU_501234567", objectName: "DIN5555", index: "0")

        // Fixture: reverseState = true.
        store.updateKeys([ref], [.value(.int(1))])
        #expect(sensor.isActive == false)
        store.updateKeys([ref], [.value(.int(0))])
        #expect(sensor.isActive == true)
    }

    @Test func coverPositionMotionAndTilt() async throws {
        let (devices, store, executor) = try loadBound()
        guard case .cover(let cover) = try entity("w-rs3", in: devices) else {
            Issue.record("expected cover")
            return
        }
        let motionRef = ValueRef.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "0")
        let positionRef = ValueRef.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "1")
        let tiltRef = ValueRef.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "2")

        store.updateKeys([motionRef, positionRef, tiltRef],
                         [.value(.int(1)), .value(.int(0)), .value(.int(90))])
        #expect(cover.motion == .opening)
        #expect(cover.isClosed == true)
        #expect(cover.tilt == 0)   // raw 90 → canonical 0 (inverted scale)

        store.updateKeys([motionRef, positionRef, tiltRef],
                         [.value(.int(0)), .value(.int(100)), .value(.int(0))])
        #expect(cover.motion == .idle)
        #expect(cover.isClosed == false)
        #expect(cover.tilt == 100)

        try await cover.setPosition(50)
        #expect(executor.lastValue == "50")    // integer string, not "50.0"
        try await cover.open()
        #expect(executor.lastValue == "100")
        try await cover.setTilt(100)
        #expect(executor.lastValue == "0")     // canonical 100 → device 0
        try await cover.setTilt(0)
        #expect(executor.lastValue == "90")
        try await cover.stop()
        #expect(executor.actions.last?.call == .method(index: "9"))
    }

    @Test func tiltTruncatesRawBeforeMapping() throws {
        // Reference order: int(raw) BEFORE map_range — raw 44.9 → 51,
        // not 50 (truncate-after-mapping would give 50).
        let (devices, store, _) = try loadBound()
        guard case .cover(let cover) = try entity("w-rs3", in: devices) else {
            Issue.record("expected cover")
            return
        }
        let tiltRef = ValueRef.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "2")
        store.updateKeys([tiltRef], [.value(.double(44.9))])
        #expect(cover.tilt == 51)
    }

    @Test func readsClampToCanonicalRanges() throws {
        let (devices, store, _) = try loadBound()
        guard case .cover(let cover) = try entity("w-rs3", in: devices),
              case .hsbLight(let led) = try entity("w-led_0", in: devices) else {
            Issue.record("expected cover and led")
            return
        }
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "1")],
            [.value(.int(150))])
        #expect(cover.position == 100)

        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "LED4444", index: "7")],
            [.value(.int(999))])   // brightness raw beyond 0...255
        #expect(led.brightness == 1.0)
    }

    @Test func entitiesShareACommonSurface() throws {
        let (devices, _, _) = try loadBound()
        // The facade/CLI iterates without switching over the enum.
        let names = devices.flatMap(\.entities).map { $0.underlying.name }
        #expect(names.count == 27)
        #expect(names.contains("Lampa sufitowa"))
        let ids = devices.flatMap(\.entities).map(\.id)
        #expect(Set(ids).count == ids.count)   // globally unique
    }

    @Test func legacyShutterStateEnum() throws {
        let (devices, store, _) = try loadBound()
        guard case .stateSensor(let sensor) = try entity("w-rs-legacy_sensor", in: devices) else {
            Issue.record("expected stateSensor")
            return
        }
        let ref = ValueRef.attribute(cluId: "CLU_501234567", objectName: "ROL1010", index: "0")
        #expect(sensor.state == .unknown)
        for (raw, expected): (Int64, LegacyShutterState) in
            [(0, .stopped), (1, .opening), (2, .closing), (3, .locked), (7, .unknown)] {
            store.updateKeys([ref], [.value(.int(raw))])
            #expect(sensor.state == expected)
        }
    }

    @Test func sceneRunsWithAndWithoutParameter() async throws {
        let (devices, _, executor) = try loadBound()
        guard case .sceneTrigger(let scene) = try entity("w-scene_0", in: devices) else {
            Issue.record("expected sceneTrigger")
            return
        }

        try await scene.run()
        #expect(executor.lastValue == "\"123\"")   // widget's baked-in value

        try await scene.run(parameter: "42")
        #expect(executor.lastValue == "42")
        // The descriptor's template is never mutated (spec §6.3.10).
        #expect(scene.descriptor.action.value == "\"123\"")

        try await scene.run()
        #expect(executor.lastValue == "\"123\"")
    }

    @Test func numberSettingClampsAndFormats() async throws {
        let (devices, store, executor) = try loadBound()
        guard case .numberSetting(let slider) = try entity("w-slider_slider", in: devices) else {
            Issue.record("expected numberSetting")
            return
        }
        let ref = ValueRef.attribute(cluId: "CLU_501234567", objectName: "THE8888", index: "0")

        store.updateKeys([ref], [.value(.double(21.5))])
        #expect(slider.value == 21.5)
        #expect(slider.step == 0.1)   // precision 1

        try await slider.setValue(21.55)
        #expect(executor.lastValue == "21.6")   // Python round(21.55, 1)
        try await slider.setValue(99)           // clamped to max 28
        #expect(executor.lastValue == "28.0")
    }

    @Test func updatesFireOnlyForOwnKeys() async throws {
        let (devices, store, _) = try loadBound()
        guard case .toggle(let toggle) = try entity("w-onoff_0", in: devices) else {
            Issue.record("expected toggle")
            return
        }

        let stream = toggle.updates()
        let events = Counter()
        let consumer = Task { for await _ in stream { events.increment() } }
        defer { consumer.cancel() }
        func settle() async { try? await Task.sleep(for: .milliseconds(100)) }

        // A foreign key must not produce an event for this entity.
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DIM3333", index: "0")],
            [.value(.int(1))])
        await settle()
        #expect(events.value == 0)
        #expect(toggle.isOn == nil)

        // The entity's own key does, once per change.
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")],
            [.value(.string("ON"))])
        await settle()
        #expect(events.value == 1)
        #expect(toggle.isOn == true)
    }

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func increment() { lock.withLock { count += 1 } }
    }
}
