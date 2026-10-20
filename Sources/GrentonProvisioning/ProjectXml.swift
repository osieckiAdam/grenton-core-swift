import Foundation

// The XML side of the project import (spec §4.5.1 pt 4, 6, 7): a document
// without a DTD, parsed into a flat arena of nodes in document order, with
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

    /// Parses `data`, rejecting a document with a `<!DOCTYPE>`, a syntax
    /// error, or two elements sharing an `id`.
    static func parse(_ data: Data) throws -> XmlDocument {
        guard !hasDoctype(data) else { throw ProvisioningError.invalidData("XML with a DOCTYPE") }
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

    // MARK: DOCTYPE

    /// Whether the prolog holds a document type declaration. The text is
    /// decoded the way an XML parser chooses its encoding — byte-order
    /// mark, the first bytes of the declaration, then its `encoding`
    /// attribute — so a UTF-16 document is read as such and not searched
    /// for ASCII bytes.
    static func hasDoctype(_ data: Data) -> Bool {
        guard let text = decodeForProlog(data) else { return false }   // undecodable: the parser reports it
        var rest = Substring(text)
        if rest.first == "\u{FEFF}" { rest = rest.dropFirst() }
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

    private static func decodeForProlog(_ data: Data) -> String? {
        let head = [UInt8](data.prefix(4))
        func decode(_ encoding: String.Encoding, dropping bom: Int = 0) -> String? {
            String(data: data.dropFirst(bom), encoding: encoding)
        }
        switch head {
        case let h where h.starts(with: [0xEF, 0xBB, 0xBF]): return decode(.utf8, dropping: 3)
        case let h where h.starts(with: [0xFF, 0xFE, 0x00, 0x00]): return decode(.utf32LittleEndian, dropping: 4)
        case let h where h.starts(with: [0x00, 0x00, 0xFE, 0xFF]): return decode(.utf32BigEndian, dropping: 4)
        case let h where h.starts(with: [0xFF, 0xFE]): return decode(.utf16LittleEndian, dropping: 2)
        case let h where h.starts(with: [0xFE, 0xFF]): return decode(.utf16BigEndian, dropping: 2)
        case let h where h.starts(with: [0x3C, 0x00, 0x3F, 0x00]): return decode(.utf16LittleEndian)
        case let h where h.starts(with: [0x00, 0x3C, 0x00, 0x3F]): return decode(.utf16BigEndian)
        case let h where h.starts(with: [0x3C, 0x00, 0x00, 0x00]): return decode(.utf32LittleEndian)
        case let h where h.starts(with: [0x00, 0x00, 0x00, 0x3C]): return decode(.utf32BigEndian)
        default: break
        }
        // An ASCII-compatible document: honour `encoding="…"` of the declaration.
        if let declaration = String(data: data.prefix(256), encoding: .isoLatin1),
           declaration.hasPrefix("<?xml"),
           let end = declaration.range(of: "?>"),
           let match = declaration[..<end.lowerBound].range(of: #"encoding\s*=\s*["']([^"']+)["']"#, options: .regularExpression) {
            let name = declaration[match].split(separator: "=")[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(name as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let encoding = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
                return decode(encoding)
            }
        }
        return decode(.utf8)
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
    }
}
