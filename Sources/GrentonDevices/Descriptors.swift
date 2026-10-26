import GrentonModel

// Canonical device descriptors (spec §6.1 stage 1): pure values produced
// from DTOs with no Runtime dependency. Entity `id`s follow the suffix
// contract of spec §6.3 — they are the stable identity adapters key
// their own configuration on.

/// A device as plain data: one widget of the interface, without state or commands.
///
/// ``DeviceMapper`` makes these from an interface with no network access, which is enough to list an installation's devices.
public struct DeviceDescriptor: Identifiable, Sendable {
    // The widget id.
    /// The widget id, stable across restarts.
    public let id: String
    // Widget `type` discriminator (e.g. "ON_OFF") — device model name.
    /// The widget type as Object Manager names it, such as `ON_OFF` or `THERMOSTAT_V2`.
    public let typeName: String
    // Canonical device kind, fixed per widget type (spec §6.1).
    /// What the device is, such as a switch, a thermostat or a shutter.
    public let kind: DeviceKind
    // The interface page the widget sits on (spec §6.1).
    /// The interface page the widget is on.
    public let page: DevicePage
    /// The section header above the widget on its page, as the app groups it; `nil` above the first header or on a page without one.
    public let section: DeviceSection?
    // The widget label, or the non-empty labels of its components joined
    // with " / " for widgets without one (spec §6.1).
    /// The widget's label, or its components' labels joined with " / " when the widget has none (such as a double switch).
    public let name: String
    /// The things you read and control on this device.
    public let entities: [EntityDescriptor]
}

/// The section header a device is shown under in the myGrenton app (spec §6.1).
public struct DeviceSection: Hashable, Sendable {
    /// The header widget's id.
    public let id: String
    /// The header's text.
    public let title: String

    /// Creates a section reference.
    public init(id: String, title: String) {
        self.id = id
        self.title = title
    }
}

// A page of the mobile interface: its position and its name.
/// A page of the mobile interface.
public struct DevicePage: Hashable, Sendable {
    /// The page's position, from 0.
    public let index: Int
    /// The page's title, often a room.
    public let name: String

    /// Creates a page reference.
    public init(index: Int, name: String) {
        self.index = index
        self.name = name
    }
}

// What a device is, independent of the entities it exposes (spec §6.1).
/// What a device is, whichever entities it has.
///
/// A door sensor with a button is still a ``contactSensor``.
@nonexhaustive
public enum DeviceKind: String, Sendable, CaseIterable {
    /// An on/off switch.
    case `switch`
    /// A dimmable light.
    case dimmableLight
    /// A colour (RGB) light.
    case hsbLight
    /// A door or window contact.
    case contactSensor
    /// A value sensor.
    case sensor
    /// A multisensor with fixed channels (temperature, humidity, CO₂…).
    case multisensor
    /// A settable number.
    case numberSetting
    /// A roller shutter or blind.
    case cover
    /// One or more scenes.
    case scene
    /// A camera.
    case camera
    /// A thermostat.
    case thermostat
    /// An event scheduler: rules that fire at a time of day on chosen weekdays.
    case eventSchedule
    /// A TV remote: a set of buttons.
    case tvRemote
}

/// An entity as plain data: what it reads and which actions it sends. `GrentonSystem` turns it into a live ``BoundEntity``.
@nonexhaustive
public enum EntityDescriptor: Identifiable, Sendable {
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
    case eventSchedule(EventScheduleDescriptor)
    case tvRemote(TvRemoteDescriptor)

    /// The stable id: the widget id plus a suffix.
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
        case .eventSchedule(let d): return d.id
        case .tvRemote(let d): return d.id
        }
    }

    /// The label from the mobile interface.
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
        case .eventSchedule(let d): return d.name
        case .tvRemote(let d): return d.name
        }
    }

    // The CLU object this entity operates (spec §6.6): its primary state
    // ref, or its action when it has no state. `nil` for a camera, which
    // involves no CLU object.
    /// What the entity operates on the CLU; `nil` for a camera. Entities with the same key control the same hardware.
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
        case .eventSchedule(let d): return ObjectKey(d.state)
        // A remote's buttons may each drive a different object (spec §6.6).
        case .camera, .tvRemote: return nil
        }
    }

    // Every ValueRef this entity reads — the binder registers them for
    // subscription; entity update streams filter on them.
    /// Every CLU value the entity reads.
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
        case .eventSchedule(let d):
            return [d.state, d.ruleList] + [d.ruleCount, d.ruleSpace, d.nextRule, d.currentRule].compactMap { $0 }
        case .trigger, .sceneTrigger, .camera, .tvRemote: return []
        }
    }
}

