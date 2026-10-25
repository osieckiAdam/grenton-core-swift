// Widget DTOs and their discriminated union (spec §3.5). The union decodes
// the `type` discriminator and delegates to the concrete shape; an unknown
// discriminator throws, which at page level means the widget is skipped
// (spec §3.6).

public struct ValueV2WidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let unit: GrentonUnit
    public let valueType: GrentonValueType
    public let precision: Int
    public let object: ValueObjectDTO
}

public struct ValueDoubleWidgetDTO: Decodable, Sendable {
    public let id: String
    public let componentLeft: ValueDoubleComponentDTO
    public let componentRight: ValueDoubleComponentDTO
}

public struct OnOffWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [ButtonBistableComponentDTO]
}

public struct OnOffDoubleWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [ButtonBistableV2ComponentDTO]
}

public struct DimmerV2WidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let min: Double
    public let max: Double
    public let precision: Int
    public let object: DimmerV2ObjectDTO
}

public struct LedWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [LedComponentDTO]
}

public struct ContactSensorWidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let onIndication: String
    public let offIndication: String
    public let reverseState: Bool
    public let object: ContactSensorObjectDTO
}

public struct ContactSensorDoubleWidgetDTO: Decodable, Sendable {
    public let id: String
    public let componentLeft: ContactSensorDoubleComponentDTO
    public let componentRight: ContactSensorDoubleComponentDTO
}

public struct SliderWidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let unit: GrentonUnit
    public let min: Double
    public let max: Double
    public let precision: Int
    public let object: SliderObjectDTO
}

public struct MultisensorWidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let labelVisible: Bool
    public let objectAirCo2: MultisensorObjectDTO
    public let objectSound: MultisensorObjectDTO
    public let objectAirVoc: MultisensorObjectDTO
    public let objectLight: MultisensorObjectDTO
    public let objectPressure: MultisensorObjectDTO
    public let objectHumidity: MultisensorObjectDTO
    public let objectTemperature: MultisensorObjectDTO
}

public struct RollerShutterWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [RollerShutterComponentDTO]
}

public struct RollerShutterV3WidgetDTO: Decodable, Sendable {
    public let id: String
    public let icon: String
    public let label: String
    public let object: RollerShutterV3ObjectDTO
}

public struct CameraWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [CameraStreamComponentDTO]
}

public struct SceneWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [ButtonMonostableComponentDTO]
}

/// Two scene buttons side by side. Both components usually carry
/// `rowId` 0, so entities are suffixed by list position (spec §6.3.10).
public struct SceneDoubleWidgetDTO: Decodable, Sendable {
    public let id: String
    public let components: [ButtonMonostableComponentDTO]
}

public struct ThermostatV2WidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String?
    public let object: ThermostatV2ObjectDTO
}

// EVENT_SCHEDULER (spec §3.5).
/// An event scheduler widget: CRON rules on the EventScheduler virtual object.
public struct EventSchedulerWidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let object: EventSchedulerObjectDTO
}

// TV_REMOTE_CONTROL (spec §3.5): `object` maps button names to actions.
// Any subset, also none; an entry that is not an action is left out
// rather than failing the widget (§6.3.14).
/// A TV remote widget: named buttons, each an action.
public struct TvRemoteControlWidgetDTO: Decodable, Sendable {
    public let id: String
    public let label: String
    public let icon: String
    public let vodLabel: String
    /// The entries of `object` that parse as actions, by button name.
    public let buttons: [String: ActionRefDTO]

    enum CodingKeys: String, CodingKey { case id, label, icon, vodLabel, object }

    private struct Lenient: Decodable {
        let action: ActionRefDTO?
        init(from decoder: Decoder) throws { action = try? ActionRefDTO(from: decoder) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = try c.decode(String.self, forKey: .label)
        icon = try c.decode(String.self, forKey: .icon)
        vodLabel = try c.decode(String.self, forKey: .vodLabel)
        let raw = try c.decode([String: Lenient].self, forKey: .object)
        buttons = raw.compactMapValues(\.action)
    }
}

// MARK: - Union

/// One widget of the interface, by type.
@nonexhaustive
public enum WidgetDTO: Decodable, Sendable {
    case valueV2(ValueV2WidgetDTO)
    case valueDouble(ValueDoubleWidgetDTO)
    case onOff(OnOffWidgetDTO)
    case onOffDouble(OnOffDoubleWidgetDTO)
    case dimmerV2(DimmerV2WidgetDTO)
    case led(LedWidgetDTO)
    case contactSensor(ContactSensorWidgetDTO)
    case contactSensorDouble(ContactSensorDoubleWidgetDTO)
    case slider(SliderWidgetDTO)
    case multisensor(MultisensorWidgetDTO)
    case rollerShutter(RollerShutterWidgetDTO)
    case rollerShutterV3(RollerShutterV3WidgetDTO)
    case camera(CameraWidgetDTO)
    case scene(SceneWidgetDTO)
    case sceneDouble(SceneDoubleWidgetDTO)
    case thermostatV2(ThermostatV2WidgetDTO)
    case eventScheduler(EventSchedulerWidgetDTO)
    case tvRemoteControl(TvRemoteControlWidgetDTO)

