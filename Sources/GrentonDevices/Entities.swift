import Foundation
import GrentonModel
import GrentonRuntime

/// Command boundary the entities execute through — `GrentonSystem` (or a
/// test mock) provides it by routing to the right CLU session.
package protocol CommandExecuting: Sendable {
    func execute(_ action: ActionRef) async throws
}

/// Everything a live entity needs: synchronous state reads and command
/// execution. Value type — cheap to hand to every entity.
package struct DeviceContext: Sendable {
    /// Where entities read their state.
    package let store: StateStore
    /// Where entities send their commands.
    package let executor: any CommandExecuting

    /// Creates a context from a store and a command executor.
    package init(store: StateStore, executor: any CommandExecuting) {
        self.store = store
        self.executor = executor
    }
}

/// Per-subscriber update signal: fires when any of `keys` changes. The
/// store filters under its lock (spec §6.5): a signal cannot be lost to
/// other keys' changes, which a filter on top of the shared, bounded
/// change stream allowed.
func filteredUpdates(keys: Set<ValueRef>, store: StateStore) -> AsyncStream<Void> {
    store.updates(for: keys)
}

// MARK: - Stage 2: binding

/// What every entity has: a stable id and a name.
public protocol GrentonEntity: Sendable {
    /// The stable id: the widget id plus a suffix, such as `k3Xq9TzA_0`.
    var id: String { get }
    /// The label from the mobile interface.
    var name: String { get }
}

/// A device of a running system: one widget of the interface and its live
/// entities.
public struct BoundDevice: Sendable {
    /// What the device is: its id, kind, name and page.
    public let descriptor: DeviceDescriptor
    /// The things you read and control, such as the two relays of a double
    /// switch.
    public let entities: [BoundEntity]
}

// Identifiable only, not Hashable (review finding): two systems built from
// the same interface would compare equal by id while commanding different
// executors. Ids are scoped to an installation; key your own collections
// by `id`.
extension BoundDevice: Identifiable {
    /// The widget id; the same as ``DeviceDescriptor/id``. Unique within one installation.
    public var id: String { descriptor.id }
}

// Catalogue enums are @nonexhaustive (SE-0487): Grenton adds widget types,
// so a new case is a minor release. Inside this package switches stay
// exhaustive; an app adds `@unknown default`. Frozen by design and so
// left exhaustive: GrentonValue, ValueRef (the wire protocol's shapes),
// SessionState, DeviceNumberFormat.
/// A live entity: something you read or control, such as a light, a
/// thermostat or a sensor.
///
/// Switch over it to reach the typed entity:
///
/// ```swift
/// if case .thermostat(let thermostat) = entity {
///     print(thermostat.currentTemperature ?? .nan)
/// }
/// ```
///
/// For lights and switches, ``switchable`` saves the switch.
@nonexhaustive
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
    case eventSchedule(EventScheduleEntity)
    case tvRemote(TvRemoteEntity)

    /// The entity as ``GrentonEntity``, for its id and name.
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
        case .eventSchedule(let e): return e
        case .tvRemote(let e): return e
        }
    }

    /// The stable id: the widget id plus a suffix, such as `k3Xq9TzA_0`.
    /// Use it to store your own settings for this entity.
    public var id: String { underlying.id }
    /// The label from the mobile interface.
    public var name: String { underlying.name }

    /// A stream that fires whenever this entity's state changes.
    ///
    /// Read the new state from the typed entity when it fires. `nil` for
    /// entities without state (buttons, scenes and cameras).
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
        case .eventSchedule(let e): return e.updates()
        case .trigger, .sceneTrigger, .camera, .tvRemote: return nil
        }
    }

    /// The entity as a switch or light, with one on/off surface for all of
    /// them.
    ///
    /// `nil` for everything else, including thermostats: turning a
    /// thermostat off stops heating control, which code that switches off
    /// "all lights" should not do by accident.
    public var switchable: (any SwitchableEntity)? {
        switch self {
        case .toggle(let e): return e
        case .dimmableLight(let e): return e
        case .hsbLight(let e): return e
        default: return nil
        }
    }
}

/// A switch, dimmer or RGB light: anything that turns on and off.
///
/// Get one from ``BoundEntity/switchable``.
public protocol SwitchableEntity: GrentonEntity {
    /// Whether it is on; `nil` until the CLU has reported it.
    var isOn: Bool? { get }
    /// Turns it on.
    func turnOn() async throws
    /// Turns it off.
    func turnOff() async throws
}

