import Foundation
import GrentonModel
import GrentonRuntime

/// Command boundary the entities execute through — `GrentonSystem` (or a
/// test mock) provides it by routing to the right CLU session.
public protocol CommandExecuting: Sendable {
    func execute(_ action: ActionRef) async throws
}

/// Everything a live entity needs: synchronous state reads and command
/// execution. Value type — cheap to hand to every entity.
public struct DeviceContext: Sendable {
    public let store: StateStore
    public let executor: any CommandExecuting

    public init(store: StateStore, executor: any CommandExecuting) {
        self.store = store
        self.executor = executor
    }
}

/// Per-subscriber update signal: fires when any of `keys` changes.
func filteredUpdates(keys: Set<ValueRef>, store: StateStore) -> AsyncStream<Void> {
    // Subscribe SYNCHRONOUSLY — deferring store.changes() into the task
    // would race the forwarding task's start against the first update and
    // silently drop events published in between.
    let changes = store.changes()
    return AsyncStream(bufferingPolicy: .bufferingNewest(8)) { continuation in
        let task = Task {
            for await change in changes where keys.contains(change.key) {
                continuation.yield(())
            }
            continuation.finish()
        }
        continuation.onTermination = { _ in task.cancel() }
    }
}

// MARK: - Stage 2: binding

/// Common read-only surface of every live entity — lets the facade and
/// adapters enumerate entities without switching over `BoundEntity`.
public protocol GrentonEntity: Sendable {
    var id: String { get }
    var name: String { get }
}

public struct BoundDevice: Sendable {
    public let descriptor: DeviceDescriptor
    public let entities: [BoundEntity]
}

public enum BoundEntity: Sendable {
    case toggle(ToggleEntity)
    case dimmableLight(DimmableLightEntity)
    case hsbLight(HsbLightEntity)
    case contactSensor(ContactSensorEntity)
    case sensor(SensorEntity)
    case numberSetting(NumberSettingEntity)
    case cover(CoverEntity)
    case stateSensor(StateSensorEntity)
    case trigger(TriggerEntity)
    case sceneTrigger(SceneTriggerEntity)
    case camera(CameraEntity)
    case thermostat(ThermostatEntity)

    /// The typed entity through its common surface.
    public var underlying: any GrentonEntity {
        switch self {
        case .toggle(let e): return e
        case .dimmableLight(let e): return e
        case .hsbLight(let e): return e
        case .contactSensor(let e): return e
        case .sensor(let e): return e
        case .numberSetting(let e): return e
        case .cover(let e): return e
        case .stateSensor(let e): return e
        case .trigger(let e): return e
        case .sceneTrigger(let e): return e
        case .camera(let e): return e
        case .thermostat(let e): return e
        }
    }

    public var id: String { underlying.id }
    public var name: String { underlying.name }

    /// Fires whenever this entity's state changes; read the new state from
    /// the typed entity. `nil` for entities without state (buttons, scenes,
    /// cameras) — there is nothing to wait for.
    public func updates() -> AsyncStream<Void>? {
        switch self {
        case .toggle(let e): return e.updates()
        case .dimmableLight(let e): return e.updates()
        case .hsbLight(let e): return e.updates()
        case .contactSensor(let e): return e.updates()
        case .sensor(let e): return e.updates()
        case .numberSetting(let e): return e.updates()
        case .cover(let e): return e.updates()
        case .stateSensor(let e): return e.updates()
        case .thermostat(let e): return e.updates()
        case .trigger, .sceneTrigger, .camera: return nil
        }
    }

    /// The entity as something that turns on and off — switches and lights.
    /// `nil` for everything else, deliberately including thermostats: their
    /// on/off starts and stops heating control.
    public var switchable: (any SwitchableEntity)? {
        switch self {
        case .toggle(let e): return e
        case .dimmableLight(let e): return e
        case .hsbLight(let e): return e
        default: return nil
        }
    }
}

/// Switches and lights: one on/off surface regardless of the light type.
public protocol SwitchableEntity: GrentonEntity {
    /// `nil` while the state is unknown.
    var isOn: Bool? { get }
    func turnOn() async throws
    func turnOff() async throws
}

extension SwitchableEntity {
    public func setOn(_ on: Bool) async throws {
        if on { try await turnOn() } else { try await turnOff() }
    }
}

