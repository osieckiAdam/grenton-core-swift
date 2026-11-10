import Foundation
import GrentonModel
import GrentonRuntime
import GrentonDevices

/// The `entities` profile (`spec/conformance.md` §4e): the production mapper
/// and binder over a state store the case fills, with a command sink in
/// place of the CLU sessions. The handlers read the entity's public state
/// and call its public intents; no normalization lives here.
enum EntityOperations {
    /// Records every action an entity asks to execute, in order.
    final class Sink: CommandExecuting, @unchecked Sendable {
        private let lock = NSLock()
        private var actions: [ActionRef] = []
        var executed: [ActionRef] { lock.withLock { actions } }
        func execute(_ action: ActionRef) async throws { lock.withLock { actions.append(action) } }
    }

    static func run(_ operation: String, _ input: JSON) async throws -> JSON {
        let data = try Data(contentsOf: ConformanceSuite.conformanceRoot
            .appendingPathComponent(try string(input, "fixture")))
        let interface = try MobileInterfaceDTO.decode(from: data)
        let store = StateStore()
        let sink = Sink()
        let devices = DeviceBinder.bind(DeviceMapper.descriptors(for: interface),
                                        context: DeviceContext(store: store, executor: sink))
        for entry in input["values"]?.arrayValue ?? [] {
            guard let key = entry["key"] else { throw SuiteError("entity: value without key") }
            let ref = try valueRef(key)
            store.registerKey(ref)
            store.updateKeys([ref], [.value(try Operations.untagged(entry["value"]))], includingUnknown: true)
        }
        let entityId = try string(input, "entityId")
        guard let entity = devices.flatMap(\.entities).first(where: { $0.id == entityId }) else {
            throw SuiteError("entity: the mapping produces no entity \(entityId)")
        }
        if operation == "entity.read" {
            return Operations.ok(["state": .object(try state(entity))])
        }
        let args = input["args"] ?? .object([:])
        let sent = try await intent(entity, try string(input, "intent"), args)
        if !sent {
            // A refusal must also send nothing (§4e).
            guard sink.executed.isEmpty else { throw SuiteError("entity: refused, but sent \(sink.executed)") }
            return Operations.reject
        }
        return Operations.ok(["actions": .array(sink.executed.map(MappingProjection.action))])
    }

    // MARK: - Reads

    static func state(_ entity: BoundEntity) throws -> [String: JSON] {
        switch entity {
        case .toggle(let e):
            return ["isOn": Operations.optionalBool(e.isOn)]
        case .dimmableLight(let e):
            return ["isOn": Operations.optionalBool(e.isOn), "brightness": double(e.brightness)]
        case .hsbLight(let e):
            return ["isOn": Operations.optionalBool(e.isOn), "hue": double(e.hue),
                    "saturation": double(e.saturation), "brightness": double(e.brightness)]
        case .contactSensor(let e):
            return ["isActive": Operations.optionalBool(e.isActive)]
        case .sensor(let e):
            return ["value": e.value.map(Operations.tagged) ?? .null]
        case .numberSetting(let e):
            return ["value": double(e.value)]
        case .cover(let e):
            let motion: String
            switch e.motion {
            case .idle: motion = "idle"
            case .opening: motion = "opening"
            case .closing: motion = "closing"
            default: motion = "unknown"
            }
            return ["position": int(e.position), "isClosed": Operations.optionalBool(e.isClosed),
                    "motion": .string(motion), "tilt": int(e.tilt)]
        case .stateSensor(let e):
            return ["state": .string(e.state.rawValue)]
        case .thermostat(let e):
            let mode: JSON
            switch e.mode {
            case .manual?: mode = "manual"
            case .holiday?: mode = "holiday"
            case .schedule?: mode = "schedule"
            default: mode = .null
            }
            return ["currentTemperature": double(e.currentTemperature),
                    "targetTemperature": double(e.targetTemperature),
                    "minTemperature": double(e.minTemperature), "maxTemperature": double(e.maxTemperature),
                    "output": double(e.output), "mode": mode, "isOn": Operations.optionalBool(e.isActive)]
        case .eventSchedule(let e):
            return ["isActive": Operations.optionalBool(e.isActive),
                    "rules": e.rules.map { .array($0.map(Operations.rule)) } ?? .null,
                    "ruleCount": int(e.ruleCount), "freeRuleSlots": int(e.freeRuleSlots),
                    "nextRule": e.nextRule.map(Operations.rule) ?? .null,
                    "currentRule": e.currentRule.map(Operations.rule) ?? .null]
        default:
            throw SuiteError("entity.read: \(entity.id) has no state")
        }
    }

    // MARK: - Intents

