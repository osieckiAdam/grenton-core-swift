// Leaf DTOs of the mobile-interface JSON (spec §3.4). Field names match the
// JSON 1:1 — no key-decoding strategy is applied anywhere in the model.

public struct EncryptionDTO: Decodable, Hashable, Sendable {
    /// Base64-encoded AES key (16/24/32 bytes after decoding).
    public let key: String
    /// Base64-encoded static IV (16 bytes after decoding).
    public let iv: String
}

/// One CLU controller of the installation, as the interface lists it.
public struct CluDTO: Decodable, Hashable, Sendable {
    /// The CLU's object name, such as `CLU220000001`; it keys sessions and states.
    public let id: String
    /// The serial number in decimal, as Object Manager writes it.
    public let serialNumber: String
    /// The name given in Object Manager.
    public let name: String
    /// The IPv4 address the CLU listens on.
    public let ip: String
    /// Kept as `Int` to mirror the schema (spec §3.4) — the 1...65535 range
    /// is validated at the UDP endpoint boundary, not in the Model.
    public let port: Int
    public let connectionType: GrentonCluConnectionType
}

public struct PushNotificationDTO: Decodable, Hashable, Sendable {
    public let cluId: Int
    public let objectId: String
    public let objectType: String
}

public struct RangeDTO: Decodable, Hashable, Sendable {
    public let min: Int
    public let max: Int
}

/// Value reference (spec §3.2). `objectName` is present in the JSON for both
/// call types; it is only meaningful for `.attribute`.
public struct ValueRefDTO: Decodable, Hashable, Sendable {
    public let cluId: String
    public let objectName: String
    public let index: String
    public let callType: GrentonValueCallType
}

/// Action reference (spec §3.3). `index` is absent for SCRIPT and required
/// for every other call type — validated at decode time so an invalid action
/// rejects its whole widget (spec §3.6 strictness below widget level).
public struct ActionRefDTO: Decodable, Hashable, Sendable {
    public let event: GrentonActionEvent
    public let cluId: String
    public let objectName: String
    public let value: String
    public let callType: GrentonActionCallType
    public let index: String?

    enum CodingKeys: String, CodingKey {
        case event, cluId, objectName, value, callType, index
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        event = try c.decode(GrentonActionEvent.self, forKey: .event)
        cluId = try c.decode(String.self, forKey: .cluId)
        objectName = try c.decode(String.self, forKey: .objectName)
        value = try c.decode(String.self, forKey: .value)
        callType = try c.decode(GrentonActionCallType.self, forKey: .callType)
        index = try c.decodeIfPresent(String.self, forKey: .index)
        if callType != .script && index == nil {
            throw DecodingError.keyNotFound(
                CodingKeys.index,
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "'index' is required for callType \(callType.rawValue)"
                )
            )
        }
    }
}

// MARK: - Lossy-decoding helpers

struct AnyCodingKey: CodingKey {
    var stringValue: String
    var intValue: Int?
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = String(intValue)
    }
}

/// Decodes (and discards) any JSON value. Used to advance an unkeyed
/// container past an element that failed to decode (spec §3.6 tolerance) —
/// `UnkeyedDecodingContainer` does not move its index on a failed decode.
struct JSONSkip: Decodable {
    init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer() {
            if single.decodeNil() { return }
            if (try? single.decode(Bool.self)) != nil { return }
            if (try? single.decode(Double.self)) != nil { return }
            if (try? single.decode(String.self)) != nil { return }
        }
        if (try? decoder.container(keyedBy: AnyCodingKey.self)) != nil { return }
        if (try? decoder.unkeyedContainer()) != nil { return }
        throw DecodingError.dataCorrupted(DecodingError.Context(
            codingPath: decoder.codingPath,
            debugDescription: "Unskippable JSON value"
        ))
    }
}
