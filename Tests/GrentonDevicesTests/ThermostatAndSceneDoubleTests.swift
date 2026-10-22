import Testing
import Foundation
import GrentonModel
import GrentonRuntime
@testable import GrentonDevices

/// THERMOSTAT_V2, SCENE_DOUBLE and HEADER (spec §3.5, §6.3.10, §6.3.12),
/// on an inline interface shaped like a live Object Manager export.
@Suite struct ThermostatAndSceneDoubleTests {
    static let clu = "CLU_501234567"

    static func ref(_ index: String) -> String {
        #"{"cluId":"\#(clu)","objectName":"THE1001","index":"\#(index)","callType":"ATTRIBUTE"}"#
    }

    static func set(_ index: String) -> String {
        #"{"cluId":"\#(clu)","objectName":"THE1001","index":"\#(index)","event":"CLICK","value":"$value$","callType":"ATTRIBUTE"}"#
    }

    static func script(_ name: String, _ value: String = "") -> String {
        #"{"cluId":"\#(clu)","objectName":"\#(name)","event":"CLICK","value":"\#(value)","callType":"SCRIPT"}"#
    }

    static let json = """
    {"id":"i","version":1,"name":"n","icon":"home","theme":"GRENTON",
     "encryption":{"key":"AAECAwQFBgcICQoLDA0ODw==","iv":"EBESExQVFhcYGRobHB0eHw=="},
     "clus":[],"pushNotifications":[],
     "pages":[{"name":"p","icon":"home","isFullscreenWidget":false,"widgets":[
       {"type":"HEADER","id":"h","components":[{"type":"HEADER","label":"SEKCJA","rowId":0,"unit":"UNKNOWN"}]},
       {"type":"THERMOSTAT_V2","id":"t","label":"Kotłownia testowa","icon":"temperature","no_of_fan_speeds":0,"object":{
         "currentTemperature":\(ref("14")),"targetTemperature":\(ref("12")),
         "setTargetTemperatureAction":\(set("3")),
         "minTemperature":\(ref("10")),"maxTemperature":\(ref("11")),
         "setMinTemperatureAction":\(set("10")),"setMaxTemperatureAction":\(set("11")),
         "mode":\(ref("8")),"setModeAction":\(set("8")),
         "state":\(ref("6")),"setStateAction":\(set("6")),
         "controlOutValue":\(ref("13")),
         "scheduleData":\(ref("9")),"setScheduleDataAction":\(set("9"))}},
       {"type":"THERMOSTAT_V2","id":"t-min","label":"Minimalny","object":{
         "currentTemperature":\(ref("14")),"targetTemperature":\(ref("12")),
         "setTargetTemperatureAction":\(set("3"))}},
       {"type":"SCENE_DOUBLE","id":"s","background":{"color":"BLUE","name":"icon_1"},"components":[
         {"type":"BUTTON_MONOSTABLE","label":"Start","rowId":0,"unit":"UNKNOWN","actions":[\(script("SCENA_A"))]},
         {"type":"BUTTON_MONOSTABLE","label":"STOP","rowId":0,"unit":"UNKNOWN","actions":[\(script("SCENA_A_STOP"))]}]}
     ]}]}
    """

    func load() throws -> (interface: MobileInterfaceDTO, devices: [BoundDevice], store: StateStore, executor: MockExecutor) {
        let interface = try MobileInterfaceDTO.decode(from: Data(Self.json.utf8))
        let store = StateStore()
        let executor = MockExecutor()
        let devices = DeviceBinder.bind(
            DeviceMapper.descriptors(for: interface),
            context: DeviceContext(store: store, executor: executor))
        return (interface, devices, store, executor)
    }

    func thermostat(_ id: String, in devices: [BoundDevice]) throws -> ThermostatEntity {
        let entity = try #require(devices.flatMap(\.entities).first { $0.id == id })
        guard case .thermostat(let t) = entity else { throw SuiteError() }
        return t
    }

    struct SuiteError: Error {}

    @Test func headerIsNeitherADeviceNorSkipped() throws {
        let (interface, devices, _, _) = try load()
        #expect(interface.skippedWidgets.isEmpty)
        #expect(devices.map(\.descriptor.id) == ["t", "t-min", "s"])
    }

    @Test func sceneDoubleSuffixesByPosition() throws {
        let (_, devices, _, _) = try load()
        let scene = try #require(devices.first { $0.descriptor.id == "s" })
        #expect(scene.descriptor.kind == .scene)
        #expect(scene.descriptor.name == "Start / STOP")
        #expect(scene.entities.map(\.id) == ["s_0", "s_1"])   // both rowId 0
    }

    @Test func thermostatReadsFeatures() throws {
        let (_, devices, store, _) = try load()
        let t = try thermostat("t_0", in: devices)
        #expect(devices.first?.descriptor.kind == .thermostat)
        #expect(t.supportsMode && t.supportsPower)
        #expect(t.currentTemperature == nil && t.mode == nil && t.isActive == nil)

        func attr(_ index: String) -> ValueRef { .attribute(cluId: Self.clu, objectName: "THE1001", index: index) }
        store.updateKeys(
            [attr("14"), attr("12"), attr("10"), attr("11"), attr("8"), attr("6"), attr("13")],
            [.value(.double(21.4)), .value(.int(22)), .value(.int(8)), .value(.int(28)),
             .value(.int(2)), .value(.int(1)), .value(.int(1))])
        #expect(t.currentTemperature == 21.4)
        #expect(t.targetTemperature == 22)
        #expect(t.minTemperature == 8 && t.maxTemperature == 28)
        #expect(t.mode == .schedule)
        #expect(t.isActive == true)
        #expect(t.output == 1)

        store.updateKeys([attr("8")], [.value(.int(7))])
        #expect(t.mode == nil)   // outside 0...2
    }

    @Test func thermostatWritesReplaceThePlaceholder() async throws {
        let (_, devices, store, executor) = try load()
        let t = try thermostat("t_0", in: devices)

        try await t.setTargetTemperature(21.55)
        #expect(executor.lastValue == "21.6")   // one decimal, reference format
        #expect(executor.actions.last?.call == .attribute(index: "3"))

        func attr(_ index: String) -> ValueRef { .attribute(cluId: Self.clu, objectName: "THE1001", index: index) }
        store.updateKeys([attr("10"), attr("11")], [.value(.int(8)), .value(.int(28))])
        try await t.setTargetTemperature(35)
        #expect(executor.lastValue == "28.0")   // clamped to live max

        try await t.setMode(.manual)
        #expect(executor.lastValue == "0")
        try await t.setMode(.holiday)
        #expect(executor.lastValue == "1")
        try await t.setActive(false)
        #expect(executor.lastValue == "0")
        #expect(executor.actions.last?.call == .attribute(index: "6"))
        try await t.setActive(true)
        #expect(executor.lastValue == "1")
        #expect(!executor.actions.contains { $0.value == "$value$" })
    }

    @Test func minimalThermostatHasNoOptionalControls() async throws {
        let (_, devices, _, executor) = try load()
        let t = try thermostat("t-min_0", in: devices)
        #expect(!t.supportsMode && !t.supportsPower)
        try await t.setMode(.schedule)
        try await t.setActive(true)
        #expect(executor.actions.isEmpty)   // no-ops, like Cover.stop()
    }
}
