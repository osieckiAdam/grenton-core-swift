import Testing
import Foundation
import GrentonModel
@testable import GrentonDevices

/// Widget → descriptor mapping against the shared interface fixture:
/// suffix contract, completeness rules, per-type payloads (spec §6.3).
@Suite struct MapperTests {

    func loadDescriptors() throws -> [DeviceDescriptor] {
        let url = try #require(Bundle.module.url(
            forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let interface = try MobileInterfaceDTO.decode(from: Data(contentsOf: url))
        return DeviceMapper.descriptors(for: interface)
    }

    func descriptor(_ id: String) throws -> DeviceDescriptor {
        try #require(try loadDescriptors().first { $0.id == id })
    }

    @Test func mapsEveryFixtureWidget() throws {
        let descriptors = try loadDescriptors()
        #expect(descriptors.count == 14)
        // The exact entity-id contract (spec §6.3) — adapters key their
        // configuration on these.
        let allIds = descriptors.flatMap { $0.entities.map(\.id) }
        #expect(allIds == [
            "w-value_0",
            "w-value-double_0", "w-value-double_1",
            "w-onoff_0", "w-onoff_1",
            "w-onoff-double_0", "w-onoff-double_1",
            "w-dimmer_0",
            "w-led_0",
            "w-contact_binary_sensor", "w-contact_button",
            "w-contact-double_binary_sensor_left", "w-contact-double_button_left",
            "w-contact-double_binary_sensor_right",
            "w-slider_slider",
            "w-multi_air_co2", "w-multi_sound", "w-multi_air_voc", "w-multi_light",
            "w-multi_pressure", "w-multi_humidity", "w-multi_temperature",
            "w-rs-legacy_sensor", "w-rs-legacy_button",
            "w-rs3",
            "w-camera_0",
            "w-scene_0",
        ])
    }

    @Test func togglesRequireBothActions() throws {
        let device = try descriptor("w-onoff")
        #expect(device.entities.count == 2)
        guard case .toggle(let first) = device.entities[0] else {
            Issue.record("expected toggle")
            return
        }
        #expect(first.onAction.event == .on)
        #expect(first.offAction.event == .off)
        #expect(first.state == .attribute(cluId: "CLU_501234567", objectName: "DOU8272", index: "0"))
    }

    @Test func ledMapsAllChannelsWithRanges() throws {
        let device = try descriptor("w-led")
        guard case .hsbLight(let led) = try #require(device.entities.first) else {
            Issue.record("expected hsbLight")
            return
        }
        #expect(led.hue.range == ChannelRange(min: 0, max: 360))
        #expect(led.saturation.range == ChannelRange(min: 0, max: 100))
        #expect(led.brightness.range == ChannelRange(min: 0, max: 255))
        #expect(led.onAction.event == .on)
    }

    @Test func incompleteLedYieldsNoEntities() throws {
        // Button + hue only — brightness/saturation missing (spec §6.3.3).
        let json = """
        { "type": "LED", "id": "w-led-broken", "components": [
            { "type": "BUTTON_BISTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
              "image": "i",
              "state": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
              "actions": [
                { "event": "ON", "cluId": "c", "objectName": "o", "index": "1", "value": "", "callType": "METHOD" },
                { "event": "OFF", "cluId": "c", "objectName": "o", "index": "2", "value": "", "callType": "METHOD" } ],
              "onIndication": "ON", "offIndication": "OFF" },
            { "type": "SLIDER_HUE", "label": "H", "rowId": 1, "unit": "DEGREE",
              "range": { "min": 0, "max": 360 },
              "state": { "cluId": "c", "objectName": "o", "index": "3", "callType": "ATTRIBUTE" },
              "actions": [ { "event": "CLICK", "cluId": "c", "objectName": "o", "index": "4", "value": "0", "callType": "METHOD" } ] }
        ] }
        """
        let widget = try JSONDecoder().decode(WidgetDTO.self, from: Data(json.utf8))
        let device = DeviceMapper.descriptor(for: widget, page: DevicePage(index: 0, name: "p", icon: "star"))
        #expect(device.entities.isEmpty)
    }

    @Test func onOffComponentWithoutOffIsSkipped() throws {
        let json = """
        { "type": "ON_OFF", "id": "w-half", "components": [
            { "type": "BUTTON_BISTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
              "state": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
              "actions": [ { "event": "ON", "cluId": "c", "objectName": "o", "index": "0", "value": "1", "callType": "ATTRIBUTE" } ],
              "onIndication": "ON", "offIndication": "OFF" }
        ] }
        """
        let widget = try JSONDecoder().decode(WidgetDTO.self, from: Data(json.utf8))
        #expect(DeviceMapper.descriptor(for: widget, page: DevicePage(index: 0, name: "p", icon: "star")).entities.isEmpty)
    }

    @Test func coverMapsTiltAndStop() throws {
        let device = try descriptor("w-rs3")
        guard case .cover(let cover) = try #require(device.entities.first) else {
            Issue.record("expected cover")
            return
        }
        // Fixture has lamelMoveTimeout + stopAction (spec §6.3.8).
        #expect(cover.id == "w-rs3")   // no suffix — reference contract
        #expect(cover.tilt != nil)
        #expect(cover.stopAction != nil)
        #expect(cover.position == .attribute(cluId: "CLU_501234567", objectName: "ROL2020", index: "1"))
    }

    @Test func multisensorChannelsCarryKindsAndUnits() throws {
        let device = try descriptor("w-multi")
        let sensors: [SensorDescriptor] = device.entities.compactMap {
            if case .sensor(let s) = $0 { return s } else { return nil }
        }
        #expect(sensors.count == 7)
        #expect(sensors.map(\.kind) == [
            .co2, .soundPressure, .voc, .illuminance, .pressure, .humidity, .temperature,
        ])
        #expect(sensors.compactMap(\.kind.canonicalUnit) == [
            "ppm", "dB", "ppb", "lx", "hPa", "%", "°C",
        ])
    }

    @Test func contactDoubleClickOnlyWhereProvided() throws {
        let device = try descriptor("w-contact-double")
        // Fixture: left has clickAction, right does not (spec §6.3.4).
        #expect(device.entities.map(\.id) == [
            "w-contact-double_binary_sensor_left",
            "w-contact-double_button_left",
            "w-contact-double_binary_sensor_right",
        ])
    }

    @Test func sceneRequiresClickScriptAction() throws {
        let device = try descriptor("w-scene")
        guard case .sceneTrigger(let scene) = try #require(device.entities.first) else {
            Issue.record("expected sceneTrigger")
            return
        }
        #expect(scene.action.call == .script)
        #expect(scene.action.value == "\"123\"")
    }

    @Test func cameraCarriesStreamURL() throws {
        let device = try descriptor("w-camera")
        guard case .camera(let camera) = try #require(device.entities.first) else {
            Issue.record("expected camera")
            return
        }
        #expect(camera.streamURL == "rtsp://192.168.1.20:554/stream1")
    }

    @Test func sensorCarriesPresentationMetadata() throws {
        let device = try descriptor("w-value")
        guard case .sensor(let sensor) = try #require(device.entities.first) else {
            Issue.record("expected sensor")
            return
        }
        #expect(sensor.grentonUnit == .degree)
        #expect(sensor.valueType == .float)
        #expect(sensor.precision == 1)
        #expect(sensor.kind == .generic)
    }
}
