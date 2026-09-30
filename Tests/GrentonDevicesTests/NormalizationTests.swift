import Testing
import GrentonModel
@testable import GrentonDevices

@Suite struct NormalizationTests {

    /// Golden table generated with CPython: `str(round(v, p))` — the
    /// reference-compatible action-value format (spec §10 pt 3).
    @Test(arguments: [
        (50.0, 0, "50.0"),
        (5.0, 0, "5.0"),
        (0.5, 0, "0.0"),      // banker's rounding
        (1.5, 0, "2.0"),
        (2.5, 0, "2.0"),
        (20.456, 1, "20.5"),
        (20.44, 1, "20.4"),
        (21.5, 1, "21.5"),
        (0.125, 2, "0.12"),   // exact binary half → even
        (0.135, 2, "0.14"),   // stored as 0.13500000000000001 → up
        (76.5, 2, "76.5"),
        (359.999, 2, "360.0"),
        (100.0, 2, "100.0"),
        (16.05, 1, "16.1"),   // decimal rounding of the true binary value
        (-3.567, 2, "-3.57"),
        (0.0, 0, "0.0"),
        (99.994999, 2, "99.99"),
    ])
    func referenceCompatibleFormatMatchesPython(value: Double, precision: Int, expected: String) {
        #expect(formatDeviceNumber(value, precision: precision) == expected)
    }

    @Test func plainFormatDropsIntegerDecimal() {
        #expect(formatDeviceNumber(50.0, precision: 0, format: .plain) == "50")
        #expect(formatDeviceNumber(20.456, precision: 1, format: .plain) == "20.5")
    }

    @Test func negativePrecisionRoundsToTens() {
        // Python: round(25.0, -1) == 20.0 (half-even), round(35.0, -1) == 40.0.
        #expect(formatDeviceNumber(25.0, precision: -1) == "20.0")
        #expect(formatDeviceNumber(35.0, precision: -1) == "40.0")
        #expect(formatDeviceNumber(1234.0, precision: -2) == "1200.0")
    }

    @Test func mapRangeAndClamp() {
        #expect(mapRange(from: (0, 255), to: (0, 1), value: 127.5) == 0.5)
        #expect(mapRange(from: (0, 0), to: (5, 10), value: 42) == 5)   // degenerate → target min
        #expect(clamp(1.5, to: 0...1) == 1)
        #expect(clamp(-0.5, to: 0...1) == 0)
    }

    @Test func onOffCoercion() {
        #expect(boolFromOnOff(.string("ON")) == true)
        #expect(boolFromOnOff(.bool(true)) == true)
        #expect(boolFromOnOff(.string("OFF")) == false)
        #expect(boolFromOnOff(.string("on")) == false)  // exact match, like the reference
        #expect(boolFromOnOff(.int(1)) == true)     // relays report 0/1; Python 1 == True
        #expect(boolFromOnOff(.double(1.0)) == true)
        #expect(boolFromOnOff(.int(0)) == false)
        #expect(boolFromOnOff(.int(2)) == false)
        #expect(boolFromOnOff(.string("1")) == false)
        #expect(boolFromOnOff(.null) == nil)
        #expect(boolFromOnOff(nil) == nil)
    }

    @Test func truthiness() {
        #expect(truthy(.int(0)) == false)
        #expect(truthy(.int(2)) == true)
        #expect(truthy(.double(0)) == false)
        #expect(truthy(.string("")) == false)
        #expect(truthy(.string("x")) == true)
        #expect(truthy(.bool(false)) == false)
        #expect(truthy(.null) == nil)
        #expect(truthy(nil) == nil)
    }
}
