import Foundation
import Testing
import GrentonKit

@Suite struct InterfaceStoreTests {
    private func fixture(_ name: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: "zip", subdirectory: "Fixtures")))
    }

    private func temporaryStore() throws -> InterfaceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try InterfaceStore(url: directory.appendingPathComponent("interface.zip"))
    }

    @Test func savesLoadsAndBuildsASystem() throws {
        let store = try temporaryStore()
        #expect(try store.load() == nil)
        #expect(throws: InterfaceStoreError.nothingSaved) { try store.system() }
        let archive = try fixture("interface")
        try store.save(archive)
        #expect(try store.load() == archive)
        #expect(try store.interface()?.id == "interface-test-001")
        let system = try store.system()
        #expect(!system.devices.isEmpty)
        try store.remove()
        #expect(try store.load() == nil)
    }

    @Test func refusesWhatIsNotAnInterface() throws {
        let store = try temporaryStore()
        #expect(throws: ProvisioningError.self) { try store.save(Data("not a zip".utf8)) }
        #expect(try store.load() == nil)
    }

    @Test func tellsANewerExportApart() throws {
        let store = try temporaryStore()
        let archive = try fixture("interface")
        #expect(try store.isNewer(archive))         // nothing saved yet
        try store.save(archive)
        #expect(try store.isNewer(archive) == false)
        #expect(try store.isNewer(try fixture("interface-newer")))
    }
}

@Suite struct InterfaceStoreDefaultLocationTests {
    @Test func theDefaultStoreIsScopedToTheApp() throws {
        // Two apps never share the archive and its key: the default path
        // carries the bundle identifier, and a process without one (this
        // test runner, a command-line tool) gets no default at all.
        if let bundle = Bundle.main.bundleIdentifier, !bundle.isEmpty {
            let store = try InterfaceStore()
            #expect(store.url.pathComponents.contains(bundle))
            #expect(store.url.lastPathComponent == "interface.zip")
        } else {
            #expect(throws: InterfaceStoreError.noBundleIdentifier) { try InterfaceStore() }
        }
    }
}
