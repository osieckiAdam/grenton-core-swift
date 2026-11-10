import Foundation

// The XML side of the project import (spec §4.5.1 pt 4, 6, 7): a UTF-8
// document without a DTD, parsed into a flat arena of nodes in document order, with
// Object Manager's `reference="…"` → `id="…"` links resolved on demand.
struct XmlNode: Sendable {
    let name: String
    let attributes: [String: String]
    /// Character data before the first child element, or nil when there
    /// is none (mixed content never occurs in these files).
    var text: String?
    var children: [Int] = []
}

struct XmlDocument: Sendable {
    let nodes: [XmlNode]
    let root: Int
    private let byId: [String: Int]

    /// Parses `data`, rejecting a document that is not UTF-8, one with a
    /// `<!DOCTYPE>`, a syntax error, or two elements sharing an `id`.
    static func parse(_ data: Data) throws -> XmlDocument {
        guard let text = utf8Text(data) else { throw ProvisioningError.invalidData("XML that is not UTF-8") }
        guard !hasDoctype(text) else { throw ProvisioningError.invalidData("XML with a DOCTYPE") }
        let builder = ArenaBuilder()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.shouldResolveExternalEntities = false
        parser.delegate = builder
        guard parser.parse(), builder.failed == false, let root = builder.rootIndex else {
            throw ProvisioningError.invalidData("XML does not parse")
        }
        var byId: [String: Int] = [:]
        for (index, node) in builder.nodes.enumerated() {
            guard let id = node.attributes["id"] else { continue }
            guard byId.updateValue(index, forKey: id) == nil else {
                throw ProvisioningError.invalidData("XML: duplicate id \(id)")
            }
        }
        return XmlDocument(nodes: builder.nodes, root: root, byId: byId)
    }

    subscript(index: Int) -> XmlNode { nodes[index] }

    /// Follows `reference` links (spec §4.5.1 pt 6); a missing target or a
    /// cycle is invalid data.
    func resolve(_ index: Int) throws -> Int {
        var current = index
        var seen: Set<String> = []
        while let target = nodes[current].attributes["reference"] {
            guard seen.insert(target).inserted, let resolved = byId[target] else {
                throw ProvisioningError.invalidData("XML: unresolved or cyclic reference \(target)")
            }
            current = resolved
        }
        return current
    }

    /// Direct children of `index` with `name`, unresolved.
    func children(of index: Int, named name: String) -> [Int] {
        nodes[index].children.filter { nodes[$0].name == name }
    }

    /// The first direct child named `name`, resolved; nil when there is none.
    func child(of index: Int, named name: String) throws -> Int? {
        guard let found = children(of: index, named: name).first else { return nil }
        return try resolve(found)
    }

    /// Spec §4.5.1 pt 7: trimmed text of the first child `name`; empty means absent.
    func text(of index: Int, child name: String) throws -> String? {
        guard let found = try child(of: index, named: name) else { return nil }
        return trimmedText(nodes[found])
    }

    func trimmedText(_ node: XmlNode) -> String? {
        guard let raw = node.text else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// The first element anywhere (document order) named `name`, resolved.
    func firstElement(named name: String) throws -> Int? {
        guard let found = nodes.firstIndex(where: { $0.name == name }) else { return nil }
        return try resolve(found)
    }

    /// A hexadecimal number of spec §4.5.1 pt 7: 1–8 hex digits, nothing else.
    static func hexNumber(_ text: String?) -> UInt64? {
        guard let text, (1...8).contains(text.utf8.count), text.utf8.allSatisfy(isHexDigit) else { return nil }
        return UInt64(text, radix: 16)
    }

    private static func isHexDigit(_ byte: UInt8) -> Bool {
        (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
            || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
    }

    // MARK: Encoding and DOCTYPE

    /// The document as UTF-8 text without its byte-order mark, or nil when
    /// it is not a UTF-8 document (spec §4.5.1 pt 4): a UTF-16 or UTF-32
    /// signature, invalid UTF-8, or an `encoding` declaration naming
    /// anything but UTF-8 (in any letter case). Object Manager writes UTF-8,
    /// so a document the parser could read in another encoding is still
    /// rejected.
    static func utf8Text(_ data: Data) -> String? {
        let body = data.starts(with: [0xEF, 0xBB, 0xBF]) ? data.dropFirst(3) : data[...]
        // A UTF-16/32 byte-order mark is invalid UTF-8; without one, such a
        // document has a NUL among its first two bytes, which XML forbids.
        guard !body.prefix(2).contains(0) else { return nil }
        guard let text = String(data: Data(body), encoding: .utf8) else { return nil }
        if text.hasPrefix("<?xml"), let end = text.range(of: "?>"),
           let match = text[..<end.lowerBound].range(
               of: #"encoding\s*=\s*["'][^"']*["']"#, options: .regularExpression) {
            let name = text[match].split(separator: "=", maxSplits: 1)[1]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"' \t\r\n"))
            guard name.lowercased() == "utf-8" else { return nil }
        }
        return text
    }

    /// Whether the prolog of the UTF-8 `text` holds a document type
    /// declaration. The parser's DTD callbacks back this up.
    static func hasDoctype(_ text: String) -> Bool {
        var rest = Substring(text)
        while true {
            rest = rest.drop(while: \.isWhitespace)
            if rest.hasPrefix("<?") {
                guard let end = rest.range(of: "?>") else { return false }
                rest = rest[end.upperBound...]
            } else if rest.hasPrefix("<!--") {
                guard let end = rest.range(of: "-->") else { return false }
                rest = rest[end.upperBound...]
            } else {
                return rest.hasPrefix("<!DOCTYPE")
            }
        }
    }

    // MARK: Arena builder

    private final class ArenaBuilder: NSObject, XMLParserDelegate {
        var nodes: [XmlNode] = []
        var rootIndex: Int?
        var failed = false
        private var stack: [Int] = []

        func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?, attributes attributeDict: [String: String]) {
            let index = nodes.count
            nodes.append(XmlNode(name: elementName, attributes: attributeDict))
            if let parent = stack.last {
                nodes[parent].children.append(index)
            } else if rootIndex == nil {
                rootIndex = index
            } else {
                failed = true   // two roots
            }
            stack.append(index)
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            guard let current = stack.last, nodes[current].children.isEmpty else { return }
            nodes[current].text = (nodes[current].text ?? "") + string
        }

        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
            guard let current = stack.last, nodes[current].children.isEmpty,
                  let string = String(data: CDATABlock, encoding: .utf8) else { return }
            nodes[current].text = (nodes[current].text ?? "") + string
        }

        func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                    qualifiedName qName: String?) {
            stack.removeLast()
        }

        func parser(_ parser: XMLParser, parseErrorOccurred parseError: any Error) {
            failed = true
        }

        // Defence in depth behind the prolog check: a DTD the parser still
        // reports (an entity, element, attribute or notation declaration)
        // rejects the document too, whatever encoding it came in.
        func parser(_ parser: XMLParser, foundInternalEntityDeclarationWithName name: String, value: String?) {
            failed = true; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundExternalEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            failed = true; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundUnparsedEntityDeclarationWithName name: String,
                    publicID: String?, systemID: String?, notationName: String?) {
            failed = true; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundElementDeclarationWithName elementName: String, model: String) {
            failed = true; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundAttributeDeclarationWithName attributeName: String,
                    forElement elementName: String, type: String?, defaultValue: String?) {
            failed = true; parser.abortParsing()
        }
        func parser(_ parser: XMLParser, foundNotationDeclarationWithName name: String,
                    publicID: String?, systemID: String?) {
            failed = true; parser.abortParsing()
        }
    }
}
