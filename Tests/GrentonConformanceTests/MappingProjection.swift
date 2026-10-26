import Foundation
import GrentonModel
import GrentonDevices

/// JSON projection of the mapping output (`spec/conformance.md` §4a):
/// devices in order, full entity descriptors, skipped widget types per page.
/// Pure field renaming — every decision comes from `DeviceMapper`.
enum MappingProjection {
    static func interface(_ interface: MobileInterfaceDTO) -> JSON {
        let devices = DeviceMapper.descriptors(for: interface)
        return .object([
            "devices": .array(devices.map(device)),
            "physicalObjects": .array(DeviceMapper.physicalObjects(for: devices).map(physicalObject)),
            "skippedWidgets": .array(interface.pages.map { page in
                .array(page.skippedWidgets.map { $0.type.map(JSON.string) ?? .null })
            }),
        ])
    }

    static func device(_ d: DeviceDescriptor) -> JSON {
        .object([
            "id": .string(d.id),
            "widgetType": .string(d.typeName),
            "kind": .string(d.kind.rawValue),
            "name": .string(d.name),
            "icon": d.icon.map(JSON.string) ?? .null,
            "page": page(d.page),
            "section": d.section.map { .object(["id": .string($0.id), "title": .string($0.title)]) } ?? .null,
            "entities": .array(d.entities.map(entity)),
        ])
    }

    static func page(_ p: DevicePage) -> JSON {
        .object(["index": .number(Double(p.index)), "name": .string(p.name), "icon": .string(p.icon)])
    }

    static func physicalObject(_ o: PhysicalObject) -> JSON {
        .object([
            "key": .object(["cluId": .string(o.key.cluId), "kind": .string(o.key.kind.rawValue),
                            "name": .string(o.key.name), "index": o.key.index.map(JSON.string) ?? .null]),
            "widgets": .array(o.widgets.map { w in
                .object([
                    "deviceId": .string(w.deviceId), "widgetType": .string(w.widgetType),
                    "name": .string(w.name), "page": page(w.page),
                    "entityIds": .array(w.entityIds.map(JSON.string)),
                ])
            }),
        ])
    }

