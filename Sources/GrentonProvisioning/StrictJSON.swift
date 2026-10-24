import Foundation

// A JSON document as the project import reads and writes it (spec §4.5.1
// pt 5): parsed strictly, members kept in document order, and serialized
// back to bytes for `MobileInterfaceDTO.decode`. Foundation's
// JSONSerialization is too lenient for the import (it accepts duplicate
// keys and lets huge numbers through), hence this small parser.
enum JSONValue: Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([(String, JSONValue)])

    subscript(key: String) -> JSONValue? {
        guard case .object(let members) = self else { return nil }
        return members.first { $0.0 == key }?.1
    }

    var members: [(String, JSONValue)]? {
        if case .object(let members) = self { return members }
        return nil
    }

    var isObject: Bool { members != nil }

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// A field counts as present when the member exists, even as `null`.
    func has(_ key: String) -> Bool { self[key] != nil }

    /// A required field (spec §4.5.6): present and not `null`.
    func required(_ key: String) -> JSONValue? {
        guard let value = self[key] else { return nil }
        if case .null = value { return nil }
        return value
    }

    // MARK: Serialization

    func serialized() -> Data {
        var out = ""
        write(into: &out)
        return Data(out.utf8)
    }

    private func write(into out: inout String) {
        switch self {
        case .null: out += "null"
        case .bool(let b): out += b ? "true" : "false"
        case .int(let i): out += String(i)
        case .double(let d): out += String(d)   // finite by construction; shortest round-trip form
        case .string(let s): Self.writeString(s, into: &out)
        case .array(let items):
            out += "["
            for (n, item) in items.enumerated() {
                if n > 0 { out += "," }
                item.write(into: &out)
            }
            out += "]"
        case .object(let members):
            out += "{"
            for (n, (key, value)) in members.enumerated() {
                if n > 0 { out += "," }
                Self.writeString(key, into: &out)
                out += ":"
                value.write(into: &out)
            }
            out += "}"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            case ..<" ": out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        out += "\""
    }
}

/// Strict JSON (RFC 8259) parser: rejects invalid UTF-8, non-JSON
/// constants, duplicate object keys, integers outside Int64, numbers that
/// are not finite as doubles, and unreasonable nesting.
struct StrictJSONParser {
    /// Deep enough for any interface or project node (they nest about ten
    /// levels) and shallow enough that the recursive descent cannot
    /// overflow a secondary thread's 512 KB stack in a debug build, which
    /// 512 levels did.
    static let maxDepth = 64

    private let bytes: [UInt8]
    private var index = 0
    private var depth = 0

    static func parse(_ data: Data) throws -> JSONValue {
        guard let text = String(data: data, encoding: .utf8) else {
            throw ProvisioningError.invalidData("JSON is not valid UTF-8")
        }
        var parser = StrictJSONParser(bytes: Array(text.utf8))
        parser.skipWhitespace()
        let value = try parser.parseValue()
        parser.skipWhitespace()
        guard parser.index == parser.bytes.count else { throw Self.invalid("trailing characters") }
        return value
    }

    private init(bytes: [UInt8]) { self.bytes = bytes }

    private static func invalid(_ reason: String) -> ProvisioningError {
        .invalidData("JSON: \(reason)")
    }

