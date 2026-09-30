// Domain-level references built from validated DTOs (spec §3.2–§3.3).

public enum GrentonModelError: Error, Sendable, Equatable {
    case unknownDiscriminator(String)
    case missingIndex
}

/// Where to read a value on a CLU (spec §3.2). Used directly as a state-store
/// key and as a subscription key on the wire.
public enum ValueRef: Hashable, Sendable {
    case variable(cluId: String, name: String)
    case attribute(cluId: String, objectName: String, index: String)

    public init(dto: ValueRefDTO) {
        switch dto.callType {
        case .variable:
            self = .variable(cluId: dto.cluId, name: dto.index)
        case .attribute:
            self = .attribute(cluId: dto.cluId, objectName: dto.objectName, index: dto.index)
        }
    }

    public var cluId: String {
        switch self {
        case .variable(let cluId, _): return cluId
        case .attribute(let cluId, _, _): return cluId
        }
    }

    /// The key form used inside a `clientRegister` payload (spec §5.3.2):
    /// variables are double-quoted names, attributes are `{objectName,index}`.
    /// Centralized here so Runtime and tests share one rendering.
    public var wireSubscriptionKey: String {
        switch self {
        case .variable(_, let name):
            return "\"\(name)\""
        case .attribute(_, let objectName, let index):
            return "{\(objectName),\(index)}"
        }
    }
}

/// What to send to a CLU (spec §3.3). Immutable — overriding `value`
/// (slider set, scene parameter) produces a copy via `withValue(_:)`.
public struct ActionRef: Hashable, Sendable {
    public enum Call: Hashable, Sendable {
        case variable(index: String)
        case attribute(index: String)
        case method(index: String)
        case script
    }

    public let cluId: String
    public let objectName: String
    public let event: GrentonActionEvent
    public let call: Call
    public let value: String

    public init(cluId: String, objectName: String, event: GrentonActionEvent, call: Call, value: String) {
        self.cluId = cluId
        self.objectName = objectName
        self.event = event
        self.call = call
        self.value = value
    }

    public init(dto: ActionRefDTO) throws {
        let call: Call
        switch dto.callType {
        case .script:
            call = .script
        case .variable, .attribute, .method:
            guard let index = dto.index else { throw GrentonModelError.missingIndex }
            switch dto.callType {
            case .variable: call = .variable(index: index)
            case .attribute: call = .attribute(index: index)
            case .method: call = .method(index: index)
            case .script: fatalError("unreachable")
            }
        }
        self.init(cluId: dto.cluId, objectName: dto.objectName, event: dto.event, call: call, value: dto.value)
    }

    /// Copy with a different payload value; the template stays untouched.
    public func withValue(_ newValue: String) -> ActionRef {
        ActionRef(cluId: cluId, objectName: objectName, event: event, call: call, value: newValue)
    }
}

/// A CLU controller as described by the mobile interface (spec §3.4).
/// Carries the full schema, including `connectionType` — the Runtime only
/// connects locally, but diagnostics and future consumers keep the field.
public struct Clu: Hashable, Sendable {
    public let id: String
    public let serialNumber: String
    public let name: String
    public let ip: String
    /// Range 1...65535 is enforced at the UDP endpoint boundary (spec §3.4).
    public let port: Int
    public let connectionType: GrentonCluConnectionType

    public init(
        id: String,
        serialNumber: String,
        name: String,
        ip: String,
        port: Int,
        connectionType: GrentonCluConnectionType
    ) {
        self.id = id
        self.serialNumber = serialNumber
        self.name = name
        self.ip = ip
        self.port = port
        self.connectionType = connectionType
    }

    public init(dto: CluDTO) {
        self.init(
            id: dto.id,
            serialNumber: dto.serialNumber,
            name: dto.name,
            ip: dto.ip,
            port: dto.port,
            connectionType: dto.connectionType
        )
    }
}
