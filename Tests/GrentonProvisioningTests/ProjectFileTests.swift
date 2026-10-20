import Foundation
import Testing
@testable import GrentonProvisioning

/// The parsers behind the project import (spec §4.5.1). The import itself
/// is covered by the conformance suite's `project` profile.
@Suite struct StrictJSONTests {
    private func parse(_ text: String) throws -> JSONValue {
        try StrictJSONParser.parse(Data(text.utf8))
    }

    @Test func keepsMemberOrderAndIntegerness() throws {
        let value = try parse(#"{"b": 1, "a": 2.0, "s": "xé\n", "n": null, "l": [true, -0]}"#)
        #expect(value.members?.map(\.0) == ["b", "a", "s", "n", "l"])
        guard case .int(1)? = value["b"], case .double(2.0)? = value["a"] else { Issue.record("numbers"); return }
        #expect(value["s"]?.stringValue == "xé\n")
        #expect(String(data: value.serialized(), encoding: .utf8) == #"{"b":1,"a":2.0,"s":"xé\n","n":null,"l":[true,0]}"#)
    }

    @Test(arguments: [
        #"{"a": 1, "a": 2}"#, "NaN", "[Infinity]", "[1e400]", "[9223372036854775808]",
        "[1,]", #"{"a" 1}"#, #"["\ud800"]"#, "[01]", "", "[1] x",
    ])
    func rejects(_ text: String) {
        #expect(throws: ProvisioningError.self) { try parse(text) }
    }

    @Test func rejectsInvalidUTF8() {
        #expect(throws: ProvisioningError.self) { try StrictJSONParser.parse(Data([0x22, 0xFF, 0x22])) }
    }

    @Test func rejectsDeepNesting() {
        let deep = String(repeating: "[", count: 600) + String(repeating: "]", count: 600)
        #expect(throws: ProvisioningError.self) { try parse(deep) }
    }
}

@Suite struct ProjectXmlTests {
    @Test func doctypeIsFoundInEveryEncoding() {
        let doc = "<?xml version=\"1.0\"?>\n<!-- c --> <!DOCTYPE x [<!ENTITY e \"1\">]><x/>"
        #expect(XmlDocument.hasDoctype(Data(doc.utf8)) == true)
        #expect(XmlDocument.hasDoctype(Data([0xFF, 0xFE]) + doc.data(using: .utf16LittleEndian)!) == true)
        #expect(XmlDocument.hasDoctype(doc.data(using: .utf16BigEndian)!) == true)
        #expect(XmlDocument.hasDoctype(Data("<?xml version=\"1.0\"?><x><!-- <!DOCTYPE --></x>".utf8)) == false)
        // An undecodable document is rejected, not passed on to the parser.
        #expect(XmlDocument.hasDoctype(Data([0x3C, 0x78, 0xFF, 0x3E])) == nil)
        #expect(throws: ProvisioningError.self) { try XmlDocument.parse(Data([0x3C, 0x78, 0xFF, 0x3E])) }
        #expect(throws: ProvisioningError.self) { try XmlDocument.parse(Data(doc.utf8)) }
    }

    @Test func resolvesReferencesAndTrimsText() throws {
        let doc = try XmlDocument.parse(Data("""
            <r><a id="1"> hi </a><b reference="1"/><c reference="2"/><d><e/></d><empty>  </empty></r>
            """.utf8))
        #expect(try doc.text(of: doc.root, child: "b") == "hi")
        #expect(try doc.text(of: doc.root, child: "empty") == nil)
        #expect(throws: ProvisioningError.self) { try doc.child(of: doc.root, named: "c") }
        #expect(throws: ProvisioningError.self) {
            try XmlDocument.parse(Data("<r><a id=\"1\"/><b id=\"1\"/></r>".utf8))
        }
        // A cycle is reported when the reference is followed, not at parse time.
        let cyclic = try XmlDocument.parse(Data("<r><a id=\"1\" reference=\"2\"/><b id=\"2\" reference=\"1\"/></r>".utf8))
        #expect(throws: ProvisioningError.self) { try cyclic.child(of: cyclic.root, named: "a") }
    }

    @Test func hexNumbers() {
        #expect(XmlDocument.hexNumber("0bebc201") == 200_000_001)
        #expect(XmlDocument.hexNumber("FF") == 255)
        #expect(XmlDocument.hexNumber("123456789") == nil)
        #expect(XmlDocument.hexNumber("-1") == nil)
        #expect(XmlDocument.hexNumber("") == nil)
        #expect(XmlDocument.hexNumber(nil) == nil)
    }
}