    /// Known widget types that are pure UI layout (section headers): they
    /// produce no device and are not reported as skipped (spec §3.5).
    public static let presentationalTypes: Set<String> = ["HEADER"]

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeLiteralKey.self)
            .decode(String.self, forKey: .type)
        switch type {
        case "VALUE_V2": self = .valueV2(try ValueV2WidgetDTO(from: decoder))
        case "VALUE_DOUBLE": self = .valueDouble(try ValueDoubleWidgetDTO(from: decoder))
        case "ON_OFF": self = .onOff(try OnOffWidgetDTO(from: decoder))
        case "ON_OFF_DOUBLE": self = .onOffDouble(try OnOffDoubleWidgetDTO(from: decoder))
        case "DIMMER_V2": self = .dimmerV2(try DimmerV2WidgetDTO(from: decoder))
        case "LED": self = .led(try LedWidgetDTO(from: decoder))
        case "CONTACT_SENSOR": self = .contactSensor(try ContactSensorWidgetDTO(from: decoder))
        case "CONTACT_SENSOR_DOUBLE": self = .contactSensorDouble(try ContactSensorDoubleWidgetDTO(from: decoder))
        case "SLIDER": self = .slider(try SliderWidgetDTO(from: decoder))
        case "MULTISENSOR": self = .multisensor(try MultisensorWidgetDTO(from: decoder))
        case "ROLLER_SHUTTER": self = .rollerShutter(try RollerShutterWidgetDTO(from: decoder))
        case "ROLLER_SHUTTER_V3": self = .rollerShutterV3(try RollerShutterV3WidgetDTO(from: decoder))
        case "CAMERA": self = .camera(try CameraWidgetDTO(from: decoder))
        case "SCENE": self = .scene(try SceneWidgetDTO(from: decoder))
        case "SCENE_DOUBLE": self = .sceneDouble(try SceneDoubleWidgetDTO(from: decoder))
        case "THERMOSTAT_V2": self = .thermostatV2(try ThermostatV2WidgetDTO(from: decoder))
        case "EVENT_SCHEDULER": self = .eventScheduler(try EventSchedulerWidgetDTO(from: decoder))
        case "TV_REMOTE_CONTROL": self = .tvRemoteControl(try TvRemoteControlWidgetDTO(from: decoder))
        default: throw GrentonModelError.unknownDiscriminator(type)
        }
    }

    /// The widget's `type` discriminator as it appears on the wire.
    public var typeName: String {
        switch self {
        case .valueV2: return "VALUE_V2"
        case .valueDouble: return "VALUE_DOUBLE"
        case .onOff: return "ON_OFF"
        case .onOffDouble: return "ON_OFF_DOUBLE"
        case .dimmerV2: return "DIMMER_V2"
        case .led: return "LED"
        case .contactSensor: return "CONTACT_SENSOR"
        case .contactSensorDouble: return "CONTACT_SENSOR_DOUBLE"
        case .slider: return "SLIDER"
        case .multisensor: return "MULTISENSOR"
        case .rollerShutter: return "ROLLER_SHUTTER"
        case .rollerShutterV3: return "ROLLER_SHUTTER_V3"
        case .camera: return "CAMERA"
        case .scene: return "SCENE"
        case .sceneDouble: return "SCENE_DOUBLE"
        case .thermostatV2: return "THERMOSTAT_V2"
        case .eventScheduler: return "EVENT_SCHEDULER"
        case .tvRemoteControl: return "TV_REMOTE_CONTROL"
        }
    }

    /// The widget's stable identifier.
    public var id: String {
        switch self {
        case .valueV2(let w): return w.id
        case .valueDouble(let w): return w.id
        case .onOff(let w): return w.id
        case .onOffDouble(let w): return w.id
        case .dimmerV2(let w): return w.id
        case .led(let w): return w.id
        case .contactSensor(let w): return w.id
        case .contactSensorDouble(let w): return w.id
        case .slider(let w): return w.id
        case .multisensor(let w): return w.id
        case .rollerShutter(let w): return w.id
        case .rollerShutterV3(let w): return w.id
        case .camera(let w): return w.id
        case .scene(let w): return w.id
        case .sceneDouble(let w): return w.id
        case .thermostatV2(let w): return w.id
        case .eventScheduler(let w): return w.id
        case .tvRemoteControl(let w): return w.id
        }
    }
}