    static func entity(_ e: EntityDescriptor) -> JSON {
        var o: [String: JSON] = ["id": .string(e.id), "name": .string(e.name), "icon": e.icon.map(JSON.string) ?? .null]
        switch e {
        case .toggle(let d):
            o["kind"] = "switch"
            o["state"] = valueRef(d.state)
            o["onAction"] = action(d.onAction)
            o["offAction"] = action(d.offAction)
            o["onIndication"] = .string(d.onIndication)
            o["offIndication"] = .string(d.offIndication)
        case .dimmableLight(let d):
            o["kind"] = "dimmableLight"
            o["state"] = valueRef(d.state)
            o["min"] = .number(d.min)
            o["max"] = .number(d.max)
            o["precision"] = .number(Double(d.precision))
            o["onAction"] = action(d.onAction)
            o["offAction"] = action(d.offAction)
            o["setValueAction"] = action(d.setValueAction)
        case .hsbLight(let d):
            o["kind"] = "hsbLight"
            o["powerState"] = valueRef(d.powerState)
            o["onAction"] = action(d.onAction)
            o["offAction"] = action(d.offAction)
            o["hue"] = channel(d.hue)
            o["saturation"] = channel(d.saturation)
            o["brightness"] = channel(d.brightness)
        case .contactSensor(let d):
            o["kind"] = "contactSensor"
            o["state"] = valueRef(d.state)
            o["reversed"] = .bool(d.reversed)
            o["onIndication"] = .string(d.onIndication)
            o["offIndication"] = .string(d.offIndication)
        case .sensor(let d):
            o["kind"] = "sensor"
            o["state"] = valueRef(d.state)
            o["sensorKind"] = .string(d.kind.rawValue)
            o["unit"] = d.kind.canonicalUnit.map(JSON.string) ?? .null
            o["grentonUnit"] = d.grentonUnit.map { .string($0.rawValue) } ?? .null
            o["valueType"] = d.valueType.map { .string($0.rawValue) } ?? .null
            o["precision"] = d.precision.map { .number(Double($0)) } ?? .null
        case .numberSetting(let d):
            o["kind"] = "numberSetting"
            o["state"] = valueRef(d.state)
            o["setValueAction"] = action(d.setValueAction)
            o["min"] = .number(d.min)
            o["max"] = .number(d.max)
            o["precision"] = .number(Double(d.precision))
        case .cover(let d):
            o["kind"] = "cover"
            o["motionState"] = valueRef(d.motionState)
            o["position"] = valueRef(d.position)
            o["setPositionAction"] = action(d.setPositionAction)
            o["tilt"] = d.tilt.map { .object(["position": valueRef($0.position), "setAction": action($0.setAction)]) } ?? .null
            o["stopAction"] = d.stopAction.map(action) ?? .null
        case .stateSensor(let d):
            o["kind"] = "stateSensor"
            o["state"] = valueRef(d.state)
        case .trigger(let d):
            o["kind"] = "trigger"
            o["action"] = action(d.action)
        case .sceneTrigger(let d):
            o["kind"] = "sceneTrigger"
            o["action"] = action(d.action)
        case .camera(let d):
            o["kind"] = "camera"
            o["streamUrl"] = .string(d.streamURL)
        case .thermostat(let d):
            func control(_ c: ThermostatDescriptor.Control?) -> JSON {
                c.map { .object(["state": valueRef($0.state), "setAction": action($0.setAction)]) } ?? .null
            }
            o["kind"] = "thermostat"
            o["currentTemperature"] = valueRef(d.currentTemperature)
            o["targetTemperature"] = valueRef(d.targetTemperature)
            o["setTargetTemperatureAction"] = action(d.setTargetTemperatureAction)
            o["minTemperature"] = d.minTemperature.map(valueRef) ?? .null
            o["maxTemperature"] = d.maxTemperature.map(valueRef) ?? .null
            o["mode"] = control(d.mode)
            o["power"] = control(d.power)
            o["output"] = d.output.map(valueRef) ?? .null
        case .eventSchedule(let d):
            o["kind"] = "eventSchedule"
            o["state"] = valueRef(d.state)
            o["ruleList"] = valueRef(d.ruleList)
            o["addRuleAction"] = action(d.addRuleAction)
            o["deleteRuleAction"] = action(d.deleteRuleAction)
            o["ruleCount"] = d.ruleCount.map(valueRef) ?? .null
            o["ruleSpace"] = d.ruleSpace.map(valueRef) ?? .null
            o["nextRule"] = d.nextRule.map(valueRef) ?? .null
            o["currentRule"] = d.currentRule.map(valueRef) ?? .null
            o["startAction"] = d.startAction.map(action) ?? .null
            o["stopAction"] = d.stopAction.map(action) ?? .null
            o["enableRuleAction"] = d.enableRuleAction.map(action) ?? .null
            o["disableRuleAction"] = d.disableRuleAction.map(action) ?? .null
        case .tvRemote(let d):
            o["kind"] = "tvRemote"
            var buttons: [String: JSON] = [:]
            for (button, a) in d.buttons { buttons[button.rawValue] = action(a) }
            o["buttons"] = .object(buttons)
        }
        return .object(o)
    }

    static func channel(_ c: HsbChannelDescriptor) -> JSON {
        .object([
            "state": valueRef(c.state),
            "setAction": action(c.setAction),
            "range": .object(["min": .number(c.range.min), "max": .number(c.range.max)]),
        ])
    }

    static func valueRef(_ ref: ValueRef) -> JSON {
        switch ref {
        case .variable(let cluId, let name):
            return .object(["callType": "VARIABLE", "cluId": .string(cluId), "index": .string(name)])
        case .attribute(let cluId, let objectName, let index):
            return .object(["callType": "ATTRIBUTE", "cluId": .string(cluId),
                            "objectName": .string(objectName), "index": .string(index)])
        }
    }

    static func action(_ a: ActionRef) -> JSON {
        var o: [String: JSON] = [
            "cluId": .string(a.cluId), "objectName": .string(a.objectName),
            "event": .string(a.event.rawValue), "value": .string(a.value),
        ]
        switch a.call {
        case .variable(let index): o["callType"] = "VARIABLE"; o["index"] = .string(index)
        case .attribute(let index): o["callType"] = "ATTRIBUTE"; o["index"] = .string(index)
        case .method(let index): o["callType"] = "METHOD"; o["index"] = .string(index)
        case .script: o["callType"] = "SCRIPT"
        }
        return .object(o)
    }
}

extension JSON: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}
