import Foundation
import GrentonModel
import GrentonProvisioning
import GrentonDevices
import GrentonRuntime

// The archive holds the installation's AES key, so where an app keeps it
// matters: a file in Application Support with complete file protection on
// iOS (unreadable while the device is locked), never UserDefaults or a
// plain Documents file. This type is that one correct place, plus the
// "is the download newer" check Object Manager's `version` allows.

/// Keeps the interface between runs, where it belongs: a protected file.
///
/// It holds either the archive Object Manager sends to a phone, or the
/// project file (`.omp`) with the id of the interface chosen in it; both
/// contain the installation's key.
///
/// Download once, save, and start every later run from the saved copy:
///
/// ```swift
/// import Foundation
/// import GrentonKit
///
/// let store = try InterfaceStore()
/// if try store.load() == nil {
///     let archive = try await ProvisioningClient(host: "192.168.1.50").fetchInterfaceArchive(pin: "149 853")
///     try store.save(archive)
/// }
/// let system = try store.system()
/// await system.start()
/// ```
///
/// The archive contains the CLUs' encryption key. On iOS the file gets complete protection; on macOS it lives in the app's Application Support directory. Never copy it into `UserDefaults`.
public struct InterfaceStore: Sendable {
    /// Where the archive is kept; a project file is kept beside it as `project.omp`, with `project.id` naming the chosen interface.
    public let url: URL

    private var projectURL: URL { url.deletingLastPathComponent().appendingPathComponent("project.omp") }
    private var projectIdURL: URL { url.deletingLastPathComponent().appendingPathComponent("project.id") }

    private var writingOptions: Data.WritingOptions {
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        return options
    }

    /// A store at `url`; the directory is created when missing.
    public init(url: URL) throws {
        self.url = url
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    }

    /// The default store: `interface.zip` in the app's own folder under Application Support.
    ///
    /// The folder is named after the app's bundle identifier, so two apps on one Mac never share an archive (and its key). A process without a bundle identifier — a command-line tool — has no default place: give one with ``init(url:)``.
    /// - Throws: `InterfaceStoreError.noBundleIdentifier` when the process has none.
    public init() throws {
        guard let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty else { throw InterfaceStoreError.noBundleIdentifier }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        try self.init(url: base.appendingPathComponent(bundle, isDirectory: true)
            .appendingPathComponent("Grenton", isDirectory: true).appendingPathComponent("interface.zip"))
    }

    /// Saves an archive, as `ProvisioningClient.fetchInterfaceArchive(pin:)` returns it. It is parsed first: an archive that is not an interface is not saved.
    /// - Throws: `ProvisioningError.invalidData` for an archive that is not an interface, or a file error.
    public func save(_ archive: Data) throws {
        _ = try ProvisioningClient.parseInterfaceArchive(archive)
        try archive.write(to: url, options: writingOptions)
        try removeProject()
    }

    /// Saves a project file (`.omp`) and the id of the interface to use from it — `nil` when the project has exactly one. It is parsed first; a project without that interface, or with several and no id, is not saved.
    /// - Throws: `ProvisioningError.invalidData`, `.interfaceNotFound`, `.interfaceAmbiguous`, or a file error.
    public func save(project: Data, interfaceId: String? = nil) throws {
        _ = try ProjectFile(data: project).interface(id: interfaceId)
        try project.write(to: projectURL, options: writingOptions)
        if let interfaceId {
            try Data(interfaceId.utf8).write(to: projectIdURL, options: writingOptions)
        } else if FileManager.default.fileExists(atPath: projectIdURL.path) {
            try FileManager.default.removeItem(at: projectIdURL)
        }
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// The saved archive, or `nil` when nothing was saved or a project file is saved instead.
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// The saved project file, or `nil` when nothing was saved or an archive is saved instead.
    public func loadProject() throws -> Data? {
        guard FileManager.default.fileExists(atPath: projectURL.path) else { return nil }
        return try Data(contentsOf: projectURL)
    }

    /// The saved interface, parsed, from the archive or the project file; `nil` when nothing was saved yet.
    public func interface() throws -> MobileInterfaceDTO? {
        if let archive = try load() { return try ProvisioningClient.parseInterfaceArchive(archive) }
        guard let project = try loadProject() else { return nil }
        let id = FileManager.default.fileExists(atPath: projectIdURL.path)
            ? String(decoding: try Data(contentsOf: projectIdURL), as: UTF8.self) : nil
        return try ProjectFile(data: project).interface(id: id)
    }

    private func removeProject() throws {
        for file in [projectURL, projectIdURL] where FileManager.default.fileExists(atPath: file.path) {
            try FileManager.default.removeItem(at: file)
        }
    }

    /// Whether `archive` is a newer export of the saved interface than the saved one: the same `id` with a higher `version`, or anything when nothing is saved. A different installation (another `id`) is also "newer".
    public func isNewer(_ archive: Data) throws -> Bool {
        let candidate = try ProvisioningClient.parseInterfaceArchive(archive)
        guard let saved = try interface() else { return true }
        return candidate.id != saved.id || candidate.version > saved.version
    }

    /// Removes whatever is saved: the archive or the project file.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        try removeProject()
    }

    /// A system from the saved interface. Nothing connects until `start()`.
    /// - Throws: `InterfaceStoreError.nothingSaved` when nothing was saved yet, or what `GrentonSystem(interface:)` throws.
    public func system(
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        logger: GrentonLogger = .disabled
    ) throws -> GrentonSystem {
        guard let interface = try interface() else { throw InterfaceStoreError.nothingSaved }
        return try GrentonSystem(interface: interface, socketFactory: socketFactory, logger: logger)
    }
}

/// Errors of ``InterfaceStore``.
@nonexhaustive
public enum InterfaceStoreError: Error, Sendable, Equatable {
    /// `system()` was called before any archive was saved.
    case nothingSaved
    /// `init()` was called in a process without a bundle identifier; use `init(url:)`.
    case noBundleIdentifier
}
