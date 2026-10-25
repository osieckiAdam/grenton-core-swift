import Foundation
import Observation
import GrentonDevices

// The bridge between an entity's `updates()` stream and the Observation
// framework: a view that reads `observed.value` re-renders after every
// change the CLU reports. The entity itself stays what it is — an
// immutable handle whose state lives in the system's store — so this
// wrapper only has to bump a revision when the stream fires.

/// An entity a SwiftUI view can observe: the view re-renders whenever the CLU reports a change.
///
/// ```swift
/// import SwiftUI
/// import GrentonKit
/// import GrentonSwiftUI
///
/// struct ThermostatRow: View {
///     let observed: Observed<ThermostatEntity>
///     var body: some View {
///         Text("\(observed.value.currentTemperature ?? .nan, specifier: "%.1f") °C")
///     }
/// }
/// ```
///
/// Create one per entity, where the entity lives (a view model, `@State`), not in `body`. Reading ``value`` inside `body` is what subscribes the view; the wrapper stops listening when it is deallocated.
@available(iOS 17, macOS 14, *)
@Observable
@MainActor
public final class Observed<Entity: StatefulEntity> {
    private let entity: Entity
    private var revision = 0
    @ObservationIgnored private var listener: Task<Void, Never>?

    /// Starts observing `entity`.
    public init(_ entity: Entity) {
        self.entity = entity
        let updates = entity.updates()
        listener = Task { [weak self] in
            for await _ in updates {
                guard let self else { return }
                self.revision &+= 1
            }
        }
    }

    deinit {
        listener?.cancel()
    }

    /// The entity, current as of the last change the CLU reported. Read it inside `body`.
    public var value: Entity {
        _ = revision
        return entity
    }

    /// How many changes have been observed; useful in tests.
    public var changeCount: Int { revision }
}
