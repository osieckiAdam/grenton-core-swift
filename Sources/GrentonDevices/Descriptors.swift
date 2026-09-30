import GrentonModel

/// Canonical device descriptors (spec §6.1 stage 1): pure values produced
/// from DTOs with no Runtime dependency. Entity `id`s follow the suffix
/// contract of spec §6.3 — they are the stable identity adapters key
/// their own configuration on.

public struct DeviceDescriptor: Sendable {
    /// The widget id.
    public let id: String
    /// Widget `type` discriminator (e.g. "ON_OFF") — device model name.
    public let typeName: String
    /// Canonical device kind, fixed per widget type (spec §6.1).
    public let kind: DeviceKind
    /// The interface page the widget sits on (spec §6.1).
    public let page: DevicePage
    /// The widget label, or the non-empty labels of its components joined
    /// with " / " for widgets without one (spec §6.1).
    public let name: String
    public let entities: [EntityDescriptor]
}

/// A page of the mobile interface: its position and its name.
public struct DevicePage: Hashable, Sendable {
    public let index: Int
    public let name: String

    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

/// What a device is, independent of the entities it exposes (spec §6.1).
public enum DeviceKind: String, Sendable, CaseIterable {
    case `switch`
    case dimmableLight
    case hsbLight
    case contactSensor
    case sensor
    case multisensor
    case numberSetting
    case cover
    case scene
    case camera
    case thermostat
}

public enum EntityDescriptor: Sendable {
    case toggle(ToggleDescriptor)
    case dimmableLight(DimmableLightDescriptor)
    case hsbLight(HsbLightDescriptor)
    case contactSensor(ContactSensorDescriptor)
    case sensor(SensorDescriptor)
    case numberSetting(NumberSettingDescriptor)
    case cover(CoverDescriptor)
    case stateSensor(StateSensorDescriptor)
    case trigger(TriggerDescriptor)
    case sceneTrigger(SceneTriggerDescriptor)
    case camera(CameraDescriptor)
    case thermostat(ThermostatDescriptor)

    public var id: String {
        switch self {
        case .toggle(let d): return d.id
        case .dimmableLight(let d): return d.id
        case .hsbLight(let d): return d.id
        case .contactSensor(let d): return d.id
        case .sensor(let d): return d.id
        case .numberSetting(let d): return d.id
        case .cover(let d): return d.id
        case .stateSensor(let d): return d.id
        case .trigger(let d): return d.id
        case .sceneTrigger(let d): return d.id
        case .camera(let d): return d.id
        case .thermostat(let d): return d.id
        }
    }

    public var name: String {
        switch self {
        case .toggle(let d): return d.name
        case .dimmableLight(let d): return d.name
        case .hsbLight(let d): return d.name
        case .contactSensor(let d): return d.name
        case .sensor(let d): return d.name
        case .numberSetting(let d): return d.name
        case .cover(let d): return d.name
        case .stateSensor(let d): return d.name
        case .trigger(let d): return d.name
        case .sceneTrigger(let d): return d.name
        case .camera(let d): return d.name
        case .thermostat(let d): return d.name
        }
    }

    /// The CLU object this entity operates (spec §6.6): its primary state
    /// ref, or its action when it has no state. `nil` for a camera, which
    /// involves no CLU object.
    public var objectKey: ObjectKey? {
        switch self {
        case .toggle(let d): return ObjectKey(d.state)
        case .dimmableLight(let d): return ObjectKey(d.state)
        case .hsbLight(let d): return ObjectKey(d.powerState)
        case .contactSensor(let d): return ObjectKey(d.state)
        case .sensor(let d): return ObjectKey(d.state)
        case .numberSetting(let d): return ObjectKey(d.state)
        case .cover(let d): return ObjectKey(d.position)
        case .stateSensor(let d): return ObjectKey(d.state)
        case .trigger(let d): return ObjectKey(d.action)
        case .sceneTrigger(let d): return ObjectKey(d.action)
        case .thermostat(let d): return ObjectKey(d.currentTemperature)
        case .camera: return nil
        }
    }

