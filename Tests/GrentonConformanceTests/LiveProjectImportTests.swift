import Foundation
import Testing
import GrentonModel
import GrentonProvisioning

/// Checks the project import against a real installation, when one is at
/// hand: the interface imported from an `.omp` must project to exactly
/// what the archive downloaded from Object Manager for the same interface
/// projects to (spec §4.5), `version` aside. Skipped without the
/// environment, so CI and clones without an installation are unaffected;
/// nothing of the installation is ever printed.
///
///     GRENTON_LIVE_OMP=/path/house.omp GRENTON_LIVE_ZIP=dist/interface-widgets.zip swift test --filter LiveProjectImport
///
/// `GRENTON_LIVE_ZIP` names the downloaded interface; the `.omp` interface
/// with the same `id` is imported and compared field for field.
/// `GRENTON_LIVE_ZIP_SHAPE` names a second archive compared on page and
/// widget types only (an interface that changed since it was downloaded).
@Suite struct LiveProjectImportTests {
    private static let environment = ProcessInfo.processInfo.environment

    private static func load(_ variable: String) throws -> MobileInterfaceDTO? {
        guard let path = environment[variable] else { return nil }
        return try ProvisioningClient.parseInterfaceArchive(Data(contentsOf: URL(fileURLWithPath: path)))
    }

    private static func imported(id: String) throws -> MobileInterfaceDTO? {
        guard let path = environment["GRENTON_LIVE_OMP"] else { return nil }
        let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: path)))
        return try project.interface(id: id)
    }

    /// The downloaded interface's projection, with `version` neutralised.
    private static func projection(_ interface: MobileInterfaceDTO) -> JSON {
        var root = ProjectProjection.root(interface)
        if case .object(var o) = root { o["version"] = .null; root = .object(o) }
        return .object(["root": root, "mapping": MappingProjection.interface(interface)])
    }

    @Test func importMatchesTheDownloadedInterface() throws {
        guard let downloaded = try Self.load("GRENTON_LIVE_ZIP"),
              let imported = try Self.imported(id: downloaded.id) else { return }
        let difference = Self.projection(downloaded).firstDifference(from: Self.projection(imported))
        // Only the JSON path is reported: the values are the installation's.
        #expect(difference == nil, "import differs from the download at \(difference ?? "")")
    }

    @Test func importHasTheSameShapeAsAnOlderDownload() throws {
        guard let downloaded = try Self.load("GRENTON_LIVE_ZIP_SHAPE"),
              let imported = try Self.imported(id: downloaded.id) else { return }
        func shape(_ interface: MobileInterfaceDTO) -> [(name: String, types: [String])] {
            interface.pages.map { page in
                (page.name, page.items.map { item in
                    switch item {
                    case .widget(let w): return w.typeName
                    case .header: return "HEADER"
                    }
                })
            }
        }
        // Everything the download had must still be there, in order; pages
        // and widgets added since may appear anywhere.
        let after = shape(imported)
        var added = 0
        for (index, old) in shape(downloaded).enumerated() {
            guard let new = after.first(where: { $0.name == old.name }) else {
                Issue.record("page \(index) of the download is gone")
                continue
            }
            var remaining = new.types[...]
            for type in old.types {
                guard let found = remaining.firstIndex(of: type) else {
                    Issue.record("page \(index): a \(type) of the download is gone")
                    break
                }
                remaining = remaining[remaining.index(after: found)...]
            }
            added += new.types.count - old.types.count
        }
        added += after.count - downloaded.pages.count
        print("live shape: \(after.count - downloaded.pages.count) page(s) and \(added) widget(s) more than the download")
        #expect(downloaded.clus.map(\.id) == imported.clus.map(\.id), "CLU list differs")
    }
}
