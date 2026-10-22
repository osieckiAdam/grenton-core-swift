// An app's unit test, as a test target would write it: the simulation
// module on its own, the entities through the umbrella.
import Foundation
import GrentonKit
import GrentonSimulation

func appTest(interface: MobileInterfaceDTO) async throws {
    let simulation = SimulatedGrentonSystem(interface: interface)
    guard let light = simulation.entities.first?.switchable else { return }
    try await light.turnOn()
    precondition(simulation.executedActions.count == 1)

    if case .thermostat(let thermostat)? = simulation.entities.first {
        simulation.set(thermostat.descriptor.currentTemperature, to: .double(21.5))
        precondition(thermostat.currentTemperature == 21.5)
        simulation.clear(thermostat.descriptor.currentTemperature)
        precondition(thermostat.currentTemperature == nil)
    }
    simulation.failCommands(with: SessionError.notConnected)
    simulation.resetCommands()
}
