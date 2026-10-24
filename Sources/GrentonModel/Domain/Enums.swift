// Enumerations of the mobile-interface JSON (spec §3.4–§3.5).
//
// All decode strictly: an unknown raw value fails the decode of the element
// that carries it, which at widget level means the widget is skipped (spec §3.6).

@nonexhaustive

public enum GrentonUnit: String, Decodable, Hashable, Sendable {
    case unknown = "UNKNOWN"
    case percent = "PERCENT"
    case degree = "DEGREE"
}

@nonexhaustive

public enum GrentonValueType: String, Decodable, Hashable, Sendable {
    case string = "STRING"
    case float = "FLOAT"
    case integer = "INTEGER"
}

@nonexhaustive

public enum GrentonValueCallType: String, Decodable, Hashable, Sendable {
    case variable = "VARIABLE"
    case attribute = "ATTRIBUTE"
}

@nonexhaustive

public enum GrentonActionEvent: String, Decodable, Hashable, Sendable {
    case click = "CLICK"
    case on = "ON"
    case off = "OFF"
}

@nonexhaustive

public enum GrentonActionCallType: String, Decodable, Hashable, Sendable {
    case variable = "VARIABLE"
    case attribute = "ATTRIBUTE"
    case method = "METHOD"
    case script = "SCRIPT"
}

@nonexhaustive

public enum GrentonComponentIndication: String, Decodable, Hashable, Sendable {
    case onOff = "ON_OFF"
    case openClosed = "OPEN_CLOSED"
    case openLocked = "OPEN_LOCKED"
    case upDown = "UP_DOWN"
}

@nonexhaustive

public enum GrentonTheme: String, Decodable, Hashable, Sendable {
    case grenton = "GRENTON"
    case red = "RED"
    case orange = "ORANGE"
    case yellow = "YELLOW"
    case lime = "LIME"
    case green = "GREEN"
    case steel = "STEEL"
    case turquoise = "TURQUOISE"
    case blue = "BLUE"
    case indigo = "INDIGO"
    case violet = "VIOLET"
    case purple = "PURPLE"
    case pink = "PINK"
    case beige = "BEIGE"
    case brown = "BROWN"
}

@nonexhaustive

public enum GrentonCluConnectionType: String, Decodable, Hashable, Sendable {
    case localOnly = "LOCAL_ONLY"
    case cloudCapable = "CLOUD_CAPABLE"
    case cloud = "CLOUD"
}
