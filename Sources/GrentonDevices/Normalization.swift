import Foundation
import GrentonModel

// Normalization primitives (spec §6.1–§6.2). ALL translation between raw
// CLU values and canonical state lives here — adapters never re-implement
// any of it.

// `mapRange((a,b) → (c,d), v)` — no clamping (spec: callers clamp inputs).
/// Maps a value from one range to another, without clamping.
public func mapRange(
    from source: (min: Double, max: Double),
    to target: (min: Double, max: Double),
    value: Double
) -> Double {
    let sourceSpan = source.max - source.min
    guard sourceSpan > 0 else { return target.min }
    let normalized = (value - source.min) / sourceSpan
    return target.min + normalized * (target.max - target.min)
}

/// Limits a value to a range.
public func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

// Switch-state coercion (spec §6.2): ON ⇔ string "ON", boolean true, or
// the number 1. The reference's `value == True` holds for 1 and 1.0 in
// Python, and relays report their state as 0/1.
/// Reads a switch state: on for the text `"ON"`, `true`, or the number 1; `nil` while unknown.
public func boolFromOnOff(_ value: GrentonValue?) -> Bool? {
    guard let value else { return nil }
    switch value {
    case .string(let s): return s == "ON"
    case .bool(let b): return b
    case .int(let i): return i == 1
    case .double(let d): return d == 1
    case .null: return nil
    }
}

// Python-style truthiness (spec §6.2) for binary sensors and LED power.
/// Reads a value as on or off the way sensors and LEDs report it: zero, empty text and `false` are off; `nil` while unknown.
public func truthy(_ value: GrentonValue?) -> Bool? {
    guard let value else { return nil }
    switch value {
    case .null: return nil
    case .bool(let b): return b
    case .int(let i): return i != 0
    case .double(let d): return d != 0
    case .string(let s): return !s.isEmpty
    }
}

/// The value as a number, if it is an integer or a decimal.
public func asDouble(_ value: GrentonValue?) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d
    default: return nil
    }
}

/// The value as an integer, if it is a number (decimals are truncated).
///
/// `nil` for a double outside the `Int` range or not finite: the wire can
/// carry such a number (an integer wider than 64 bits arrives as a double,
/// spec §3.1 pt 4), and it must not crash the app.
public func asInt(_ value: GrentonValue?) -> Int? {
    switch value {
    case .int(let i): return Int(i)
    case .double(let d): return d.isFinite ? Int(exactly: d.rounded(.towardZero)) : nil
    default: return nil
    }
}

/// How numbers are written into commands sent to a CLU.
public enum DeviceNumberFormat: Sendable {
    // Byte-for-byte the reference implementation: Python `str(round(v, p))`
    // (spec §10 pt 3).
    /// Always with a decimal point, such as `"50.0"`. The default; CLUs accept it.
    case referenceCompatible
    /// Whole numbers without a decimal point, such as `"50"`. Not confirmed to
    /// work with every CLU.
    case plain
}

// Renders an action value like the reference (`str(round(v, p))`).
//
// Python's `round` performs CORRECT decimal rounding of the binary value
// (`round(16.05, 1) == 16.1` because 16.05 is stored as 16.050000…07);
// naive multiply-round-divide gets these wrong. `%.pf` delegates to the
// C library's correctly-rounded conversion, then the shortest round-trip
// description mirrors Python's `str`.
/// Writes a number for a command, rounded to `precision` decimals.
///
/// The default format always keeps a decimal point, such as `"50.0"`, which every CLU accepts.
public func formatDeviceNumber(
    _ value: Double, precision: Int, format: DeviceNumberFormat = .referenceCompatible
) -> String {
    let rounded: Double
    if precision >= 0 {
        let fixed = String(format: "%.\(precision)f", value)
        rounded = Double(fixed) ?? value
    } else {
        // Python round(v, -n) rounds to tens/hundreds/… with the same
        // half-even semantics; scale, round at the units, scale back.
        let scale = pow(10, Double(-precision))
        let fixed = String(format: "%.0f", value / scale)
        rounded = (Double(fixed) ?? (value / scale)) * scale
    }
    switch format {
    case .referenceCompatible:
        return "\(rounded)"
    case .plain:
        if rounded == rounded.rounded(), abs(rounded) < 1e15 {
            return "\(Int64(rounded))"
        }
        return "\(rounded)"
    }
}
