import Foundation
import GrentonModel
import ZIPFoundation

/// One mobile interface listed in a project file.
public struct ProjectInterface: Hashable, Sendable {
    /// The interface identifier, stable across saves of the project.
    public let id: String
    /// The name shown in Object Manager.
    public let name: String
}

// Import of the mobile interface from an Object Manager project file
// (spec §4.5): the second source of `MobileInterfaceDTO`, needing neither
// a PIN nor a running Object Manager. The archive, both XML documents and
// the interface list are validated here; `interface(id:)` converts one
// interface and reads the key and the CLUs it uses.
/// A Grenton Object Manager project file (`.omp`), read for its mobile interfaces.
///
/// A project holds every mobile interface designed for it, the CLUs and the encryption key. Importing one gives the same `MobileInterfaceDTO` as downloading it from Object Manager, without a PIN:
///
/// ```swift
/// let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: "house.omp")))
/// let interface = try project.interface()
/// ```
///
/// A project with several interfaces needs the id of the one to import; ``interfaces`` lists them. The file contains the CLU encryption key, so store it privately.
public struct ProjectFile: Sendable {
    /// The largest file, and the largest entry inside it, the import accepts.
    public static let maxBytes = 64 * 1024 * 1024
    /// The most entries an archive may have.
    public static let maxEntries = 10_000

    /// The mobile interfaces of the project, in archive order.
    public let interfaces: [ProjectInterface]

    private let properties: XmlDocument
    private let system: XmlDocument
    private let editors: [JSONValue]

    /// Reads and validates the project file.
    ///
    /// - Throws: ``ProvisioningError/invalidData(_:)`` when the file is not a project archive, an XML document is malformed, or an interface entry is not valid JSON.
    public init(data: Data) throws {
        let archive = try ProjectArchive(data: data)
        properties = try XmlDocument.parse(try archive.required("properties.xml"))
        system = try XmlDocument.parse(try archive.required("system.xml"))

        var editors: [JSONValue] = []
        var ids: Set<String> = []
        for name in archive.nodeEntries {
            let document = try StrictJSONParser.parse(try archive.required(name))
            guard document.isObject, document["pages"]?.arrayValue != nil else { continue }
            guard let id = document["id"]?.stringValue, document["label"]?.stringValue != nil else {
                throw ProvisioningError.invalidData("\(name): interface id or label is not a string")
            }
            guard ids.insert(id).inserted else {
                throw ProvisioningError.invalidData("two interfaces share the id \(id)")
            }
            editors.append(document)
        }
        self.editors = editors
        interfaces = editors.map { ProjectInterface(id: $0["id"]!.stringValue!, name: $0["label"]!.stringValue!) }
    }

    /// Imports one interface of the project.
    ///
    /// - Parameter id: The interface to import. Omit it when the project has exactly one.
    /// - Throws: ``ProvisioningError/interfaceNotFound`` when no interface has `id` (or the project has none), ``ProvisioningError/interfaceAmbiguous`` when `id` is omitted and the project has several, ``ProvisioningError/invalidData(_:)`` when the key, a CLU or a page is malformed.
    public func interface(id: String? = nil) throws -> MobileInterfaceDTO {
        let editor: JSONValue
        if let id {
            guard let found = editors.first(where: { $0["id"]?.stringValue == id }) else {
                throw ProvisioningError.interfaceNotFound
            }
            editor = found
        } else {
            switch editors.count {
            case 1: editor = editors[0]
            case 0: throw ProvisioningError.interfaceNotFound
            default: throw ProvisioningError.interfaceAmbiguous
            }
        }

        // The key (§4.5.3): the first keyBytes and ivBytes of properties.xml.
        guard let keyIndex = try properties.firstElement(named: "keyBytes"),
              let ivIndex = try properties.firstElement(named: "ivBytes"),
              let key = properties.trimmedText(properties[keyIndex]),
              let iv = properties.trimmedText(properties[ivIndex]) else {
            throw ProvisioningError.invalidData("properties.xml has no project key")
        }
        guard let icon = editor["icon"]?.stringValue, let theme = editor["theme"]?.stringValue else {
            throw ProvisioningError.invalidData("interface icon or theme is not a string")
        }

        let pages = try ProjectConversion.pages(editor["pages"]?.arrayValue ?? [])
        let blockCloud: Bool
        if case .bool(true)? = editor["blockCloud"] { blockCloud = true } else { blockCloud = false }
        let root = JSONValue.object([
            ("id", editor["id"]!), ("version", .int(0)), ("name", editor["label"]!),
            ("icon", .string(icon)), ("theme", .string(theme.uppercased())),
            ("encryption", .object([("key", .string(key)), ("iv", .string(iv))])),
            ("clus", .array(try ProjectConversion.clus(in: system, used: pages.usedCluIds, blockCloud: blockCloud))),
            ("pages", .array(pages.pages)),
            ("pushNotifications", .array(try ProjectConversion.pushNotifications(in: system))),
        ])
        do {
            return try MobileInterfaceDTO.decode(from: root.serialized())
        } catch {
            throw ProvisioningError.invalidData("imported interface does not decode: \(error)")
        }
    }
}

