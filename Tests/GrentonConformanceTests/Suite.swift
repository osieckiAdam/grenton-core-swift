import Foundation
import CryptoKit

/// Loads the language-agnostic conformance suite (grenton-core-spec,
/// `spec/conformance.md`) from the `vendor/grenton-core-spec` submodule and
/// checks it fails closed: a missing checkout, a stale manifest, or a bad
/// port declaration is an error, never "0 tests ran".

struct SuiteError: Error, CustomStringConvertible, Sendable {
    let description: String
    init(_ description: String) { self.description = description }
}

struct ConformanceCase: Sendable {
    let id: String
    let operation: String
    let input: JSON
    let expect: JSON
}

struct PortDeclaration: Decodable, Sendable {
    struct Skip: Decodable, Sendable {
        let id: String
        let reason: String
        let issue: String?
    }
    let suiteVersion: String
    let profiles: [String]
    let skips: [Skip]
}

struct ConformanceSuite: Sendable {
    static let supportedSchemaVersion = 1

    let suiteVersion: String
    let cases: [String: ConformanceCase]
    let port: PortDeclaration

    var skippedIds: Set<String> { Set(port.skips.map(\.id)) }

    /// Repository root, from this file's location — independent of the
    /// process working directory `swift test` happens to use.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // GrentonConformanceTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()

    static let conformanceRoot = repositoryRoot
        .appendingPathComponent("vendor/grenton-core-spec/conformance")

    static let portDeclarationURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().appendingPathComponent("port.json")

    /// Loaded once per test process.
    static let shared: Result<ConformanceSuite, SuiteError> = Result { try load() }
        .mapError { $0 as? SuiteError ?? SuiteError(String(describing: $0)) }

    /// Case ids for the parameterized test; empty when the suite is broken
    /// (the integrity test then fails with the reason).
    static var caseIds: [String] {
        (try? shared.get()).map { $0.cases.keys.sorted() } ?? []
    }

    static func load() throws -> ConformanceSuite {
        let manifestURL = conformanceRoot.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw SuiteError("""
                conformance suite not found at \(conformanceRoot.path) — \
                run `git submodule update --init`
                """)
        }
        let manifest = try JSON.decode(Data(contentsOf: manifestURL))
        guard manifest["schemaVersion"]?.intValue == supportedSchemaVersion else {
            throw SuiteError("unsupported manifest schemaVersion \(manifest["schemaVersion"] ?? .null)")
        }
        guard let suiteVersion = manifest["suiteVersion"]?.stringValue,
              let entries = manifest["cases"]?.arrayValue else {
            throw SuiteError("manifest.json lacks suiteVersion or cases")
        }

        var cases: [String: ConformanceCase] = [:]
        var listedPaths: Set<String> = []
        for entry in entries {
            guard let id = entry["id"]?.stringValue,
                  let path = entry["path"]?.stringValue,
                  let hash = entry["sha256"]?.stringValue else {
                throw SuiteError("malformed manifest entry \(entry)")
            }
            let data = try Data(contentsOf: conformanceRoot.appendingPathComponent(path))
            guard sha256(data) == hash else { throw SuiteError("\(path): SHA-256 does not match the manifest") }

            let doc = try JSON.decode(data)
            guard doc["schemaVersion"]?.intValue == supportedSchemaVersion else {
                throw SuiteError("\(path): unsupported schemaVersion")
            }
            guard doc["id"]?.stringValue == id,
                  let operation = doc["operation"]?.stringValue,
                  let input = doc["input"], let expect = doc["expect"] else {
                throw SuiteError("\(path): malformed case")
            }
            guard cases[id] == nil else { throw SuiteError("duplicate case id \(id)") }
            cases[id] = ConformanceCase(id: id, operation: operation, input: input, expect: expect)
            listedPaths.insert(path)
        }

