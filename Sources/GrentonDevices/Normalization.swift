import Foundation
import GrentonModel

/// Normalization primitives (spec §6.1–§6.2). ALL translation between raw
/// CLU values and canonical state lives here — adapters never re-implement
/// any of it.

/// `mapRange((a,b) → (c,d), v)` — no clamping (spec: callers clamp inputs).
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

public func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
    min(max(value, range.lowerBound), range.upperBound)
}

/// Switch-state coercion (spec §6.2): ON ⇔ string "ON", boolean true, or
/// the number 1. The reference's `value == True` holds for 1 and 1.0 in
/// Python, and relays report their state as 0/1.
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

/// Python-style truthiness (spec §6.2) for binary sensors and LED power.
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

public func asDouble(_ value: GrentonValue?) -> Double? {
    switch value {
    case .int(let i): return Double(i)
    case .double(let d): return d
    default: return nil
    }
}

public func asInt(_ value: GrentonValue?) -> Int? {
    switch value {
    case .int(let i): return Int(i)
    case .double(let d): return Int(d)
    default: return nil
    }
}

public enum DeviceNumberFormat: Sendable {
    /// Byte-for-byte the reference implementation: Python `str(round(v, p))`
    /// — e.g. precision 0 renders `"50.0"`. The DEFAULT until a live CLU
    /// proves the plain format acceptable (spec §10 pt 3).
    case referenceCompatible
    /// `"50"` instead of `"50.0"` at integer values. Behind this flag only.
    case plain
}

/// Renders an action value like the reference (`str(round(v, p))`).
///
/// Python's `round` performs CORRECT decimal rounding of the binary value
/// (`round(16.05, 1) == 16.1` because 16.05 is stored as 16.050000…07);
/// naive multiply-round-divide gets these wrong. `%.pf` delegates to the
/// C library's correctly-rounded conversion, then the shortest round-trip
/// description mirrors Python's `str`.
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
