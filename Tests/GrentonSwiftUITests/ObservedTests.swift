import Foundation
import Observation
import Testing
import GrentonKit
import GrentonSimulation
import GrentonSwiftUI

@Suite struct ObservedTests {
    @MainActor
    private func makeToggle() throws -> (SimulatedGrentonSystem, ToggleEntity) {
        let url = try #require(Bundle.module.url(forResource: "data", withExtension: "json", subdirectory: "Fixtures"))
        let simulation = SimulatedGrentonSystem(interface: try MobileInterfaceDTO.decode(from: Data(contentsOf: url)))
        let toggle = try #require(simulation.entities.compactMap { entity -> ToggleEntity? in
            if case .toggle(let t) = entity { return t } else { return nil }
        }.first)
        return (simulation, toggle)
    }

    /// Reading `value` inside an observation registers the dependency the
    /// view relies on: a reported change fires `onChange`.
    @Test @MainActor func aReportedChangeInvalidatesTheObservation() async throws {
        let (simulation, toggle) = try makeToggle()
        let observed = Observed(toggle)
        let fired = AsyncStream<Void>.makeStream()
        let seen = withObservationTracking {
            observed.value.isOn
        } onChange: {
            fired.continuation.yield(())
        }
        #expect(seen == nil)
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        let signalled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { for await _ in fired.stream { return true }; return false }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        #expect(signalled, "the view would not re-render")
        #expect(observed.value.isOn == true)
    }

    @Test @MainActor func anUnchangedValueDoesNotCount() async throws {
        let (simulation, toggle) = try makeToggle()
        let observed = Observed(toggle)
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        for _ in 0..<100 where observed.changeCount == 0 { try await Task.sleep(for: .milliseconds(10)) }
        #expect(observed.changeCount == 1)
        simulation.set(toggle.descriptor.state, to: .string("ON"))
        try await Task.sleep(for: .milliseconds(50))
        #expect(observed.changeCount == 1)
    }

    /// Dropping the wrapper stops listening: nothing keeps it alive.
    @Test @MainActor func isReleasedWhenDropped() async throws {
        let (_, toggle) = try makeToggle()
        weak var weakObserved: Observed<ToggleEntity>?
        do {
            let observed = Observed(toggle)
            weakObserved = observed
            #expect(weakObserved != nil)
        }
        for _ in 0..<100 where weakObserved != nil { try await Task.sleep(for: .milliseconds(10)) }
        #expect(weakObserved == nil)
    }
}
