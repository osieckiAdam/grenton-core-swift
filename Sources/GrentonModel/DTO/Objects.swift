// Object DTOs — the `object` field of non-list widgets (spec §3.5).

public struct ValueObjectDTO: Decodable, Sendable {
    public let value: ValueRefDTO
}

public struct DimmerV2ObjectDTO: Decodable, Sendable {
    public let value: ValueRefDTO
    public let setValueAction: ActionRefDTO
    public let onAction: ActionRefDTO
    public let offAction: ActionRefDTO
}

public struct SliderObjectDTO: Decodable, Sendable {
    public let value: ValueRefDTO
    public let setValueAction: ActionRefDTO
    public let clickAction: ActionRefDTO?
}

public struct MultisensorObjectDTO: Decodable, Sendable {
    public let value: ValueRefDTO
    public let minValue: ValueRefDTO?
    public let maxValue: ValueRefDTO?
    public let threshold: ValueRefDTO?
    public let sensitivity: ValueRefDTO?
}

public struct ContactSensorObjectDTO: Decodable, Sendable {
    public let value: ValueRefDTO
    public let clickAction: ActionRefDTO?
}

/// ROLLER_SHUTTER_V3 object — the full field set of the reference DTO.
/// Only a subset drives the canonical Cover (spec §6.3.8); the rest is
/// retained for forward use.
public struct RollerShutterV3ObjectDTO: Decodable, Sendable {
    public let state: ValueRefDTO
    public let up: ValueRefDTO?
    public let down: ValueRefDTO?
    public let loadCurrent: ValueRefDTO?
    public let overcurrent: ValueRefDTO?
    public let voltageType: ValueRefDTO?
    public let position: ValueRefDTO
    public let lamelPosition: ValueRefDTO
    /// Presence of this field is the reference heuristic for "has lamels"
    /// (tilt support) — spec §6.3.8.
    public let lamelMoveTimeout: ValueRefDTO?
    public let distributedLogicGroup: ValueRefDTO?
    public let reversePosition: ValueRefDTO?
    public let blindsUpMaxTime: ValueRefDTO?
    public let blindsDownMaxTime: ValueRefDTO?
    public let mechanicalOffset: ValueRefDTO?

    public let setPositionAction: ActionRefDTO
    public let setLamelPositionAction: ActionRefDTO
    public let calibrationAction: ActionRefDTO?
    public let setBlindsMaxTimeAction: ActionRefDTO?
    public let setLamelMoveTimeoutAction: ActionRefDTO?
    public let moveUpAction: ActionRefDTO
    public let moveDownAction: ActionRefDTO
    public let startAction: ActionRefDTO
    public let stopAction: ActionRefDTO?
    public let holdAction: ActionRefDTO?
    public let holdUpAction: ActionRefDTO?
    public let holdDownAction: ActionRefDTO?
    public let setRollerBlockedAction: ActionRefDTO
    public let lamelStartAction: ActionRefDTO?
    public let setMechanicalOffsetAction: ActionRefDTO?
    public let setBlindsUpMaxTimeAction: ActionRefDTO?
    public let setBlindsDownMaxTimeAction: ActionRefDTO?
}

/// THERMOSTAT_V2 object (spec §6.3.12) — a Grenton Thermostat virtual
/// object. Only the temperatures and the target setter are required; the
/// mode/state controls and the rest are optional so an interface that
/// omits them still maps. Set actions carry the `$value$` placeholder
/// (spec §3.3).
public struct ThermostatV2ObjectDTO: Decodable, Sendable {
    public let currentTemperature: ValueRefDTO
    public let targetTemperature: ValueRefDTO
    public let setTargetTemperatureAction: ActionRefDTO
    public let minTemperature: ValueRefDTO?
    public let maxTemperature: ValueRefDTO?
    public let setMinTemperatureAction: ActionRefDTO?
    public let setMaxTemperatureAction: ActionRefDTO?
    public let mode: ValueRefDTO?
    public let setModeAction: ActionRefDTO?
    public let state: ValueRefDTO?
    public let setStateAction: ActionRefDTO?
    public let controlOutValue: ValueRefDTO?
    public let scheduleData: ValueRefDTO?
    public let setScheduleDataAction: ActionRefDTO?
}
