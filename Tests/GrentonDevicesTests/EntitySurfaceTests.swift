import Testing
import Foundation
import GrentonModel
import GrentonRuntime
@testable import GrentonDevices

/// The type-independent surface of BoundEntity: one update stream for
/// every stateful entity, one on/off surface for switches and lights.
@Suite struct EntitySurfaceTests {
    func loadBound() throws -> (entities: [BoundEntity], store: StateStore, executor: MockExecutor) {
        let url = try #require(Bundle.module.url(
            forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let interface = try MobileInterfaceDTO.decode(from: Data(contentsOf: url))
        let store = StateStore()
        let executor = MockExecutor()
        let devices = DeviceBinder.bind(
            DeviceMapper.descriptors(for: interface),
            context: DeviceContext(store: store, executor: executor))
        return (devices.flatMap(\.entities), store, executor)
    }

    func entity(_ id: String, in entities: [BoundEntity]) throws -> BoundEntity {
        try #require(entities.first { $0.id == id })
    }

    @Test func statelessEntitiesHaveNoUpdateStream() throws {
        let (entities, _, _) = try loadBound()
        for entity in entities {
            switch entity {
            case .trigger, .sceneTrigger, .camera: #expect(entity.updates() == nil, "\(entity.id)")
            default: #expect(entity.updates() != nil, "\(entity.id)")
            }
        }
    }

    @Test func updateStreamFiresOnStateChange() async throws {
        let (entities, store, _) = try loadBound()
        let stream = try #require(try entity("w-onoff_0", in: entities).updates())
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")],
            [.value(.string("ON"))])
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
    }

    @Test func switchableCoversSwitchesAndLightsOnly() throws {
        let (entities, _, _) = try loadBound()
        let switchable = entities.filter { $0.switchable != nil }.map(\.id).sorted()
        #expect(switchable == ["w-dimmer_0", "w-led_0", "w-onoff-double_0", "w-onoff-double_1",
                               "w-onoff_0", "w-onoff_1"])
    }

    @Test func setOnSendsTheOnOrOffAction() async throws {
        let (entities, store, executor) = try loadBound()
        let light = try #require(try entity("w-onoff_0", in: entities).switchable)
        #expect(light.isOn == nil)
        store.updateKeys(
            [.attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0")],
            [.value(.string("ON"))])
        #expect(light.isOn == true)

        try await light.setOn(false)
        #expect(executor.actions.last?.event == .off)
        try await light.setOn(true)
        #expect(executor.actions.last?.event == .on)

        let dimmer = try #require(try entity("w-dimmer_0", in: entities).switchable)
        try await dimmer.setOn(false)
        #expect(executor.actions.last?.objectName == "DIM3333")
        #expect(executor.actions.last?.event == .off)
    }
}