    /// Every ValueRef this entity reads — the binder registers them for
    /// subscription; entity update streams filter on them.
    public var stateRefs: [ValueRef] {
        switch self {
        case .toggle(let d): return [d.state]
        case .dimmableLight(let d): return [d.state]
        case .hsbLight(let d):
            return [d.powerState, d.hue.state, d.saturation.state, d.brightness.state]
        case .contactSensor(let d): return [d.state]
        case .sensor(let d): return [d.state]
        case .numberSetting(let d): return [d.state]
        case .cover(let d):
            var refs = [d.motionState, d.position]
            if let tilt = d.tilt { refs.append(tilt.position) }
            return refs
        case .stateSensor(let d): return [d.state]
        case .thermostat(let d):
            var refs = [d.currentTemperature, d.targetTemperature]
            refs += [d.minTemperature, d.maxTemperature, d.mode?.state, d.power?.state, d.output].compactMap { $0 }
            return refs
        case .trigger, .sceneTrigger, .camera: return []
        }
    }
}

// MARK: - Concrete descriptors

/// Switch (spec §6.3.1).
public struct ToggleDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
    public let onAction: ActionRef
    public let offAction: ActionRef
    public let onIndication: String
    public let offIndication: String
}

/// Dimmable light (spec §6.3.2).
public struct DimmableLightDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
    public let min: Double
    public let max: Double
    public let precision: Int
    public let onAction: ActionRef
    public let offAction: ActionRef
    public let setValueAction: ActionRef
}

/// One HSB channel: where to read it, how to set it, the device range.
public struct HsbChannelDescriptor: Sendable {
    public let state: ValueRef
    public let setAction: ActionRef
    public let range: (min: Double, max: Double)

    public init(state: ValueRef, setAction: ActionRef, range: (min: Double, max: Double)) {
        self.state = state
        self.setAction = setAction
        self.range = range
    }
}

/// HSB light (spec §6.3.3).
public struct HsbLightDescriptor: Sendable {
    public let id: String
    public let name: String
    public let powerState: ValueRef
    public let onAction: ActionRef
    public let offAction: ActionRef
    public let hue: HsbChannelDescriptor
    public let saturation: HsbChannelDescriptor
    public let brightness: HsbChannelDescriptor
}

/// Contact sensor (spec §6.3.4).
public struct ContactSensorDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
    public let reversed: Bool
    public let onIndication: String
    public let offIndication: String
}

/// Fixed multisensor channel kinds with canonical units (spec §6.3.6).
public enum SensorKind: String, Sendable {
    case generic
    case co2
    case soundPressure
    case voc
    case illuminance
    case pressure
    case humidity
    case temperature

    public var canonicalUnit: String? {
        switch self {
        case .generic: return nil
        case .co2: return "ppm"
        case .soundPressure: return "dB"
        case .voc: return "ppb"
        case .illuminance: return "lx"
        case .pressure: return "hPa"
        case .humidity: return "%"
        case .temperature: return "°C"
        }
    }
}

/// Numeric/text sensor (spec §6.3.5–§6.3.6).
public struct SensorDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
    public let kind: SensorKind
    /// Presentation metadata from the widget — adapters decide how to use it.
    public let grentonUnit: GrentonUnit?
    public let valueType: GrentonValueType?
    public let precision: Int?
}

/// Settable number (spec §6.3.7).
public struct NumberSettingDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
    public let setValueAction: ActionRef
    public let min: Double
    public let max: Double
    public let precision: Int
}

/// Cover with optional tilt and stop (spec §6.3.8).
public struct CoverDescriptor: Sendable {
    public struct Tilt: Sendable {
        public let position: ValueRef
        public let setAction: ActionRef
    }

    public let id: String
    public let name: String
    /// Raw motion enum: 0 idle, 1 opening, 2 closing.
    public let motionState: ValueRef
    /// Raw position 0...100 (0 = closed).
    public let position: ValueRef
    public let setPositionAction: ActionRef
    public let tilt: Tilt?
    public let stopAction: ActionRef?
}

