import Foundation
import Testing
import GrentonKit
import GrentonSimulation
import GrentonSwiftUI

@Suite struct ObservedTests {
    @Test @MainActor func bumpsOnEveryReportedChange() async throws {
        let url = try #require(Bundle.module.url(forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let simulation = SimulatedGrentonSystem(interface: try MobileInterfaceDTO.decode(from: Data(contentsOf: url)))
        guard let toggle = simulation.entities.compactMap({ entity -> ToggleEntity? in
            if case .toggle(let t) = entity { return t } else { return nil }
        }).first else { Issue.record("expected a toggle"); return }

        let observed = Observed(toggle)
        #expect(observed.changeCount == 0)
        #expect(observed.value.isOn == nil)
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        for _ in 0..<50 where observed.changeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.changeCount == 1)
        #expect(observed.value.isOn == true)
        simulation.set(toggle.descriptor.state, to: .string("ON"))   // unchanged: no signal
        try await Task.sleep(for: .milliseconds(50))
        #expect(observed.changeCount == 1)
    }
}