        // Fixtures are hashed too; every one on disk must be listed.
        var listedFixtures: Set<String> = []
        for entry in manifest["fixtures"]?.arrayValue ?? [] {
            guard let path = entry["path"]?.stringValue, let hash = entry["sha256"]?.stringValue else {
                throw SuiteError("malformed manifest fixture entry \(entry)")
            }
            let data = try Data(contentsOf: conformanceRoot.appendingPathComponent(path))
            guard sha256(data) == hash else { throw SuiteError("\(path): SHA-256 does not match the manifest") }
            listedFixtures.insert(path)
        }
        try requireListed(under: "fixtures", listed: listedFixtures)

        // Every case file on disk must be in the manifest.
        try requireListed(under: "cases", listed: listedPaths)

        let port = try JSONDecoder().decode(PortDeclaration.self, from: Data(contentsOf: portDeclarationURL))
        guard port.suiteVersion == suiteVersion else {
            throw SuiteError("port.json declares suite \(port.suiteVersion), vendored suite is \(suiteVersion)")
        }
        for skip in port.skips where cases[skip.id] == nil {
            throw SuiteError("port.json skips unknown case \(skip.id)")
        }
        return ConformanceSuite(suiteVersion: suiteVersion, cases: cases, port: port)
    }
}

extension ConformanceSuite {
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Fails when a JSON file under `conformance/<directory>` is missing
    /// from the manifest — an unlisted file would silently never run.
    static func requireListed(under directory: String, listed: Set<String>) throws {
        let root = conformanceRoot.appendingPathComponent(directory).resolvingSymlinksInPath()
        let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            let path = "\(directory)/" + url.resolvingSymlinksInPath().path.dropFirst(root.path.count + 1)
            guard listed.contains(path) else { throw SuiteError("\(path) is not listed in manifest.json") }
        }
    }
}

// MARK: - JSON

/// Minimal JSON tree: structural equality ignores object key order.
indirect enum JSON: Equatable, Decodable, CustomStringConvertible, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    static func decode(_ data: Data) throws -> JSON {
        try JSONDecoder().decode(JSON.self, from: data)
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSON].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSON].self)) }
    }

    subscript(key: String) -> JSON? {
        if case .object(let o) = self { return o[key] }
        return nil
    }

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var boolValue: Bool? { if case .bool(let b) = self { return b }; return nil }
    var arrayValue: [JSON]? { if case .array(let a) = self { return a }; return nil }
    var intValue: Int? {
        if case .number(let n) = self, n == n.rounded(), abs(n) < 1e15 { return Int(n) }
        return nil
    }

    func data() throws -> Data {
        try JSONSerialization.data(withJSONObject: foundationObject, options: [.fragmentsAllowed])
    }

    private var foundationObject: Any {
        switch self {
        case .null: return NSNull()
        case .bool(let b): return b
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? Int(n) as Any : n
        case .string(let s): return s
        case .array(let a): return a.map(\.foundationObject)
        case .object(let o): return o.mapValues(\.foundationObject)
        }
    }

    var description: String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: foundationObject, options: [.fragmentsAllowed, .sortedKeys, .withoutEscapingSlashes]),
              let text = String(data: data, encoding: .utf8) else { return "<unprintable>" }
        return text
    }

    /// Path of the first difference, or nil when equal.
    func firstDifference(from other: JSON, path: String = "$") -> String? {
        switch (self, other) {
        case (.object(let a), .object(let b)):
            for key in Set(a.keys).union(b.keys).sorted() {
                guard let x = a[key], let y = b[key] else { return "\(path).\(key)" }
                if let d = x.firstDifference(from: y, path: "\(path).\(key)") { return d }
            }
            return nil
        case (.array(let a), .array(let b)):
            guard a.count == b.count else { return "\(path) (length \(a.count) vs \(b.count))" }
            for (n, (x, y)) in zip(a, b).enumerated() {
                if let d = x.firstDifference(from: y, path: "\(path)[\(n)]") { return d }
            }
            return nil
        default:
            return self == other ? nil : path
        }
    }
}