extension SwitchableEntity {
    /// Turns it on or off.
    public func setOn(_ on: Bool) async throws {
        if on { try await turnOn() } else { try await turnOff() }
    }
}

// Stage 2 of the device pipeline (spec §6.1): binds descriptors to the
// runtime — registers every state ref for subscription and produces live
// entities.

/// Builds live devices from descriptors. ``GrentonSystem`` does this for
/// you; use it only to run devices on your own store and command executor.
package enum DeviceBinder {
    /// Turns descriptors into live devices, registering every value they read in the store.
    package static func bind(
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
                case .eventSchedule(let d): return .eventSchedule(EventScheduleEntity(descriptor: d, context: context))
                case .tvRemote(let d): return .tvRemote(TvRemoteEntity(descriptor: d, context: context))
                case .thermostat(let d): return .thermostat(ThermostatEntity(descriptor: d, context: context))
                }
            }
            return BoundDevice(descriptor: descriptor, entities: entities)
        }
    }
}

// MARK: - Live entities (immutable; state read from the store)

/// An on/off switch: a relay behind a light, a socket or any other load.
public final class ToggleEntity: Sendable {
    /// What the switch is: its state reference and on/off actions.
    public let descriptor: ToggleDescriptor
    private let context: DeviceContext

    init(descriptor: ToggleDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // `nil` = unknown (spec §6.3.1: ON ⇔ "ON" or true).
    /// Whether it is on; `nil` until the CLU has reported it.
    public var isOn: Bool? {
        boolFromOnOff(context.store.value(for: descriptor.state))
    }

    /// Turns it on.
    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    /// Turns it off.
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// A dimmable light.
public final class DimmableLightEntity: Sendable {
    /// What the light is: its range, precision and actions.
    public let descriptor: DimmableLightDescriptor
    private let context: DeviceContext

    init(descriptor: DimmableLightDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Whether it is on (brightness above zero); `nil` until the CLU has reported it.
    public var isOn: Bool? {
        guard let value = asDouble(context.store.value(for: descriptor.state)) else { return nil }
        return value > 0
    }

    // Canonical 0...1 (spec §6.3.2).
    /// Brightness from 0 (off) to 1 (full); `nil` until the CLU has reported it.
    public var brightness: Double? {
        guard let value = asDouble(context.store.value(for: descriptor.state)) else { return nil }
        return clamp(mapRange(
            from: (descriptor.min, descriptor.max), to: (0, 1), value: value), to: 0...1)
    }

    /// Turns it on, at the brightness the device chooses.
    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    /// Turns it off.
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    /// Sets the brightness, from 0 (off) to 1 (full). Values outside the range are clamped.
    public func setBrightness(_ brightness: Double) async throws {
        let clamped = clamp(brightness, to: 0...1)
        let deviceValue = mapRange(from: (0, 1), to: (descriptor.min, descriptor.max), value: clamped)
        let action = descriptor.setValueAction.withValue(
            formatDeviceNumber(deviceValue, precision: descriptor.precision))
        try await context.executor.execute(action)
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// A colour light (RGB LED) controlled by hue, saturation and brightness.
public final class HsbLightEntity: Sendable {
    /// What the light is: its channels and actions.
    public let descriptor: HsbLightDescriptor
    private let context: DeviceContext

    init(descriptor: HsbLightDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Whether it is on; `nil` until the CLU has reported it.
    public var isOn: Bool? {
        truthy(context.store.value(for: descriptor.powerState))
    }

    // Canonical 0...360 (spec §6.3.3).
    /// Hue in degrees, from 0 to 360; `nil` until the CLU has reported it.
    public var hue: Double? { channelValue(descriptor.hue, canonical: (0, 360)) }
    // Canonical 0...1.
    /// Saturation from 0 (white) to 1 (full colour); `nil` until the CLU has reported it.
    public var saturation: Double? { channelValue(descriptor.saturation, canonical: (0, 1)) }
    // Canonical 0...1.
    /// Brightness from 0 to 1; `nil` until the CLU has reported it.
    public var brightness: Double? { channelValue(descriptor.brightness, canonical: (0, 1)) }

    private func channelValue(
        _ channel: HsbChannelDescriptor, canonical: (Double, Double)
    ) -> Double? {
        guard let raw = asDouble(context.store.value(for: channel.state)) else { return nil }
        // Clamp reads to the canonical range (Δ vs the reference): the
        // state contract holds even when the CLU reports out of range.
        return clamp(
            mapRange(from: channel.range.tuple, to: canonical, value: raw),
            to: canonical.0...canonical.1)
    }

    /// Turns it on.
    public func turnOn() async throws { try await context.executor.execute(descriptor.onAction) }
    /// Turns it off.
    public func turnOff() async throws { try await context.executor.execute(descriptor.offAction) }

    // Sets hue and saturation (device values rounded to 2 decimals like
    // the reference); ordering color → caller may follow with power.
    /// Sets the colour.
    ///
    /// - Parameters:
    ///   - hue: Degrees, from 0 to 360.
    ///   - saturation: From 0 (white) to 1 (full colour).
    public func setColor(hue: Double, saturation: Double) async throws {
        try await setChannel(descriptor.hue, canonical: (0, 360), value: clamp(hue, to: 0...360))
        try await setChannel(descriptor.saturation, canonical: (0, 1), value: clamp(saturation, to: 0...1))
    }

    /// Sets the brightness, from 0 to 1.
    public func setBrightness(_ brightness: Double) async throws {
        try await setChannel(descriptor.brightness, canonical: (0, 1), value: clamp(brightness, to: 0...1))
    }

    private func setChannel(
        _ channel: HsbChannelDescriptor, canonical: (Double, Double), value: Double
    ) async throws {
        let deviceValue = mapRange(from: canonical, to: channel.range.tuple, value: value)
        let action = channel.setAction.withValue(formatDeviceNumber(deviceValue, precision: 2))
        try await context.executor.execute(action)
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(
            keys: [descriptor.powerState, descriptor.hue.state,
                   descriptor.saturation.state, descriptor.brightness.state],
            store: context.store)
    }
}

/// A binary sensor, such as a door or window contact.
public final class ContactSensorEntity: Sendable {
    /// What the sensor is, including its on/off labels.
    public let descriptor: ContactSensorDescriptor
    private let context: DeviceContext

    init(descriptor: ContactSensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // truthy XOR reversed (spec §6.3.4).
    /// Whether the sensor is active (for example, the door is open), with the widget's “reverse state” setting already applied; `nil` until the CLU has reported it.
    public var isActive: Bool? {
        guard let raw = truthy(context.store.value(for: descriptor.state)) else { return nil }
        return descriptor.reversed ? !raw : raw
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// A value sensor: temperature, humidity, a text status, or one channel of a multisensor.
public final class SensorEntity: Sendable {
    /// What the sensor measures: its kind, unit and precision.
    public let descriptor: SensorDescriptor
    private let context: DeviceContext

    init(descriptor: SensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // Raw value after wire casting (spec §6.3.5) — presentation is the
    // adapter's business, guided by the descriptor metadata.
    /// The reported value as the CLU sent it (a number, text or flag); `nil` until the CLU has reported it.
    ///
    /// Use the descriptor's unit and precision to present it.
    public var value: GrentonValue? {
        context.store.value(for: descriptor.state)
    }

    /// The reported value as a number; `nil` until reported, or when the CLU sent text or a flag.
    public var number: Double? {
        asDouble(value)
    }

    /// The unit to show next to ``number``: the measured quantity's own (`"°C"`, `"ppm"`, `"lx"`…) or the widget's (`"%"` or `"°"`); `nil` when the interface gives none.
    public var unit: String? {
        if let canonical = descriptor.kind.canonicalUnit { return canonical }
        switch descriptor.grentonUnit {
        case .percent?: return "%"
        case .degree?: return "°"
        case .unknown?, nil: return nil
        }
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// A number you can set within a range, such as a set point shown as a slider.
public final class NumberSettingEntity: Sendable {
    /// What the setting is: its range and precision.
    public let descriptor: NumberSettingDescriptor
    private let context: DeviceContext

    init(descriptor: NumberSettingDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// The current value; `nil` until the CLU has reported it.
    public var value: Double? {
        asDouble(context.store.value(for: descriptor.state))
    }

    // Step derived from precision (spec §6.3.7).
    /// The smallest meaningful change, from the widget's precision.
    public var step: Double { pow(10, -Double(descriptor.precision)) }

    /// Sets the value. Values outside the range are clamped.
    public func setValue(_ value: Double) async throws {
        let clamped = clamp(value, to: descriptor.min...descriptor.max)
        let action = descriptor.setValueAction.withValue(
            formatDeviceNumber(clamped, precision: descriptor.precision))
        try await context.executor.execute(action)
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// What a shutter is doing right now.
@nonexhaustive
public enum CoverMotion: Sendable, Equatable {
    /// Not moving.
    case idle
    /// Opening.
    case opening
    /// Closing.
    case closing
    /// Not reported yet, or a value the library does not know.
    case unknown
}

/// A roller shutter or blind, optionally with tiltable slats.
public final class CoverEntity: Sendable {
    /// What the shutter is: its state references and actions.
    public let descriptor: CoverDescriptor
    private let context: DeviceContext

    init(descriptor: CoverDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // Canonical 0...100, 0 = closed (spec §6.3.8). Reads clamp to the
    // canonical range (Δ vs the reference, which trusts raw values) —
    // the canonical state contract holds even for a misbehaving CLU.
    /// Position from 0 (closed) to 100 (open); `nil` until the CLU has reported it.
    public var position: Int? {
        guard let raw = asInt(context.store.value(for: descriptor.position)) else { return nil }
        return Int(clamp(Double(raw), to: 0...100))
    }

    /// Whether it is fully closed; `nil` until the CLU has reported it.
    public var isClosed: Bool? {
        guard let position else { return nil }
        return position == 0
    }

    /// Whether it is moving and in which direction.
    public var motion: CoverMotion {
        switch asInt(context.store.value(for: descriptor.motionState)) {
        case 0: return .idle
        case 1: return .opening
        case 2: return .closing
        default: return .unknown
        }
    }

    // Canonical 0...100; the device reports lamels as 0...90 on an
    // INVERTED scale (spec §6.3.8). The raw value is truncated to an
    // integer BEFORE mapping — the reference does `int(value)` first,
    // and the order changes the result for fractional reports.
    /// Slat tilt from 0 (closed) to 100 (open); `nil` until reported, or when the shutter has no slats.
    public var tilt: Int? {
        guard let tiltDescriptor = descriptor.tilt,
              let raw = asInt(context.store.value(for: tiltDescriptor.position))
        else { return nil }
        let mapped = 100 - mapRange(from: (0, 90), to: (0, 100), value: Double(raw))
        return Int(clamp(mapped, to: 0...100))
    }

    /// Whether the shutter has tiltable slats.
    public var supportsTilt: Bool { descriptor.tilt != nil }
    /// Whether ``stop()`` can stop a moving shutter.
    public var supportsStop: Bool { descriptor.stopAction != nil }

    /// Opens it fully.
    public func open() async throws { try await setPosition(100) }
    /// Closes it fully.
    public func close() async throws { try await setPosition(0) }

    /// Moves it to a position from 0 (closed) to 100 (open). Values outside the range are clamped.
    public func setPosition(_ position: Int) async throws {
        let clamped = Int(clamp(Double(position), to: 0...100))
        // Integer string — the reference sends str(int) here (spec §6.3.8).
        try await context.executor.execute(
            descriptor.setPositionAction.withValue("\(clamped)"))
    }

    /// Stops it. Does nothing when ``supportsStop`` is `false`.
    public func stop() async throws {
        guard let stopAction = descriptor.stopAction else { return }
        try await context.executor.execute(stopAction)
    }

    /// Tilts the slats, from 0 (closed) to 100 (open). Does nothing without slats.
    public func setTilt(_ tilt: Int) async throws {
        guard let tiltDescriptor = descriptor.tilt else { return }
        let clamped = clamp(Double(tilt), to: 0...100)
        let deviceValue = Int(90 - mapRange(from: (0, 100), to: (0, 90), value: clamped))
        try await context.executor.execute(
            tiltDescriptor.setAction.withValue("\(deviceValue)"))
    }

    /// Opens the slats fully.
    public func openTilt() async throws { try await setTilt(100) }
    /// Closes the slats fully.
    public func closeTilt() async throws { try await setTilt(0) }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        var keys: Set<ValueRef> = [descriptor.motionState, descriptor.position]
        if let tilt = descriptor.tilt { keys.insert(tilt.position) }
        return filteredUpdates(keys: keys, store: context.store)
    }
}

/// What an older-style shutter reports: stopped, opening, closing, locked or unknown.
@nonexhaustive
public enum LegacyShutterState: String, Sendable {
    case stopped, opening, closing, locked, unknown
}

/// The state of an older-style shutter widget, which has no position.
public final class StateSensorEntity: Sendable {
    /// What the sensor reads.
    public let descriptor: StateSensorDescriptor
    private let context: DeviceContext

    init(descriptor: StateSensorDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // 0 stopped, 1 opening, 2 closing, 3 locked, else unknown (spec §6.3.9).
    /// The current state; `.unknown` until reported.
    public var state: LegacyShutterState {
        switch asInt(context.store.value(for: descriptor.state)) {
        case 0: return .stopped
        case 1: return .opening
        case 2: return .closing
        case 3: return .locked
        default: return .unknown
        }
    }

    /// A stream that fires whenever the state changes.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: [descriptor.state], store: context.store)
    }
}

/// A button that runs one action, such as the button of a gate or of a door sensor.
public final class TriggerEntity: Sendable {
    /// The action the button runs.
    public let descriptor: TriggerDescriptor
    private let context: DeviceContext

    init(descriptor: TriggerDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Presses the button.
    public func press() async throws {
        try await context.executor.execute(descriptor.action)
    }
}

/// A scene: a script on the CLU that sets several devices at once.
public final class SceneTriggerEntity: Sendable {
    /// The script the scene runs.
    public let descriptor: SceneTriggerDescriptor
    private let context: DeviceContext

    init(descriptor: SceneTriggerDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    // Runs the scene with the widget's baked-in value (spec §6.3.10).
    /// Runs the scene.
    public func run() async throws {
        try await context.executor.execute(descriptor.action)
    }

    // Runs with `parameter` VERBATIM as the script argument (Lua syntax is
    // the caller's contract); the descriptor's action stays untouched.
    /// Runs the scene with an argument for its script.
    ///
    /// The argument is passed as written, in Lua syntax: `"text"` with quotes, `42`, or an empty string for none. Only pass values you trust.
    public func run(parameter: String) async throws {
        try await context.executor.execute(descriptor.action.withValue(parameter))
    }
}

/// A camera from the interface. The library only provides its stream address.
public final class CameraEntity: Sendable {
    /// What the camera is.
    public let descriptor: CameraDescriptor

    init(descriptor: CameraDescriptor) {
        self.descriptor = descriptor
    }

    /// The stream address from the interface, such as an RTSP URL.
    public var streamURL: String { descriptor.streamURL }
}

// Thermostat operating mode — the Mode feature (spec §6.3.12).
/// How a thermostat picks its target temperature.
@nonexhaustive
public enum ThermostatMode: Int, Sendable, CaseIterable {
    /// Holds the set point you choose with `setTargetTemperature(_:)`.
    case manual = 0
    /// Holds the holiday temperature configured on the CLU.
    case holiday = 1
    /// Follows the weekly schedule configured in Object Manager.
    case schedule = 2
}

/// A thermostat: current and target temperature, operating mode, and whether it controls the heating.
public final class ThermostatEntity: Sendable {
    /// What the thermostat is: its state references and actions.
    public let descriptor: ThermostatDescriptor
    private let context: DeviceContext

    init(descriptor: ThermostatDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// Measured temperature in °C; `nil` until the CLU has reported it.
    public var currentTemperature: Double? {
        asDouble(context.store.value(for: descriptor.currentTemperature))
    }

    /// The temperature the thermostat aims for now, in °C; `nil` until the CLU has reported it.
    ///
    /// It follows the mode: your set point in manual mode, the schedule or the holiday value otherwise.
    public var targetTemperature: Double? {
        asDouble(context.store.value(for: descriptor.targetTemperature))
    }

    /// Lowest allowed target in °C; `nil` until reported, or when the interface does not expose it.
    public var minTemperature: Double? {
        descriptor.minTemperature.flatMap { asDouble(context.store.value(for: $0)) }
    }

    /// Highest allowed target in °C; `nil` until reported, or when the interface does not expose it.
    public var maxTemperature: Double? {
        descriptor.maxTemperature.flatMap { asDouble(context.store.value(for: $0)) }
    }

    // `nil` while unknown, when the interface has no mode control, or for
    // a value outside 0...2.
    /// The operating mode; `nil` until reported, when the interface does not expose it, or for a value the library does not know.
    public var mode: ThermostatMode? {
        descriptor.mode.flatMap { asInt(context.store.value(for: $0.state)) }.flatMap(ThermostatMode.init)
    }

    // Running (State 1) vs stopped (State 0); `nil` while unknown.
    /// Whether the thermostat controls its output (heating or cooling); `nil` until reported, or when the interface does not expose it.
    ///
    /// Not "on" like a light: an inactive thermostat still measures, it just stops heating or cooling.
    public var isActive: Bool? {
        descriptor.power.flatMap { truthy(context.store.value(for: $0.state)) }
    }

    // ControlOutValue as reported — 0/1 for a digital output, a level for
    // an analog one.
    /// What the thermostat currently drives its output with: 0 or 1 for an on/off output, a level for an analog one.
    public var output: Double? {
        descriptor.output.flatMap { asDouble(context.store.value(for: $0)) }
    }

    /// Whether ``setMode(_:)`` has an effect.
    public var supportsMode: Bool { descriptor.mode != nil }
    /// Whether ``setActive(_:)`` has an effect.
    public var supportsPower: Bool { descriptor.power != nil }

    // Writes the manual set point, clamped to the live min/max when both
    // are known; one decimal, reference number format (spec §10 pt 3).
    /// Sets the target temperature for manual mode, in °C.
    ///
    /// The value is clamped to ``minTemperature`` and ``maxTemperature`` when both are known.
    public func setTargetTemperature(_ temperature: Double) async throws {
        var value = temperature
        if let min = minTemperature, let max = maxTemperature, min <= max {
            value = clamp(value, to: min...max)
        }
        try await context.executor.execute(
            descriptor.setTargetTemperatureAction.withValue(formatDeviceNumber(value, precision: 1)))
    }

    /// Switches the operating mode. Does nothing when ``supportsMode`` is `false`.
    public func setMode(_ mode: ThermostatMode) async throws {
        guard let control = descriptor.mode else { return }
        try await context.executor.execute(control.setAction.withValue("\(mode.rawValue)"))
    }

    /// Starts (`true`) or stops (`false`) controlling the output; stopped, the thermostat no longer heats or cools. Does nothing when ``supportsPower`` is `false`.
    public func setActive(_ active: Bool) async throws {
        guard let control = descriptor.power else { return }
        try await context.executor.execute(control.setAction.withValue(active ? "1" : "0"))
    }

    /// A stream that fires whenever the state changes.
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
extension EventScheduleEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}
extension TvRemoteEntity: GrentonEntity {
    public var id: String { descriptor.id }
    public var name: String { descriptor.name }
}

/// An event scheduler: up to 16 rules, each a time of day on chosen weekdays, that fire an action on the CLU.
///
/// The CLU reports the rules as a list; add, delete, enable and disable them by number. A new rule shows up in ``rules`` with the next report.
public final class EventScheduleEntity: Sendable {
    /// What the scheduler is: its state references and actions.
    public let descriptor: EventScheduleDescriptor
    private let context: DeviceContext

    init(descriptor: EventScheduleDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    private func rules(at ref: ValueRef?) -> [ScheduleRule]? {
        guard let ref, case .string(let text)? = context.store.value(for: ref) else { return nil }
        return ScheduleRule.rules(in: text)
    }

    /// Whether the scheduler fires its rules; `nil` until the CLU has reported it.
    public var isActive: Bool? { truthy(context.store.value(for: descriptor.state)) }

    /// The rules in the CLU's order (by their next firing time); `nil` until reported, or when the CLU reports none.
    public var rules: [ScheduleRule]? { rules(at: descriptor.ruleList) }

    /// How many rules the scheduler has; `nil` until reported, or when the interface does not expose it.
    public var ruleCount: Int? { descriptor.ruleCount.flatMap { asInt(context.store.value(for: $0)) } }

    /// How many more rules fit (of 16); `nil` until reported, or when the interface does not expose it.
    public var freeRuleSlots: Int? { descriptor.ruleSpace.flatMap { asInt(context.store.value(for: $0)) } }

    /// The rule that fires next; `nil` until reported, when none is due, or when the interface does not expose it.
    public var nextRule: ScheduleRule? { rules(at: descriptor.nextRule)?.first }

    /// The rule firing now; `nil` until reported, when none is running, or when the interface does not expose it.
    public var currentRule: ScheduleRule? { rules(at: descriptor.currentRule)?.first }

    /// Whether `setActive(true)` has an effect.
    public var supportsStarting: Bool { descriptor.startAction != nil }
    /// Whether `setActive(false)` has an effect.
    public var supportsStopping: Bool { descriptor.stopAction != nil }
    /// Whether ``enableRule(_:)`` has an effect.
    public var supportsEnablingRules: Bool { descriptor.enableRuleAction != nil }
    /// Whether ``disableRule(_:)`` has an effect.
    public var supportsDisablingRules: Bool { descriptor.disableRuleAction != nil }

    /// Starts (`true`) or stops (`false`) the scheduler. Does nothing when the interface has no action for that direction (``supportsStarting``, ``supportsStopping``).
    public func setActive(_ active: Bool) async throws {
        guard let action = active ? descriptor.startAction : descriptor.stopAction else { return }
        try await context.executor.execute(action)
    }

    // The CRON text is a string with spaces and commas: §5.3.4 sends it
    // quoted, exactly as the app does.
    /// Adds a rule firing at `hour`:`minute` on `days`. Hour, minute or days out of range, or no days: nothing is sent and `false` is returned.
    ///
    /// The CLU numbers the rule; it appears in ``rules`` with the next report.
    @discardableResult
    public func addRule(hour: Int, minute: Int, days: Set<Weekday>) async throws -> Bool {
        guard let cron = ScheduleRule.cron(hour: hour, minute: minute, days: days) else { return false }
        try await context.executor.execute(descriptor.addRuleAction.withValue(cron))
        return true
    }

    /// Deletes the rule with that number (1–16).
    public func deleteRule(_ id: Int) async throws {
        try await context.executor.execute(descriptor.deleteRuleAction.withValue("\(id)"))
    }

    /// Enables the rule with that number. Does nothing when ``supportsEnablingRules`` is `false`.
    public func enableRule(_ id: Int) async throws {
        guard let action = descriptor.enableRuleAction else { return }
        try await context.executor.execute(action.withValue("\(id)"))
    }

    /// Disables the rule with that number. Does nothing when ``supportsDisablingRules`` is `false`.
    public func disableRule(_ id: Int) async throws {
        guard let action = descriptor.disableRuleAction else { return }
        try await context.executor.execute(action.withValue("\(id)"))
    }

    /// A stream that fires whenever the state or the rules change.
    public func updates() -> AsyncStream<Void> {
        filteredUpdates(keys: Set(EntityDescriptor.eventSchedule(descriptor).stateRefs), store: context.store)
    }
}

/// A TV remote: named buttons, each sending an action to the CLU. No state.
public final class TvRemoteEntity: Sendable {
    /// What the remote is: its buttons and their actions.
    public let descriptor: TvRemoteDescriptor
    private let context: DeviceContext

    init(descriptor: TvRemoteDescriptor, context: DeviceContext) {
        self.descriptor = descriptor
        self.context = context
    }

    /// The buttons this remote has; empty until buttons are assigned in Object Manager.
    public var buttons: Set<TvRemoteButton> { Set(descriptor.buttons.keys) }

    /// The label of the VOD button.
    public var vodLabel: String { descriptor.vodLabel }

    /// Presses a button. Does nothing for a button the remote does not have.
    public func press(_ button: TvRemoteButton) async throws {
        guard let action = descriptor.buttons[button] else { return }
        try await context.executor.execute(action)
    }
}

/// An entity with state the CLU reports: it can tell you when that state changed.
///
/// Every entity with `updates()` conforms; buttons, scenes, cameras and remotes have no state.
public protocol StatefulEntity: GrentonEntity {
    /// A stream that fires whenever the state changes; read the entity for the new values.
    func updates() -> AsyncStream<Void>
}

extension ToggleEntity: StatefulEntity {}
extension DimmableLightEntity: StatefulEntity {}
extension HsbLightEntity: StatefulEntity {}
extension ContactSensorEntity: StatefulEntity {}
extension SensorEntity: StatefulEntity {}
extension NumberSettingEntity: StatefulEntity {}
extension CoverEntity: StatefulEntity {}
extension StateSensorEntity: StatefulEntity {}
extension ThermostatEntity: StatefulEntity {}
extension EventScheduleEntity: StatefulEntity {}

extension ToggleEntity: SwitchableEntity {}
extension DimmableLightEntity: SwitchableEntity {}
extension HsbLightEntity: SwitchableEntity {}

extension BoundEntity: Identifiable {}