    /// Calls the intent; `false` when the entity refused the input.
    static func intent(_ entity: BoundEntity, _ name: String, _ args: JSON) async throws -> Bool {
        func number(_ key: String) throws -> Double {
            guard case .number(let n)? = args[key] else { throw SuiteError("intent \(name): no number `\(key)`") }
            return n
        }
        func integer(_ key: String) throws -> Int {
            guard let i = args[key]?.intValue else { throw SuiteError("intent \(name): no integer `\(key)`") }
            return i
        }
        func text(_ key: String) throws -> String {
            guard let s = args[key]?.stringValue else { throw SuiteError("intent \(name): no string `\(key)`") }
            return s
        }
        switch (entity, name) {
        case (.toggle(let e), "turnOn"): try await e.turnOn()
        case (.toggle(let e), "turnOff"): try await e.turnOff()
        case (.dimmableLight(let e), "turnOn"): try await e.turnOn()
        case (.dimmableLight(let e), "turnOff"): try await e.turnOff()
        case (.dimmableLight(let e), "setBrightness"): try await e.setBrightness(try number("brightness"))
        case (.hsbLight(let e), "turnOn"): try await e.turnOn()
        case (.hsbLight(let e), "turnOff"): try await e.turnOff()
        case (.hsbLight(let e), "setColor"): try await e.setColor(hue: try number("hue"), saturation: try number("saturation"))
        case (.hsbLight(let e), "setBrightness"): try await e.setBrightness(try number("brightness"))
        case (.numberSetting(let e), "setValue"): try await e.setValue(try number("value"))
        case (.cover(let e), "open"): try await e.open()
        case (.cover(let e), "close"): try await e.close()
        case (.cover(let e), "stop"): try await e.stop()
        case (.cover(let e), "openTilt"): try await e.openTilt()
        case (.cover(let e), "closeTilt"): try await e.closeTilt()
        case (.cover(let e), "setPosition"): try await e.setPosition(try integer("position"))
        case (.cover(let e), "setTilt"): try await e.setTilt(try integer("tilt"))
        case (.trigger(let e), "press"): try await e.press()
        case (.sceneTrigger(let e), "run"):
            if args["parameter"] != nil { try await e.run(parameter: try text("parameter")) } else { try await e.run() }
        case (.thermostat(let e), "setTargetTemperature"): try await e.setTargetTemperature(try number("temperature"))
        case (.thermostat(let e), "setMode"):
            let modes: [String: ThermostatMode] = ["manual": .manual, "holiday": .holiday, "schedule": .schedule]
            guard let mode = modes[try text("mode")] else { throw SuiteError("intent setMode: unknown mode") }
            try await e.setMode(mode)
        case (.thermostat(let e), "turnOn"): try await e.setActive(true)
        case (.thermostat(let e), "turnOff"): try await e.setActive(false)
        case (.eventSchedule(let e), "setActive"):
            guard let active = args["active"]?.boolValue else { throw SuiteError("intent setActive: no `active`") }
            try await e.setActive(active)
        case (.eventSchedule(let e), "addRule"):
            guard case .array(let values)? = args["days"] else { throw SuiteError("intent addRule: no `days`") }
            let days = try Set(values.map { value -> Weekday in
                guard let raw = value.intValue, let day = Weekday(rawValue: raw) else {
                    throw SuiteError("intent addRule: day \(value) outside 0–6")
                }
                return day
            })
            return try await e.addRule(hour: try integer("hour"), minute: try integer("minute"), days: days)
        case (.eventSchedule(let e), "deleteRule"): try await e.deleteRule(try integer("id"))
        case (.eventSchedule(let e), "enableRule"): try await e.enableRule(try integer("id"))
        case (.eventSchedule(let e), "disableRule"): try await e.disableRule(try integer("id"))
        case (.tvRemote(let e), "press"):
            guard let button = TvRemoteButton(rawValue: try text("button")) else {
                throw SuiteError("intent press: unknown button")
            }
            try await e.press(button)
        default:
            throw SuiteError("entity.intent: \(entity.id) has no intent \(name)")
        }
        return true
    }

    // MARK: - Helpers

    static func valueRef(_ json: JSON) throws -> ValueRef {
        let cluId = try string(json, "cluId"), index = try string(json, "index")
        switch json["callType"]?.stringValue {
        case "VARIABLE": return .variable(cluId: cluId, name: index)
        case "ATTRIBUTE": return .attribute(cluId: cluId, objectName: try string(json, "objectName"), index: index)
        default: throw SuiteError("bad ValueRef \(json)")
        }
    }

    static func double(_ value: Double?) -> JSON { value.map { Operations.tagged(.double($0)) } ?? .null }

    static func int(_ value: Int?) -> JSON { value.map { Operations.tagged(.int(Int64($0))) } ?? .null }

    static func string(_ json: JSON, _ key: String) throws -> String {
        guard let value = json[key]?.stringValue else { throw SuiteError("missing string `\(key)`") }
        return value
    }
}