// Event scheduler (spec §6.3.13).
/// The description of an ``EventScheduleEntity``: its state references and actions.
public struct EventScheduleDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The State feature: 1 while the scheduler fires its rules.
    public let state: ValueRef
    /// The RuleList feature: every rule as the CLU serializes them.
    public let ruleList: ValueRef
    /// Adds a rule; its value is the CRON text.
    public let addRuleAction: ActionRef
    /// Deletes a rule by its number.
    public let deleteRuleAction: ActionRef
    /// The RuleCount feature, if the interface exposes it.
    public let ruleCount: ValueRef?
    /// The RuleAvailableCount feature (free of 16), if exposed.
    public let ruleSpace: ValueRef?
    /// The NextRule feature, if exposed.
    public let nextRule: ValueRef?
    /// The CurrentRule feature, if exposed.
    public let currentRule: ValueRef?
    /// Starts the scheduler, if the interface exposes it.
    public let startAction: ActionRef?
    /// Stops the scheduler, if exposed.
    public let stopAction: ActionRef?
    /// Enables a rule by its number, if exposed.
    public let enableRuleAction: ActionRef?
    /// Disables a rule by its number, if exposed.
    public let disableRuleAction: ActionRef?
}

/// A button of a TV remote (spec §3.5).
@nonexhaustive
public enum TvRemoteButton: String, Sendable, CaseIterable {
    case on, off, up, down, left, right, ok, menu, back, guide, play, pause
    case fastForward, fastRewind, nextChannel, previousChannel, volumeUp, volumeDown, mute, vod, `init`
}

// TV remote (spec §6.3.14).
/// The description of a ``TvRemoteEntity``: the actions behind its buttons.
public struct TvRemoteDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The label of the VOD button.
    public let vodLabel: String
    /// The buttons the remote has, with their actions; empty before any button is assigned in Object Manager.
    public let buttons: [TvRemoteButton: ActionRef]
}

// MARK: - Concrete descriptors

// Switch (spec §6.3.1).
/// The description of a ``ToggleEntity``: its id, name, and the references and actions it uses.
public struct ToggleDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// The action that turns it on.
    public let onAction: ActionRef
    /// The action that turns it off.
    public let offAction: ActionRef
    /// The label the widget shows when on.
    public let onIndication: String
    /// The label the widget shows when off.
    public let offIndication: String
}

// Dimmable light (spec §6.3.2).
/// The description of a ``DimmableLightEntity``: its id, name, and the references and actions it uses.
public struct DimmableLightDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// The lowest device value.
    public let min: Double
    /// The highest device value.
    public let max: Double
    /// How many decimals values are rounded to.
    public let precision: Int
    /// The action that turns it on.
    public let onAction: ActionRef
    /// The action that turns it off.
    public let offAction: ActionRef
    /// The action that sets a new value; its value is replaced when sent.
    public let setValueAction: ActionRef
}

// One HSB channel: where to read it, how to set it, the device range.
/// The range a device uses for one channel, such as 0…255 for brightness.
public struct ChannelRange: Equatable, Sendable {
    /// The lowest device value.
    public let min: Double
    /// The highest device value.
    public let max: Double

    /// Creates a range.
    public init(min: Double, max: Double) {
        self.min = min
        self.max = max
    }

    package var tuple: (min: Double, max: Double) { (min, max) }
}

/// One channel of an RGB light — hue, saturation or brightness — with the
/// value it reads, the action that sets it and the device's range for it.
public struct HsbChannelDescriptor: Sendable {
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// The action that sets this value; its value is replaced when sent.
    public let setAction: ActionRef
    /// The device's range for this channel.
    public let range: ChannelRange

