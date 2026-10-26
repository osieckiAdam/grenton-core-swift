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
/// `Entity` is a concrete entity type, or `any SwitchableEntity` / `any StatefulEntity` when the view does not care which: `Observed(entity.switchable!)` gives an `Observed<any SwitchableEntity>`.
///
/// Create one per entity, where the entity lives (a view model, `@State`), not in `body`. Reading ``value`` inside `body` is what subscribes the view; the wrapper stops listening when it is deallocated.
@available(iOS 17, macOS 14, *)
@Observable
@MainActor
public final class Observed<Entity: Sendable> {
    private let entity: Entity
    private var revision = 0
    @ObservationIgnored private var listener: Task<Void, Never>?

    /// Observes `entity` through `updates`, its change stream.
    public init(_ entity: Entity, updates: AsyncStream<Void>) {
        self.entity = entity
        listener = Task { [weak self] in
            for await _ in updates {
                guard let self else { return }
                self.revision &+= 1
            }
        }
    }

    /// Starts observing a concrete entity.
    public convenience init(_ entity: Entity) where Entity: StatefulEntity {
        self.init(entity, updates: entity.updates())
    }

    /// Starts observing a switch, dimmer or RGB light of any kind.
    public convenience init(_ entity: Entity) where Entity == any SwitchableEntity {
        self.init(entity, updates: entity.updates())
    }

    /// Starts observing an entity of any kind with state.
    public convenience init(_ entity: Entity) where Entity == any StatefulEntity {
        self.init(entity, updates: entity.updates())
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
