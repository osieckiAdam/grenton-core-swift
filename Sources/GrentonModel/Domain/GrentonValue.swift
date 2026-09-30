/// Dynamically-typed value used across the Grenton system (spec §3.1).
public enum GrentonValue: Hashable, Sendable {
    case string(String)
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case null
}

extension GrentonValue {
    /// Casts a wire string from a `clientReport` payload into a typed value.
    ///
    /// Order of attempts is significant (spec §3.1): trim + strip quotes,
    /// then nil → bool → Int64 (strict decimal grammar; overflow retries as
    /// double) → finite double (dot or exponent required) → string.
    public init(wireString raw: String) {
        var s = Substring(raw.trimmingCharacters(in: .whitespacesAndNewlines))
        // Reference behaviour (Python str.strip('"')): drop ALL leading/trailing quotes.
        while s.first == "\"" { s = s.dropFirst() }
        while s.last == "\"" { s = s.dropLast() }
        let text = String(s)

        switch text.lowercased() {
        case "nil": self = .null; return
        case "true": self = .bool(true); return
        case "false": self = .bool(false); return
        default: break
        }

        if Self.isIntegerLiteral(s) {
            if let i = Int64(text) {
                self = .int(i)
            } else if let d = Double(text), d.isFinite {
                // Integer too wide for Int64 (spec §3.1 pt 4).
                self = .double(d)
            } else {
                self = .string(text)
            }
            return
        }

        if Self.isDoubleLiteral(s), let d = Double(text), d.isFinite {
            self = .double(d)
            return
        }

        self = .string(text)
    }

    /// `^-?[0-9]+$` — ASCII digits only; no separators, no hex, no whitespace.
    static func isIntegerLiteral(_ s: Substring) -> Bool {
        var t = s
        if t.first == "-" { t = t.dropFirst() }
        guard !t.isEmpty else { return false }
        return t.unicodeScalars.allSatisfy { (48...57).contains($0.value) }
    }

    /// `^-?(d+.d*|.d+|d+)([eE][+-]?d+)?$` with a dot or exponent required
    /// (a bare integer form is handled by `isIntegerLiteral`). Excludes
    /// `inf`/`nan`/hex by construction.
    static func isDoubleLiteral(_ s: Substring) -> Bool {
        var t = s
        if t.first == "-" { t = t.dropFirst() }
        guard !t.isEmpty else { return false }

        func takeDigits(_ sub: inout Substring) -> Int {
            var count = 0
            while let f = sub.unicodeScalars.first, (48...57).contains(f.value) {
                sub = sub.dropFirst()
                count += 1
            }
            return count
        }

        let intDigits = takeDigits(&t)
        var hasDot = false
        if t.first == "." {
            hasDot = true
            t = t.dropFirst()
            let fracDigits = takeDigits(&t)
            guard intDigits > 0 || fracDigits > 0 else { return false }
        } else {
            guard intDigits > 0 else { return false }
        }

        var hasExponent = false
        if t.first == "e" || t.first == "E" {
            hasExponent = true
            t = t.dropFirst()
            if t.first == "+" || t.first == "-" { t = t.dropFirst() }
            guard takeDigits(&t) > 0 else { return false }
        }

        return t.isEmpty && (hasDot || hasExponent)
    }
}
