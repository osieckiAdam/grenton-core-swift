/// Component DTOs (spec §3.5). List components carry `label`/`rowId`/`unit`;
/// the double-widget components are standalone shapes without `rowId`.
///
/// Components with a fixed `type` literal follow the reference semantics
/// (pydantic `Literal` with default): the field may be absent, but when
/// present it must match — a mismatch rejects the component and thereby its
/// widget.

func validateTypeLiteral(
    _ container: KeyedDecodingContainer<TypeLiteralKey>,
    expected: String,
    codingPath: [CodingKey]
) throws {
    // pydantic Literal-with-default semantics: an ABSENT key applies the
    // default, but an explicitly supplied null (or wrong value) rejects.
    guard container.contains(.type) else { return }
    let found = try container.decode(String.self, forKey: .type) // throws on null
    if found != expected {
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: codingPath,
            debugDescription: "Expected type '\(expected)', found '\(found)'"
        ))
    }
}

public enum TypeLiteralKey: String, CodingKey {
    case type
}

// MARK: - Bistable buttons (ON_OFF / ON_OFF_DOUBLE)

public struct ButtonBistableComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let state: ValueRefDTO
    public let actions: [ActionRefDTO]
    public let onIndication: String
    public let offIndication: String

    enum CodingKeys: String, CodingKey {
        case label, rowId, unit, state, actions, onIndication, offIndication
    }

    public init(from decoder: Decoder) throws {
        try validateTypeLiteral(
            decoder.container(keyedBy: TypeLiteralKey.self),
            expected: "BUTTON_BISTABLE", codingPath: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rowId = try c.decode(Int.self, forKey: .rowId)
        unit = try c.decode(GrentonUnit.self, forKey: .unit)
        state = try c.decode(ValueRefDTO.self, forKey: .state)
        actions = try c.decode([ActionRefDTO].self, forKey: .actions)
        onIndication = try c.decode(String.self, forKey: .onIndication)
        offIndication = try c.decode(String.self, forKey: .offIndication)
    }
}

public struct ButtonBistableV2ComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let state: ValueRefDTO
    public let actions: [ActionRefDTO]
    public let onIndication: String
    public let offIndication: String

    enum CodingKeys: String, CodingKey {
        case label, rowId, unit, state, actions, onIndication, offIndication
    }

    public init(from decoder: Decoder) throws {
        try validateTypeLiteral(
            decoder.container(keyedBy: TypeLiteralKey.self),
            expected: "BUTTON_BISTABLE_V2", codingPath: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rowId = try c.decode(Int.self, forKey: .rowId)
        unit = try c.decode(GrentonUnit.self, forKey: .unit)
        state = try c.decode(ValueRefDTO.self, forKey: .state)
        actions = try c.decode([ActionRefDTO].self, forKey: .actions)
        onIndication = try c.decode(String.self, forKey: .onIndication)
        offIndication = try c.decode(String.self, forKey: .offIndication)
    }
}

// MARK: - Monostable button (SCENE)

public struct ButtonMonostableComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let actions: [ActionRefDTO]

    enum CodingKeys: String, CodingKey { case label, rowId, unit, actions }

    public init(from decoder: Decoder) throws {
        try validateTypeLiteral(
            decoder.container(keyedBy: TypeLiteralKey.self),
            expected: "BUTTON_MONOSTABLE", codingPath: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rowId = try c.decode(Int.self, forKey: .rowId)
        unit = try c.decode(GrentonUnit.self, forKey: .unit)
        actions = try c.decode([ActionRefDTO].self, forKey: .actions)
    }
}

// MARK: - Camera stream (CAMERA)

public struct CameraStreamComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let image: String
    /// The stream URL (e.g. RTSP) — despite the generic field name.
    public let value: String

    enum CodingKeys: String, CodingKey { case label, rowId, unit, image, value }

    public init(from decoder: Decoder) throws {
        try validateTypeLiteral(
            decoder.container(keyedBy: TypeLiteralKey.self),
            expected: "CAMERA_STREAM", codingPath: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rowId = try c.decode(Int.self, forKey: .rowId)
        unit = try c.decode(GrentonUnit.self, forKey: .unit)
        image = try c.decode(String.self, forKey: .image)
        value = try c.decode(String.self, forKey: .value)
    }
}

// MARK: - Legacy roller shutter (ROLLER_SHUTTER)

public struct RollerShutterComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let image: String
    public let state: ValueRefDTO
    public let indication: GrentonComponentIndication
    public let actions: [ActionRefDTO]

    enum CodingKeys: String, CodingKey {
        case label, rowId, unit, image, state, indication, actions
    }

    public init(from decoder: Decoder) throws {
        try validateTypeLiteral(
            decoder.container(keyedBy: TypeLiteralKey.self),
            expected: "BUTTON_BISTABLE", codingPath: decoder.codingPath)
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        rowId = try c.decode(Int.self, forKey: .rowId)
        unit = try c.decode(GrentonUnit.self, forKey: .unit)
        image = try c.decode(String.self, forKey: .image)
        state = try c.decode(ValueRefDTO.self, forKey: .state)
        indication = try c.decode(GrentonComponentIndication.self, forKey: .indication)
        actions = try c.decode([ActionRefDTO].self, forKey: .actions)
    }
}

// MARK: - LED components (discriminated union, spec §3.5)

public struct LedButtonComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let state: ValueRefDTO
    public let actions: [ActionRefDTO]
    public let image: String
    public let onIndication: String
    public let offIndication: String
}

public struct LedSliderComponentDTO: Decodable, Sendable {
    public let label: String
    public let rowId: Int
    public let unit: GrentonUnit
    public let state: ValueRefDTO
    public let actions: [ActionRefDTO]
    public let range: RangeDTO
}

public enum LedComponentDTO: Decodable, Sendable {
    case button(LedButtonComponentDTO)
    case hue(LedSliderComponentDTO)
    case saturation(LedSliderComponentDTO)
    case brightness(LedSliderComponentDTO)

    public init(from decoder: Decoder) throws {
        let type = try decoder.container(keyedBy: TypeLiteralKey.self)
            .decode(String.self, forKey: .type)
        switch type {
        case "BUTTON_BISTABLE": self = .button(try LedButtonComponentDTO(from: decoder))
        case "SLIDER_HUE": self = .hue(try LedSliderComponentDTO(from: decoder))
        case "SLIDER_SATURATION": self = .saturation(try LedSliderComponentDTO(from: decoder))
        case "SLIDER_BRIGHTNESS": self = .brightness(try LedSliderComponentDTO(from: decoder))
        default: throw GrentonModelError.unknownDiscriminator(type)
        }
    }
}

// MARK: - Double-widget components (no rowId)

public struct ValueDoubleComponentDTO: Decodable, Sendable {
    public let label: String
    public let icon: String
    public let unit: GrentonUnit
    public let valueType: GrentonValueType
    public let precision: Int
    public let object: ValueObjectDTO
}

public struct ContactSensorDoubleComponentDTO: Decodable, Sendable {
    public let label: String
    public let icon: String
    public let onIndication: String
    public let offIndication: String
    public let reverseState: Bool
    public let object: ContactSensorObjectDTO
}
