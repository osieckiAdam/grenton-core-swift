import Testing
import Foundation
@testable import GrentonModel

/// Decodes the shared interface fixture (spec §9.3) and asserts the exact
/// set of surviving widgets plus spot-checks of every layer.
@Suite struct FixtureTests {

    func loadFixture() throws -> MobileInterfaceDTO {
        let url = try #require(Bundle.module.url(
            forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: url)
        return try MobileInterfaceDTO.decode(from: data)
    }

    @Test func decodesRootAndClus() throws {
        let interface = try loadFixture()
        #expect(interface.id == "interface-test-001")
        #expect(interface.version == 3)
        #expect(interface.theme == .grenton)
        #expect(interface.encryption.key == "AAECAwQFBgcICQoLDA0ODw==")
        #expect(interface.encryption.iv == "EBESExQVFhcYGRobHB0eHw==")

        let clu = try #require(interface.clus.first)
        #expect(clu.id == "CLU_501234567")
        #expect(clu.ip == "192.168.1.10")
        #expect(clu.port == 1234)
        #expect(clu.connectionType == .localOnly)
        #expect(interface.pushNotifications.count == 1)
    }

    @Test func skipsInvalidWidgetsAndKeepsOrder() throws {
        let interface = try loadFixture()
        let widgets = interface.allWidgets
        // 17 entries in the fixture: 14 valid + unknown type + missing
        // components + action without index (spec §3.6).
        #expect(widgets.count == 14)
        #expect(widgets.map(\.typeName) == [
            "VALUE_V2", "VALUE_DOUBLE", "ON_OFF", "ON_OFF_DOUBLE",
            "DIMMER_V2", "LED", "CONTACT_SENSOR", "CONTACT_SENSOR_DOUBLE",
            "SLIDER", "MULTISENSOR", "ROLLER_SHUTTER", "ROLLER_SHUTTER_V3",
            "CAMERA", "SCENE",
        ])
        #expect(!widgets.map(\.id).contains("w-unknown"))
        #expect(!widgets.map(\.id).contains("w-broken-missing-components"))
        #expect(!widgets.map(\.id).contains("w-broken-action-without-index"))
        #expect(interface.skippedWidgets.count == 3)
        #expect(interface.skippedWidgets.map(\.type)
            == ["FANCY_NEW_WIDGET", "ON_OFF", "ON_OFF"])
    }

    @Test func rendersWireSubscriptionKeys() throws {
        // spec §5.3.2 key forms, shared by Runtime and the conformance suite.
        let variable = ValueRef.variable(cluId: "c", name: "x_kinkiet")
        let attribute = ValueRef.attribute(cluId: "c", objectName: "DOU8272", index: "0")
        #expect(variable.wireSubscriptionKey == "\"x_kinkiet\"")
        #expect(attribute.wireSubscriptionKey == "{DOU8272,0}")
    }

    @Test func decodesOnOffComponents() throws {
        let interface = try loadFixture()
        guard case .onOff(let widget) = interface.allWidgets[2] else {
            Issue.record("Expected ON_OFF at index 2")
            return
        }
        #expect(widget.id == "w-onoff")
        #expect(widget.components.count == 2)

        let first = widget.components[0]
        #expect(first.rowId == 0)
        #expect(first.state.callType == .attribute)
        #expect(first.actions.map(\.event) == [.on, .off])

        // VARIABLE state ref maps index → name (spec §3.2).
        let second = widget.components[1]
        #expect(ValueRef(dto: second.state)
            == .variable(cluId: "CLU_501234567", name: "x_kinkiet"))
        #expect(ValueRef(dto: first.state)
            == .attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0"))
    }

    @Test func decodesLedUnionComponents() throws {
        let interface = try loadFixture()
        guard case .led(let widget) = interface.allWidgets[5] else {
            Issue.record("Expected LED at index 5")
            return
        }
        #expect(widget.components.count == 4)
        guard case .button = widget.components[0],
              case .hue(let hue) = widget.components[1],
              case .saturation = widget.components[2],
              case .brightness(let brightness) = widget.components[3] else {
            Issue.record("LED component union mismatch")
            return
        }
        #expect(hue.range.min == 0 && hue.range.max == 360)
        #expect(brightness.range.max == 255)
    }

    @Test func decodesOptionalClickActions() throws {
        let interface = try loadFixture()
        guard case .contactSensorDouble(let widget) = interface.allWidgets[7] else {
            Issue.record("Expected CONTACT_SENSOR_DOUBLE at index 7")
            return
        }
        #expect(widget.componentLeft.object.clickAction != nil)
        #expect(widget.componentRight.object.clickAction == nil)

        guard case .slider(let slider) = interface.allWidgets[8] else {
            Issue.record("Expected SLIDER at index 8")
            return
        }
        #expect(slider.object.clickAction == nil)
        #expect(slider.min == 16 && slider.max == 28 && slider.precision == 1)
    }

    @Test func decodesRollerShutterV3TiltHeuristic() throws {
        let interface = try loadFixture()
        guard case .rollerShutterV3(let widget) = interface.allWidgets[11] else {
            Issue.record("Expected ROLLER_SHUTTER_V3 at index 11")
            return
        }
        // Fixture models a shutter WITH lamels and a stop action (spec §6.3.8).
        #expect(widget.object.lamelMoveTimeout != nil)
        #expect(widget.object.stopAction != nil)
        #expect(widget.object.calibrationAction == nil)
    }

    @Test func decodesCameraAndScene() throws {
        let interface = try loadFixture()
        guard case .camera(let camera) = interface.allWidgets[12],
              case .scene(let scene) = interface.allWidgets[13] else {
            Issue.record("Expected CAMERA and SCENE at the tail")
            return
        }
        #expect(camera.components[0].value == "rtsp://192.168.1.20:554/stream1")

        let sceneAction = try #require(scene.components[0].actions.first)
        #expect(sceneAction.callType == .script)
        #expect(sceneAction.index == nil)
        let ref = try ActionRef(dto: sceneAction)
        #expect(ref.call == .script)
        #expect(ref.value == "\"123\"")
        // Scene parameter override copies, never mutates (spec §6.3.10).
        let overridden = ref.withValue("42")
        #expect(overridden.value == "42")
        #expect(ref.value == "\"123\"")
    }
}