    private var current: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while let c = current, c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D { index += 1 }
    }

    private mutating func expect(_ literal: String) throws {
        let expected = Array(literal.utf8)
        guard bytes.count - index >= expected.count,
              Array(bytes[index..<index + expected.count]) == expected else {
            throw Self.invalid("unexpected token")
        }
        index += expected.count
    }

    private mutating func parseValue() throws -> JSONValue {
        guard let c = current else { throw Self.invalid("unexpected end") }
        switch c {
        case UInt8(ascii: "{"): return try parseObject()
        case UInt8(ascii: "["): return try parseArray()
        case UInt8(ascii: "\""): return .string(try parseString())
        case UInt8(ascii: "t"): try expect("true"); return .bool(true)
        case UInt8(ascii: "f"): try expect("false"); return .bool(false)
        case UInt8(ascii: "n"): try expect("null"); return .null
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return try parseNumber()
        default: throw Self.invalid("unexpected character")
        }
    }

    private mutating func enter() throws {
        depth += 1
        guard depth <= Self.maxDepth else { throw Self.invalid("nesting too deep") }
    }

    private mutating func parseObject() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var members: [(String, JSONValue)] = []
        var seen: Set<String> = []
        skipWhitespace()
        if current == UInt8(ascii: "}") { index += 1; return .object(members) }
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else { throw Self.invalid("expected a key") }
            let key = try parseString()
            guard seen.insert(key).inserted else { throw Self.invalid("duplicate key \(key)") }
            skipWhitespace()
            guard current == UInt8(ascii: ":") else { throw Self.invalid("expected ':'") }
            index += 1
            skipWhitespace()
            members.append((key, try parseValue()))
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "}"): index += 1; return .object(members)
            default: throw Self.invalid("expected ',' or '}'")
            }
        }
    }

    private mutating func parseArray() throws -> JSONValue {
        try enter()
        defer { depth -= 1 }
        index += 1
        var items: [JSONValue] = []
        skipWhitespace()
        if current == UInt8(ascii: "]") { index += 1; return .array(items) }
        while true {
            skipWhitespace()
            items.append(try parseValue())
            skipWhitespace()
            switch current {
            case UInt8(ascii: ","): index += 1
            case UInt8(ascii: "]"): index += 1; return .array(items)
            default: throw Self.invalid("expected ',' or ']'")
            }
        }
    }

    private mutating func parseNumber() throws -> JSONValue {
        let start = index
        var isInteger = true
        if current == UInt8(ascii: "-") { index += 1 }
        guard let first = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(first) else {
            throw Self.invalid("bad number")
        }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let c = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { index += 1 }
        }
        if current == UInt8(ascii: ".") {
            isInteger = false
            index += 1
            try digits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            isInteger = false
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") { index += 1 }
            try digits()
        }
        let text = String(decoding: bytes[start..<index], as: UTF8.self)
        if isInteger {
            guard let value = Int64(text) else { throw Self.invalid("integer out of range") }
            return .int(value)
        }
        guard let value = Double(text), value.isFinite else { throw Self.invalid("number is not finite") }
        return .double(value)
    }

    private mutating func digits() throws {
        var count = 0
        while let c = current, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(c) { index += 1; count += 1 }
        guard count > 0 else { throw Self.invalid("bad number") }
    }

    private mutating func parseString() throws -> String {
        index += 1   // opening quote
        var scalars = String.UnicodeScalarView()
        var pendingHighSurrogate: UInt32?
        func flushSurrogate() throws {
            guard pendingHighSurrogate == nil else { throw Self.invalid("lone surrogate") }
        }
        while true {
            guard let c = current else { throw Self.invalid("unterminated string") }
            if c == UInt8(ascii: "\"") {
                try flushSurrogate()
                index += 1
                return String(scalars)
            }
            if c == UInt8(ascii: "\\") {
                index += 1
                guard let e = current else { throw Self.invalid("unterminated escape") }
                index += 1
                switch e {
                case UInt8(ascii: "\""): try flushSurrogate(); scalars.append("\"")
                case UInt8(ascii: "\\"): try flushSurrogate(); scalars.append("\\")
                case UInt8(ascii: "/"): try flushSurrogate(); scalars.append("/")
                case UInt8(ascii: "b"): try flushSurrogate(); scalars.append("\u{08}")
                case UInt8(ascii: "f"): try flushSurrogate(); scalars.append("\u{0C}")
                case UInt8(ascii: "n"): try flushSurrogate(); scalars.append("\n")
                case UInt8(ascii: "r"): try flushSurrogate(); scalars.append("\r")
                case UInt8(ascii: "t"): try flushSurrogate(); scalars.append("\t")
                case UInt8(ascii: "u"):
                    guard bytes.count - index >= 4,
                          let unit = UInt32(String(decoding: bytes[index..<index + 4], as: UTF8.self), radix: 16)
                    else { throw Self.invalid("bad \\u escape") }
                    index += 4
                    if let high = pendingHighSurrogate {
                        guard (0xDC00...0xDFFF).contains(unit) else { throw Self.invalid("lone surrogate") }
                        let combined = 0x10000 + ((high - 0xD800) << 10) + (unit - 0xDC00)
                        guard let scalar = Unicode.Scalar(combined) else { throw Self.invalid("bad surrogate pair") }
                        scalars.append(scalar)
                        pendingHighSurrogate = nil
                    } else if (0xD800...0xDBFF).contains(unit) {
                        pendingHighSurrogate = unit
                    } else if let scalar = Unicode.Scalar(unit) {
                        scalars.append(scalar)
                    } else {
                        throw Self.invalid("lone surrogate")
                    }
                default: throw Self.invalid("bad escape")
                }
                continue
            }
            try flushSurrogate()
            guard c >= 0x20 else { throw Self.invalid("control character in string") }
            // Copy one UTF-8 scalar (the input is validated UTF-8).
            let length = c < 0x80 ? 1 : c < 0xE0 ? 2 : c < 0xF0 ? 3 : 4
            let scalarBytes = bytes[index..<min(index + length, bytes.count)]
            index += length
            scalars.append(contentsOf: String(decoding: scalarBytes, as: UTF8.self).unicodeScalars)
        }
    }
}