/// Legacy roller-shutter state sensor (spec §6.3.9):
/// 0 stopped, 1 opening, 2 closing, 3 locked, else unknown.
public struct StateSensorDescriptor: Sendable {
    public let id: String
    public let name: String
    public let state: ValueRef
}

/// Plain push button executing one action (spec §6.3.9).
public struct TriggerDescriptor: Sendable {
    public let id: String
    public let name: String
    public let action: ActionRef
}

/// Scene trigger — a SCRIPT action with an overridable parameter (spec §6.3.10).
public struct SceneTriggerDescriptor: Sendable {
    public let id: String
    public let name: String
    public let action: ActionRef
}

/// Camera stream (spec §6.3.11) — Core only carries the URL.
public struct CameraDescriptor: Sendable {
    public let id: String
    public let name: String
    public let streamURL: String
}

/// Thermostat (spec §6.3.12) — a Grenton Thermostat virtual object.
public struct ThermostatDescriptor: Sendable {
    /// A readable feature with the action that writes it.
    public struct Control: Sendable {
        public let state: ValueRef
        public let setAction: ActionRef
    }

    public let id: String
    public let name: String
    public let currentTemperature: ValueRef
    /// Effective target (TargetTemp) — follows the mode (manual/holiday/schedule).
    public let targetTemperature: ValueRef
    /// Writes the manual set point (PointValue).
    public let setTargetTemperatureAction: ActionRef
    public let minTemperature: ValueRef?
    public let maxTemperature: ValueRef?
    /// Mode feature: 0 manual, 1 holiday, 2 schedule.
    public let mode: Control?
    /// State feature: 0 stopped, 1 running.
    public let power: Control?
    /// ControlOutValue — what the thermostat drives its output with.
    public let output: ValueRef?
}

// MARK: - Physical objects (spec §6.6)

/// Identity of what a widget actually operates on a CLU: an object's
/// feature (THE1001 / 14), a variable, or a script. Several widgets (on
/// different pages, under different names) can operate the same one. The
/// index matters: one LED module drives separate strips on separate
/// channels (LED1001 / 3 and / 4).
public struct ObjectKey: Hashable, Sendable {
    public enum Kind: String, Sendable {
        /// An object such as THE1001 or DOU1001 (attribute/method calls).
        case object
        /// A CLU global variable.
        case variable
        /// A Lua script (scene).
        case script
    }

    public let cluId: String
    public let kind: Kind
    public let name: String
    /// Feature (attribute) or method index for `.object`; `nil` otherwise.
    public let index: String?

    public init(cluId: String, kind: Kind, name: String, index: String? = nil) {
        self.cluId = cluId
        self.kind = kind
        self.name = name
        self.index = index
    }

    init(_ ref: ValueRef) {
        switch ref {
        case .variable(let cluId, let name):
            self.init(cluId: cluId, kind: .variable, name: name)
        case .attribute(let cluId, let objectName, let index):
            self.init(cluId: cluId, kind: .object, name: objectName, index: index)
        }
    }

    init(_ action: ActionRef) {
        switch action.call {
        case .variable(let index):
            self.init(cluId: action.cluId, kind: .variable, name: index)
        case .attribute(let index), .method(let index):
            self.init(cluId: action.cluId, kind: .object, name: action.objectName, index: index)
        case .script:
            self.init(cluId: action.cluId, kind: .script, name: action.objectName)
        }
    }
}

/// One CLU object and every widget that operates it (spec §6.6).
public struct PhysicalObject: Sendable {
    /// A widget's view of the object: which device, where, and which of
    /// its entities belong to this object.
    public struct Widget: Sendable {
        public let deviceId: String
        public let widgetType: String
        public let name: String
        public let page: DevicePage
        public let entityIds: [String]
    }

    public let key: ObjectKey
    /// In device order.
    public let widgets: [Widget]
}
