import Foundation
import GrentonModel
import GrentonRuntime
import GrentonDevices

/// Records every action the entities execute, and fails them on request.
/// Held strongly by the simulation: there is no cycle to break here, unlike
/// the live system's proxy.
final class CommandRecorder: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private var actions: [ActionRef] = []
    private var failure: (any Error)?
    /// Set by the simulation when it echoes switch commands (§6.3.1–§6.3.3).
    var echo: (@Sendable (ActionRef) -> Void)?

    func execute(_ action: ActionRef) async throws {
        // Recorded before the caller resumes, so a test that awaited the
        // command sees it in `executedActions` without waiting.
        let (failure, echo): ((any Error)?, (@Sendable (ActionRef) -> Void)?) = lock.withLock {
            actions.append(action)
            return (self.failure, self.echo)
        }
        if let failure { throw failure }
        echo?(action)
    }

    var executed: [ActionRef] { lock.withLock { actions } }
    func reset() { lock.withLock { actions.removeAll() } }
    func fail(with error: (any Error)?) { lock.withLock { failure = error } }
}

/// The devices of an interface without any CLU: the same entities as a
/// live `GrentonSystem`, over values you set, with every command recorded.
///
/// For your app's tests. Nothing connects, no key is needed:
///
/// ```swift
/// import GrentonKit
/// import GrentonSimulation
///
/// let simulation = SimulatedGrentonSystem(interface: interface)
/// guard case .thermostat(let thermostat) = simulation.entities[0] else { return }
/// simulation.set(thermostat.descriptor.currentTemperature, to: .double(21.5))
/// // thermostat.currentTemperature == 21.5
/// try await thermostat.setTargetTemperature(22)
/// // simulation.executedActions.count == 1
/// ```
///
/// A command does not change any value — on a real CLU the new value
/// arrives as a report, later. Set it yourself when the test needs it, or
/// create the simulation with `echoesSwitches: true` for a demo mode in
/// which a light turns on and off as commanded. Entities signal
/// `updates()` for values set here exactly as for reports.
public final class SimulatedGrentonSystem: Sendable {
    /// The devices as plain descriptions, without state or commands.
    public let descriptors: [DeviceDescriptor]
    /// Every device of the interface, one per widget, in page order.
    public let devices: [BoundDevice]
    /// The CLU controllers the interface lists.
    public let clus: [Clu]

    private let store: StateStore
    private let recorder: CommandRecorder

    /// Creates the devices of an interface over an empty store: every
    /// value is unknown until ``set(_:to:)``.
    ///
    /// - Parameters:
    ///   - interface: The mobile interface, downloaded or imported.
    ///   - echoesSwitches: When `true`, the on and off commands of
    ///     switches, dimmers and RGB lights set their state as a CLU would
    ///     report it (`"ON"`/`"OFF"`, a dimmer's full or zero level, `1`/`0`
    ///     for an RGB light's power) — a demo mode for previews. Every other
    ///     command still changes nothing.
    public init(interface: MobileInterfaceDTO, echoesSwitches: Bool = false) {
        clus = interface.clus.map(Clu.init(dto:))
        let store = StateStore()
        let recorder = CommandRecorder()
        self.store = store
        self.recorder = recorder
        descriptors = DeviceMapper.descriptors(for: interface)
        devices = DeviceBinder.bind(descriptors, context: DeviceContext(store: store, executor: recorder))
        if echoesSwitches {
            // On/off actions of every switchable entity, by identity.
            var onOff: [ActionRef: (ValueRef, GrentonValue)] = [:]
            for entity in devices.flatMap(\.entities) {
                switch entity {
                case .toggle(let e):
                    onOff[e.descriptor.onAction] = (e.descriptor.state, .string("ON"))
                    onOff[e.descriptor.offAction] = (e.descriptor.state, .string("OFF"))
                case .dimmableLight(let e):
                    // The state is the level: full on, fully off.
                    onOff[e.descriptor.onAction] = (e.descriptor.state, .double(e.descriptor.max))
                    onOff[e.descriptor.offAction] = (e.descriptor.state, .double(e.descriptor.min))
                case .hsbLight(let e):
                    onOff[e.descriptor.onAction] = (e.descriptor.powerState, .int(1))
                    onOff[e.descriptor.offAction] = (e.descriptor.powerState, .int(0))
                default: break
                }
            }
            let table = onOff
            recorder.echo = { action in
                if let (ref, value) = table[action] { store.updateKeys([ref], [.value(value)], includingUnknown: true) }
            }
        }
    }

    /// Every entity of every device, in device order.
    public var entities: [BoundEntity] { devices.flatMap(\.entities) }

    /// Devices grouped by what they operate on the CLU, as in the live system.
    public var physicalObjects: [PhysicalObject] { DeviceMapper.physicalObjects(for: descriptors) }

    // MARK: - Values

    /// Makes `ref` read as `value`, as if a CLU had reported it: entities
    /// that show it signal their `updates()` when it changed.
    public func set(_ ref: ValueRef, to value: GrentonValue) {
        store.registerKey(ref)
        store.updateKeys([ref], [.value(value)], includingUnknown: true)
    }

    /// Makes `ref` unknown again, as before any report: entities read
    /// `nil`. Different from ``set(_:to:)`` with `GrentonValue.null`, which
    /// is a CLU reporting nothing.
    public func clear(_ ref: ValueRef) {
        store.clearValue(for: ref)
    }

    /// The raw value of `ref`; `nil` until set.
    public func value(for ref: ValueRef) -> GrentonValue? {
        store.value(for: ref)
    }

    // MARK: - Commands

    /// Every action the entities executed since creation or ``resetCommands()``,
    /// in order, including the failed ones. A command is recorded before
    /// its call returns.
    public var executedActions: [ActionRef] { recorder.executed }

    /// Forgets the recorded actions.
    public func resetCommands() { recorder.reset() }

    /// Makes every command from now on throw `error`; `nil` lets them
    /// succeed again. Commands are recorded either way.
    public func failCommands(with error: (any Error)?) { recorder.fail(with: error) }
}