/// Stage 2 of the device pipeline (spec §6.1): binds descriptors to the
/// runtime — registers every state ref for subscription and produces live
/// entities.
public enum DeviceBinder {
    public static func bind(
        _ descriptors: [DeviceDescriptor], context: DeviceContext
    ) -> [BoundDevice] {
        descriptors.map { descriptor in
            let entities = descriptor.entities.map { entity -> BoundEntity in
                for ref in entity.stateRefs {
                    context.store.registerKey(ref)
                }
                switch entity {
                case .toggle(let d): return .toggle(ToggleEntity(descriptor: d, context: context))
                case .dimmableLight(let d): return .dimmableLight(DimmableLightEntity(descriptor: d, context: context))
                case .hsbLight(let d): return .hsbLight(HsbLightEntity(descriptor: d, context: context))
                case .contactSensor(let d): return .contactSensor(ContactSensorEntity(descriptor: d, context: context))
                case .sensor(let d): return .sensor(SensorEntity(descriptor: d, context: context))
                case .numberSetting(let d): return .numberSetting(NumberSettingEntity(descriptor: d, context: context))
                case .cover(let d): return .cover(CoverEntity(descriptor: d, context: context))
                case .stateSensor(let d): return .stateSensor(StateSensorEntity(descriptor: d, context: context))
                case .trigger(let d): return .trigger(TriggerEntity(descriptor: d, context: context))
                case .sceneTrigger(let d): return .sceneTrigger(SceneTriggerEntity(descriptor: d, context: context))
                case .camera(let d): return .camera(CameraEntity(descriptor: d))
                case .thermostat(let d): return .thermostat(ThermostatEntity(descriptor: d, context: context))
                }
            }
            return BoundDevice(descriptor: descriptor, entities: entities)
        }
    }
}

// MARK: - Live entities (immutable; state read from the store)

public final class ToggleEntity: Sendable {
    public let descriptor: ToggleDescriptor
    private let context: DeviceContext

