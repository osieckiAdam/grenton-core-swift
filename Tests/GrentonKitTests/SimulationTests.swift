import Foundation
import Testing
import GrentonKit
import GrentonSimulation

/// The simulation seen as an app's test target sees it: the public API
/// only, through the umbrella and the simulation module.
@Suite struct SimulationTests {
    private struct NotAToggle: Error {}
    private func load() throws -> SimulatedGrentonSystem {
        let url = try #require(Bundle.module.url(forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        return SimulatedGrentonSystem(interface: try MobileInterfaceDTO.decode(from: Data(contentsOf: url)))
    }

    private func toggle(in simulation: SimulatedGrentonSystem) throws -> ToggleEntity {
        let entity = try #require(simulation.entities.first { $0.id == "w-onoff_0" })
        guard case .toggle(let toggle) = entity else { throw NotAToggle() }
        return toggle
    }

    @Test func valuesStartUnknownAndFollowSet() throws {
        let simulation = try load()
        let toggle = try toggle(in: simulation)
        #expect(toggle.isOn == nil)
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        #expect(toggle.isOn == true)
        simulation.set(toggle.descriptor.state, to: .null)
        #expect(toggle.isOn == nil)
        #expect(simulation.value(for: toggle.descriptor.state) == .null)
        simulation.clear(toggle.descriptor.state)
        #expect(simulation.value(for: toggle.descriptor.state) == nil)
    }

    @Test func commandsAreRecordedBeforeTheyReturn() async throws {
        let simulation = try load()
        let toggle = try toggle(in: simulation)
        try await toggle.turnOn()
        #expect(simulation.executedActions == [toggle.descriptor.onAction])
        // A command changes no value: the CLU would report it later.
        #expect(toggle.isOn == nil)
        simulation.resetCommands()
        #expect(simulation.executedActions.isEmpty)
    }

    @Test func commandsFailOnRequest() async throws {
        let simulation = try load()
        let toggle = try toggle(in: simulation)
        simulation.failCommands(with: SessionError.notConnected)
        await #expect(throws: SessionError.self) { try await toggle.turnOff() }
        #expect(simulation.executedActions == [toggle.descriptor.offAction])
        simulation.failCommands(with: nil)
        try await toggle.turnOff()
    }

    @Test func setSignalsTheEntity() async throws {
        let simulation = try load()
        let toggle = try toggle(in: simulation)
        let updates = toggle.updates()
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        let signalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in updates { return true }; return false }
            group.addTask { try? await Task.sleep(for: .milliseconds(500)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(signalled)
        #expect(toggle.isOn == true)
    }

    @Test func theUmbrellaExposesEveryModule() throws {
        let simulation = try load()
        // Model, Devices, Runtime and Provisioning through one import.
        let ref: ValueRef = .attribute(cluId: simulation.clus[0].id, objectName: "DOU8272", index: "0")
        #expect(simulation.value(for: ref) == nil)
        let diagnostics = SessionDiagnostics.idle
        #expect(diagnostics.state == .idle)
        _ = ProvisioningClient.self
    }
}