    /// Creates a channel.
    public init(state: ValueRef, setAction: ActionRef, range: ChannelRange) {
        self.state = state
        self.setAction = setAction
        self.range = range
    }
}

// HSB light (spec §6.3.3).
/// The description of a ``HsbLightEntity``: its id, name, and the references and actions it uses.
public struct HsbLightDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value that says whether the light is on.
    public let powerState: ValueRef
    /// The action that turns it on.
    public let onAction: ActionRef
    /// The action that turns it off.
    public let offAction: ActionRef
    /// The hue channel.
    public let hue: HsbChannelDescriptor
    /// The saturation channel.
    public let saturation: HsbChannelDescriptor
    /// The brightness channel.
    public let brightness: HsbChannelDescriptor
}

// Contact sensor (spec §6.3.4).
/// The description of a ``ContactSensorEntity``: its id, name, and the references and actions it uses.
public struct ContactSensorDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// Whether the sensor's reading is inverted (the widget's “reverse state”).
    public let reversed: Bool
    /// The label the widget shows when on.
    public let onIndication: String
    /// The label the widget shows when off.
    public let offIndication: String
}

// Fixed multisensor channel kinds with canonical units (spec §6.3.6).
/// What a sensor measures. Multisensor channels have a fixed kind and unit; other sensors are ``generic``.
@nonexhaustive
public enum SensorKind: String, Sendable {
    case generic
    case co2
    case soundPressure
    case voc
    case illuminance
    case pressure
    case humidity
    case temperature

    /// The unit of the measured value, such as `"°C"` or `"ppm"`; `nil` for ``generic`` sensors, whose unit comes from the widget.
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

// Numeric/text sensor (spec §6.3.5–§6.3.6).
/// The description of a ``SensorEntity``: what it measures and how to present it.
public struct SensorDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// What the sensor measures.
    public let kind: SensorKind
    // Presentation metadata from the widget — adapters decide how to use it.
    /// The unit chosen in Object Manager, for ``SensorKind/generic`` sensors.
    public let grentonUnit: GrentonUnit?
    /// Whether the widget shows the value as text, a decimal or an integer.
    public let valueType: GrentonValueType?
    /// How many decimals the widget shows.
    public let precision: Int?
}

// Settable number (spec §6.3.7).
/// The description of a ``NumberSettingEntity``: its id, name, and the references and actions it uses.
public struct NumberSettingDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
    /// The action that sets a new value; its value is replaced when sent.
    public let setValueAction: ActionRef
    /// The lowest device value.
    public let min: Double
    /// The highest device value.
    public let max: Double
    /// How many decimals values are rounded to.
    public let precision: Int
}

// Cover with optional tilt and stop (spec §6.3.8).
/// The description of a ``CoverEntity``: its id, name, and the references and actions it uses.
public struct CoverDescriptor: Sendable {
    /// The slats of a shutter: where their tilt is read and how it is set.
    public struct Tilt: Sendable {
        /// The CLU value holding the position.
        public let position: ValueRef
        /// The action that sets this value; its value is replaced when sent.
        public let setAction: ActionRef
    }

    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// Raw motion enum: 0 idle, 1 opening, 2 closing.
    public let motionState: ValueRef
    /// Raw position 0...100 (0 = closed).
    public let position: ValueRef
    /// The action that moves it to a position.
    public let setPositionAction: ActionRef
    /// The slats, when the shutter has them.
    public let tilt: Tilt?
    /// The action that stops it; `nil` when the widget has none.
    public let stopAction: ActionRef?
}

// Legacy roller-shutter state sensor (spec §6.3.9):
// 0 stopped, 1 opening, 2 closing, 3 locked, else unknown.
/// The description of a ``StateSensorEntity``: its id, name, and the references and actions it uses.
public struct StateSensorDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value the entity reads.
    public let state: ValueRef
}

// Plain push button executing one action (spec §6.3.9).
/// The description of a ``TriggerEntity``: its id, name, and the references and actions it uses.
public struct TriggerDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The action it runs.
    public let action: ActionRef
}

