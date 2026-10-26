import Foundation
import Testing
import GrentonKit
import GrentonSimulation

@Suite struct InterfaceStoreProjectTests {
    private func fixture(_ name: String, _ ext: String) throws -> Data {
        try Data(contentsOf: try #require(Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "Fixtures")))
    }
    private func temporaryStore() throws -> InterfaceStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        return try InterfaceStore(url: directory.appendingPathComponent("interface.zip"))
    }

    @Test func keepsAProjectFileAndTheChosenInterface() throws {
        let store = try temporaryStore()
        try store.save(project: try fixture("project", "omp"))
        #expect(try store.load() == nil)
        #expect(try store.loadProject() != nil)
        #expect(try store.interface()?.name == "Single")
        #expect(!(try store.system()).devices.isEmpty)

        // Several interfaces need an id; the id is kept with the project.
        #expect(throws: ProvisioningError.interfaceAmbiguous) { try store.save(project: try fixture("project-two", "omp")) }
        try store.save(project: try fixture("project-two", "omp"), interfaceId: "66666666-7777-8888-9999-000000000000")
        #expect(try store.interface()?.name == "Integration")

        // Saving an archive replaces the project, and the other way round.
        try store.save(try fixture("interface", "zip"))
        #expect(try store.loadProject() == nil)
        #expect(try store.interface()?.id == "interface-test-001")
        try store.save(project: try fixture("project", "omp"))
        #expect(try store.load() == nil)
        try store.remove()
        #expect(try store.interface() == nil)
    }
}

@Suite struct SimulationEchoTests {
    @Test func switchesFollowTheirCommandsInDemoMode() async throws {
        let url = try #require(Bundle.module.url(forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let interface = try MobileInterfaceDTO.decode(from: Data(contentsOf: url))
        let demo = SimulatedGrentonSystem(interface: interface, echoesSwitches: true)
        let lights = demo.entities.compactMap(\.switchable)
        #expect(!lights.isEmpty)
        for light in lights {
            #expect(light.isOn == nil)
            try await light.turnOn()
            #expect(light.isOn == true, Comment(rawValue: light.name))
            try await light.turnOff()
            #expect(light.isOn == false, Comment(rawValue: light.name))
        }
        // Without the option nothing moves.
        let plain = SimulatedGrentonSystem(interface: interface)
        let light = try #require(plain.entities.compactMap(\.switchable).first)
        try await light.turnOn()
        #expect(light.isOn == nil)
    }
}