/// The archive side of spec §4.5.1: entries, limits and extraction.
private struct ProjectArchive {
    private let archive: Archive
    private let entries: [String: Entry]
    /// Every `nodes/{n}/data.json`, in archive order.
    let nodeEntries: [String]

    init(data: Data) throws {
        guard data.count <= ProjectFile.maxBytes else {
            throw ProvisioningError.invalidData("project file larger than \(ProjectFile.maxBytes) bytes")
        }
        do {
            archive = try Archive(data: data, accessMode: .read)
        } catch {
            throw ProvisioningError.invalidData("not a ZIP archive")
        }
        var entries: [String: Entry] = [:]
        var nodes: [String] = []
        var count = 0
        var usedBytes: UInt64 = 0
        for entry in archive {
            count += 1
            guard count <= ProjectFile.maxEntries else {
                throw ProvisioningError.invalidData("more than \(ProjectFile.maxEntries) entries")
            }
            guard entries.updateValue(entry, forKey: entry.path) == nil else {
                throw ProvisioningError.invalidData("duplicate entry \(entry.path)")
            }
            if entry.path == "properties.xml" || entry.path == "system.xml" || Self.isNode(entry.path) {
                guard entry.type == .file else { throw ProvisioningError.invalidData("\(entry.path) is not a file") }
                let size = UInt64(entry.uncompressedSize)
                guard size <= UInt64(ProjectFile.maxBytes) else {
                    throw ProvisioningError.invalidData("\(entry.path) larger than \(ProjectFile.maxBytes) bytes")
                }
                usedBytes += size
                guard usedBytes <= UInt64(ProjectFile.maxBytes) else {
                    throw ProvisioningError.invalidData("used entries exceed \(ProjectFile.maxBytes) bytes")
                }
                if Self.isNode(entry.path) { nodes.append(entry.path) }
            }
        }
        self.entries = entries
        nodeEntries = nodes
        for name in ["properties.xml", "system.xml"] where entries[name] == nil {
            throw ProvisioningError.invalidData("missing \(name)")
        }
    }

    /// `nodes/{n}/data.json` with a non-empty run of ASCII digits.
    private static func isNode(_ path: String) -> Bool {
        guard path.hasPrefix("nodes/"), path.hasSuffix("/data.json") else { return false }
        let digits = path.dropFirst("nodes/".count).dropLast("/data.json".count)
        return !digits.isEmpty && digits.utf8.allSatisfy { (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }
    }

    func required(_ name: String) throws -> Data {
        guard let entry = entries[name] else { throw ProvisioningError.invalidData("missing \(name)") }
        return try archive.extractBounded(entry, name: name, limit: ProjectFile.maxBytes)
    }
}
