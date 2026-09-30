import Testing
@testable import GrentonModel

/// Wire-string casting conformance table (spec §9.2) plus the strict-grammar
/// edges the spec adds over the Python reference (spec §3.1).
@Suite struct GrentonValueTests {

    @Test(arguments: [
        ("nil", GrentonValue.null),
        ("NIL", .null),
        ("true", .bool(true)),
        ("True", .bool(true)),
        ("false", .bool(false)),
        ("FALSE", .bool(false)),
        ("ON", .string("ON")),
        ("42", .int(42)),
        ("-7", .int(-7)),
        ("21.5", .double(21.5)),
        ("-3e2", .double(-300)),
        ("\"21.5\"", .double(21.5)),
        ("  tekst  ", .string("tekst")),
        ("\"ON\"", .string("ON")),
        ("", .string("")),
        ("0", .int(0)),
        ("1.0E-3", .double(0.001)),
        (".5", .double(0.5)),
        ("-.5", .double(-0.5)),
        ("1.", .double(1.0)),
        ("1e0", .double(1.0)),
        ("01", .int(1)),
        ("9223372036854775807", .int(.max)),
        ("-9223372036854775808", .int(.min)),
    ])
    func castsWireStrings(input: String, expected: GrentonValue) {
        #expect(GrentonValue(wireString: input) == expected)
    }

    @Test func integerOverflowFallsBackToDouble() {
        // One above Int64.max / below Int64.min — spec §3.1 pt 4.
        #expect(GrentonValue(wireString: "9223372036854775808")
            == .double(9.223372036854776e18))
        #expect(GrentonValue(wireString: "-9223372036854775809")
            == .double(-9.223372036854776e18))
    }

    @Test func nonFiniteFallbacksStayStrings() {
        // Overflow paths that produce a non-finite double must yield string.
        #expect(GrentonValue(wireString: "1e309") == .string("1e309"))
        let hugeInteger = "1" + String(repeating: "0", count: 400)
        #expect(GrentonValue(wireString: hugeInteger) == .string(hugeInteger))
    }

    @Test(arguments: [
        "1_0",        // Python liberalism must not leak in (spec §3.1 Δ)
        "inf",
        "-inf",
        "nan",
        "0x10",
        "1e",         // exponent without digits
        "-",
        ".",
        "1.2.3",
        "+1",         // leading plus is not in the grammar
    ])
    func strictGrammarRejectsAsString(input: String) {
        #expect(GrentonValue(wireString: input) == .string(input))
    }

    @Test func stripsAllSurroundingQuotes() {
        // Reference behaviour is Python str.strip('"') — every leading and
        // trailing quote goes, not just one pair.
        #expect(GrentonValue(wireString: "\"\"abc\"\"") == .string("abc"))
    }
}
