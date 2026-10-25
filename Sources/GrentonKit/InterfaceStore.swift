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

/// Keeps the interface archive between runs, where it belongs: a protected file.
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
    /// Where the archive is kept.
    public let url: URL

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
        var options: Data.WritingOptions = [.atomic]
        #if os(iOS)
        options.insert(.completeFileProtection)
        #endif
        try archive.write(to: url, options: options)
    }

    /// The saved archive, or `nil` when nothing was saved yet.
    public func load() throws -> Data? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// The saved interface, parsed; `nil` when nothing was saved yet.
    public func interface() throws -> MobileInterfaceDTO? {
        try load().map { try ProvisioningClient.parseInterfaceArchive($0) }
    }

    /// Whether `archive` is a newer export of the saved interface than the saved one: the same `id` with a higher `version`, or anything when nothing is saved. A different installation (another `id`) is also "newer".
    public func isNewer(_ archive: Data) throws -> Bool {
        let candidate = try ProvisioningClient.parseInterfaceArchive(archive)
        guard let saved = try interface() else { return true }
        return candidate.id != saved.id || candidate.version > saved.version
    }

    /// Removes the saved archive, if any.
    public func remove() throws {
        if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }

    /// A system from the saved archive. Nothing connects until `start()`.
    /// - Throws: `InterfaceStoreError.nothingSaved` when nothing was saved yet, or what `GrentonSystem(interfaceArchive:)` throws.
    public func system(
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        logger: GrentonLogger = .disabled
    ) throws -> GrentonSystem {
        guard let archive = try load() else { throw InterfaceStoreError.nothingSaved }
        return try GrentonSystem(interfaceArchive: archive, socketFactory: socketFactory, logger: logger)
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