// Scene trigger — a SCRIPT action with an overridable parameter (spec §6.3.10).
/// The description of a ``SceneTriggerEntity``: its id, name, and the references and actions it uses.
public struct SceneTriggerDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The action it runs.
    public let action: ActionRef
}

// Camera stream (spec §6.3.11) — Core only carries the URL.
/// The description of a ``CameraEntity``: its id, name, and the references and actions it uses.
public struct CameraDescriptor: Sendable {
    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The stream address, such as an RTSP URL.
    public let streamURL: String
}

// Thermostat (spec §6.3.12) — a Grenton Thermostat virtual object.
/// The description of a ``ThermostatEntity``: its id, name, and the references and actions it uses.
public struct ThermostatDescriptor: Sendable {
    /// A readable feature with the action that writes it.
    public struct Control: Sendable {
        /// The CLU value the entity reads.
        public let state: ValueRef
        /// The action that sets this value; its value is replaced when sent.
        public let setAction: ActionRef
    }

    /// The entity's stable id: the widget id plus a suffix.
    public let id: String
    /// The label from the mobile interface.
    public let name: String
    /// The CLU value with the measured temperature.
    public let currentTemperature: ValueRef
    /// Effective target (TargetTemp) — follows the mode (manual/holiday/schedule).
    public let targetTemperature: ValueRef
    /// Writes the manual set point (PointValue).
    public let setTargetTemperatureAction: ActionRef
    /// The CLU value with the lowest allowed target, if exposed.
    public let minTemperature: ValueRef?
    /// The CLU value with the highest allowed target, if exposed.
    public let maxTemperature: ValueRef?
    /// Mode feature: 0 manual, 1 holiday, 2 schedule.
    public let mode: Control?
    /// State feature: 0 stopped, 1 running.
    public let power: Control?
    /// ControlOutValue — what the thermostat drives its output with.
    public let output: ValueRef?
}

// MARK: - Physical objects (spec §6.6)

// Identity of what a widget actually operates on a CLU: an object's
// feature (THE1001 / 14), a variable, or a script. Several widgets (on
// different pages, under different names) can operate the same one. The
// index matters: one LED module drives separate strips on separate
// channels (LED1001 / 3 and / 4).
/// What an entity operates on a CLU: a feature of an object (such as a thermostat's temperature), a variable, or a script.
///
/// Entities with equal keys control the same hardware, even when they come from different widgets.
public struct ObjectKey: Hashable, Sendable {
    /// The kind of thing on the CLU.
    @nonexhaustive
    public enum Kind: String, Sendable {
        /// An object such as THE1001 or DOU1001 (attribute/method calls).
        case object
        /// A CLU global variable.
        case variable
        /// A Lua script (scene).
        case script
    }

    /// The CLU the object lives on.
    public let cluId: String
    /// Object feature, variable or script.
    public let kind: Kind
    /// The object, variable or script name on the CLU, such as `THE1001`.
    public let name: String
    // Feature (attribute) or method index for `.object`; `nil` otherwise.
    /// The feature index for an object, such as `14` for a thermostat's temperature; `nil` for variables and scripts.
    public let index: String?

    /// Creates a key.
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

// One CLU object and every widget that operates it (spec §6.6).
/// One piece of hardware on a CLU and every widget that shows it.
///
/// Get the list from ``GrentonSystem/physicalObjects``.
public struct PhysicalObject: Identifiable, Sendable {
    /// The object's key, which identifies it.
    public var id: ObjectKey { key }
    // A widget's view of the object: which device, where, and which of
    // its entities belong to this object.
    /// One widget showing the object.
    public struct Widget: Sendable {
        /// The id of the device (widget).
        public let deviceId: String
        /// The widget type, such as `THERMOSTAT_V2`.
        public let widgetType: String
        /// The widget's name, which can differ between pages.
        public let name: String
        /// The page the widget is on.
        public let page: DevicePage
        /// The widget's entities that operate this object.
        public let entityIds: [String]
    }

    /// What the widgets operate.
    public let key: ObjectKey
    // In device order.
    /// The widgets, in device order.
    public let widgets: [Widget]
}