    init(descriptor: ToggleDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// `nil` = unknown (spec §6.3.1: ON ⇔ "ON" or true).
    public var isOn: Bool? {
        boolFromOnOff(context.store.value(for: descriptor.state))
    }

    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public final class DimmableLightEntity: Sendable {
    public let descriptor: DimmableLightDescriptor
    private let context: DeviceContext

    init(descriptor: DimmableLightDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    public var isOn: Bool? {
        guard let value = asDouble(context.store.value(for: descriptor.state)) else { return nil }
        return value > 0
    }

    /// Canonical 0...1 (spec §6.3.2).
    public var brightness: Double? {
        guard let value = asDouble(context.store.value(for: descriptor.state)) else { return nil }
        return clamp(mapRange(
            from: (descriptor.min, descriptor.max), to: (0, 1), value: value), to: 0...1)
    }

    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    public func setBrightness(_ brightness: Double) async throws {
        let clamped = clamp(brightness, to: 0...1)
        let deviceValue = mapRange(from: (0, 1), to: (descriptor.min, descriptor.max), value: clamped)
        let action = descriptor.setValueAction.withValue(
            formatDeviceNumber(deviceValue, precision: descriptor.precision))
        try await context.executor.execute(action)
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public final class HsbLightEntity: Sendable {
    public let descriptor: HsbLightDescriptor
    private let context: DeviceContext

    init(descriptor: HsbLightDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    public var isOn: Bool? {
        truthy(context.store.value(for: descriptor.powerState))
    }

    /// Canonical 0...360 (spec §6.3.3).
    public var hue: Double? { channelValue(descriptor.hue, canonical: (0, 360)) }
    /// Canonical 0...1.
    public var saturation: Double? { channelValue(descriptor.saturation, canonical: (0, 1)) }
    /// Canonical 0...1.
    public var brightness: Double? { channelValue(descriptor.brightness, canonical: (0, 1)) }

    private func channelValue(
        _ channel: HsbChannelDescriptor, canonical: (Double, Double)
    ) -> Double? {
        guard let raw = asDouble(context.store.value(for: channel.state)) else { return nil }
        // Clamp reads to the canonical range (Δ vs the reference): the
        // state contract holds even when the CLU reports out of range.
        return clamp(
            mapRange(from: channel.range, to: canonical, value: raw),
            to: canonical.0...canonical.1)
    }

    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    /// Sets hue and saturation (device values rounded to 2 decimals like
    /// the reference); ordering color → caller may follow with power.
    public func setColor(hue: Double, saturation: Double) async throws {
        try await setChannel(descriptor.hue, canonical: (0, 360), value: clamp(hue, to: 0...360))
        try await setChannel(descriptor.saturation, canonical: (0, 1), value: clamp(saturation, to: 0...1))
    }

    public func setBrightness(_ brightness: Double) async throws {
        try await setChannel(descriptor.brightness, canonical: (0, 1), value: clamp(brightness, to: 0...1))
    }

    private func setChannel(
        _ channel: HsbChannelDescriptor, canonical: (Double, Double), value: Double
    ) async throws {
        let deviceValue = mapRange(from: canonical, to: channel.range, value: value)
        let action = channel.setAction.withValue(formatDeviceNumber(deviceValue, precision: 2))
        try await context.executor.execute(action)
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(
            keys: [descriptor.powerState, descriptor.hue.state,
                   descriptor.saturation.state, descriptor.brightness.state],
            store: context.store)
    }
}

public final class ContactSensorEntity: Sendable {
    public let descriptor: ContactSensorDescriptor
    private let context: DeviceContext

    init(descriptor: ContactSensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// truthy XOR reversed (spec §6.3.4).
    public var isActive: Bool? {
        guard let raw = truthy(context.store.value(for: descriptor.state)) else { return nil }
        return descriptor.reversed ? !raw : raw
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public final class SensorEntity: Sendable {
    public let descriptor: SensorDescriptor
    private let context: DeviceContext

    init(descriptor: SensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Raw value after wire casting (spec §6.3.5) — presentation is the
    /// adapter's business, guided by the descriptor metadata.
    public var value: GrentonValue? {
        context.store.value(for: descriptor.state)
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public final class NumberSettingEntity: Sendable {
    public let descriptor: NumberSettingDescriptor
    private let context: DeviceContext

    init(descriptor: NumberSettingDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    public var value: Double? {
        asDouble(context.store.value(for: descriptor.state))
    }

    /// Step derived from precision (spec §6.3.7).
    public var step: Double { pow(10, -Double(descriptor.precision)) }

    public func setValue(_ value: Double) async throws {
        let clamped = clamp(value, to: descriptor.min...descriptor.max)
        let action = descriptor.setValueAction.withValue(
            formatDeviceNumber(clamped, precision: descriptor.precision))
        try await context.executor.execute(action)
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public enum CoverMotion: Sendable, Equatable {
    case idle
    case opening
    case closing
    case unknown
}

public final class CoverEntity: Sendable {
    public let descriptor: CoverDescriptor
    private let context: DeviceContext

    init(descriptor: CoverDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Canonical 0...100, 0 = closed (spec §6.3.8). Reads clamp to the
    /// canonical range (Δ vs the reference, which trusts raw values) —
    /// the canonical state contract holds even for a misbehaving CLU.
    public var position: Int? {
        guard let raw = asInt(context.store.value(for: descriptor.position)) else { return nil }
        return Int(clamp(Double(raw), to: 0...100))
    }

    public var isClosed: Bool? {
        guard let position else { return nil }
        return position == 0
    }

    public var motion: CoverMotion {
        switch asInt(context.store.value(for: descriptor.motionState)) {
        case 0: return .idle
        case 1: return .opening
        case 2: return .closing
        default: return .unknown
        }
    }

    /// Canonical 0...100; the device reports lamels as 0...90 on an
    /// INVERTED scale (spec §6.3.8). The raw value is truncated to an
    /// integer BEFORE mapping — the reference does `int(value)` first,
    /// and the order changes the result for fractional reports.
    public var tilt: Int? {
        guard let tiltDescriptor = descriptor.tilt,
              let raw = asInt(context.store.value(for: tiltDescriptor.position))
        else { return nil }
        let mapped = 100 - mapRange(from: (0, 90), to: (0, 100), value: Double(raw))
        return Int(clamp(mapped, to: 0...100))
    }

    public var supportsTilt: Bool { descriptor.tilt != nil }
    public var supportsStop: Bool { descriptor.stopAction != nil }

    public func open() async throws { try await setPosition(100) }
    public func close() async throws { try await setPosition(0) }

    public func setPosition(_ position: Int) async throws {
        let clamped = Int(clamp(Double(position), to: 0...100))
        // Integer string — the reference sends str(int) here (spec §6.3.8).
        try await context.executor.execute(
            descriptor.setPositionAction.withValue("\(clamped)"))
    }

    public func stop() async throws {
        guard let stopAction = descriptor.stopAction else { return }
        try await context.executor.execute(stopAction)
    }

    public func setTilt(_ tilt: Int) async throws {
        guard let tiltDescriptor = descriptor.tilt else { return }
        let clamped = clamp(Double(tilt), to: 0...100)
        let deviceValue = Int(90 - mapRange(from: (0, 100), to: (0, 90), value: clamped))
        try await context.executor.execute(
            tiltDescriptor.setAction.withValue("\(deviceValue)"))
    }

    public func openTilt() async throws { try await setTilt(100) }
    public func closeTilt() async throws { try await setTilt(0) }

    public func updates() -> AsyncStream<Void> {
        var keys: Set<ValueRef> = [descriptor.motionState, descriptor.position]
        if let tilt = descriptor.tilt { keys.insert(tilt.position) }
        return filteredUpdates(keys: keys, store: context.store)
    }
}

public enum LegacyShutterState: String, Sendable {
    case stopped, opening, closing, locked, unknown
}

public final class StateSensorEntity: Sendable {
    public let descriptor: StateSensorDescriptor
    private let context: DeviceContext

    init(descriptor: StateSensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// 0 stopped, 1 opening, 2 closing, 3 locked, else unknown (spec §6.3.9).
    public var state: LegacyShutterState {
        switch asInt(context.store.value(for: descriptor.state)) {
        case 0: return .stopped
        case 1: return .opening
        case 2: return .closing
        case 3: return .locked
        default: return .unknown
        }
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

public final class TriggerEntity: Sendable {
    public let descriptor: TriggerDescriptor
    private let context: DeviceContext

    init(descriptor: TriggerDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    public func press() async throws {
        try await context.executor.execute(descriptor.action)
    }
}

public final class SceneTriggerEntity: Sendable {
    public let descriptor: SceneTriggerDescriptor
    private let context: DeviceContext

    init(descriptor: SceneTriggerDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Runs the scene with the widget's baked-in value (spec §6.3.10).
    public func run() async throws {
        try await context.executor.execute(descriptor.action)
    }

    /// Runs with `parameter` VERBATIM as the script argument (Lua syntax is
    /// the caller's contract); the descriptor's action stays untouched.
    public func run(parameter: String) async throws {
        try await context.executor.execute(descriptor.action.withValue(parameter))
    }
}

public final class CameraEntity: Sendable {
    public let descriptor: CameraDescriptor

    init(descriptor: CameraDescriptor) {
        self.descriptor = descriptor
    }

    public var streamURL: String { descriptor.streamURL }
}

/// Thermostat operating mode — the Mode feature (spec §6.3.12).
public enum ThermostatMode: Int, Sendable, CaseIterable {
    case manual = 0
    case holiday = 1
    case schedule = 2
}

public final class ThermostatEntity: Sendable {
    public let descriptor: ThermostatDescriptor
    private let context: DeviceContext

    init(descriptor: ThermostatDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    public var currentTemperature: Double? {
        asDouble(context.store.value(for: descriptor.currentTemperature))
    }

    public var targetTemperature: Double? {
        asDouble(context.store.value(for: descriptor.targetTemperature))
    }

    public var minTemperature: Double? {
        descriptor.minTemperature.flatMap { asDouble(context.store.value(for: $0)) }
    }

    public var maxTemperature: Double? {
        descriptor.maxTemperature.flatMap { asDouble(context.store.value(for: $0)) }
    }

    /// `nil` while unknown, when the interface has no mode control, or for
    /// a value outside 0...2.
    public var mode: ThermostatMode? {
        descriptor.mode.flatMap { asInt(context.store.value(for: $0.state)) }.flatMap(ThermostatMode.init)
    }

    /// Running (State 1) vs stopped (State 0); `nil` while unknown.
    public var isOn: Bool? {
        descriptor.power.flatMap { truthy(context.store.value(for: $0.state)) }
    }

    /// ControlOutValue as reported — 0/1 for a digital output, a level for
    /// an analog one.
    public var output: Double? {
        descriptor.output.flatMap { asDouble(context.store.value(for: $0)) }
    }

    public var supportsMode: Bool { descriptor.mode != nil }
    public var supportsPower: Bool { descriptor.power != nil }

    /// Writes the manual set point, clamped to the live min/max when both
    /// are known; one decimal, reference number format (spec §10 pt 3).
    public func setTargetTemperature(_ temperature: Double) async throws {
        var value = temperature
        if let min = minTemperature, let max = maxTemperature, min <= max {
            value = clamp(value, to: min...max)
        }
        try await context.executor.execute(
            descriptor.setTargetTemperatureAction.withValue(formatDeviceNumber(value, precision: 1)))
    }

    public func setMode(_ mode: ThermostatMode) async throws {
        guard let control = descriptor.mode else { return }
        try await context.executor.execute(control.setAction.withValue("\(mode.rawValue)"))
    }

    public func turnOn() async throws { try await setPower(true) }
    public func turnOff() async throws { try await setPower(false) }

    private func setPower(_ on: Bool) async throws {
        guard let control = descriptor.power else { return }
        try await context.executor.execute(control.setAction.withValue(on ? "1" : "0"))
    }

    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: Set(EntityDescriptor.thermostat(descriptor).stateRefs), store: context.store)
    }
}

// MARK: - Common surface conformances

extension ToggleEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension DimmableLightEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension HsbLightEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension ContactSensorEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension SensorEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension NumberSettingEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension CoverEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension StateSensorEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension TriggerEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension SceneTriggerEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension CameraEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension ThermostatEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}

extension ToggleEntity: SwitchableEntity {}
extension DimmableLightEntity: SwitchableEntity {}
extension HsbLightEntity: SwitchableEntity {}
