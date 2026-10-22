# Controlling Devices

Switch lights, set a thermostat, move a shutter, run a scene.

## Overview

Commands are `async` and throw when the CLU does not answer
(`SessionError.timeout`) or the system is not started
(`SessionError.notConnected`); <doc:ConnectionLifecycle> lists every
error. The CLU then pushes the new state back, so an entity reflects the
change a moment after the command returns.

### Lights and switches

Switches, dimmers and RGB lights share one on/off surface,
``SwitchableEntity``:

```swift
if let light = entity.switchable {
    try await light.setOn(true)
}
```

Dimmers and RGB lights also take a brightness from 0 to 1:

```swift
if case .dimmableLight(let dimmer) = entity {
    try await dimmer.setBrightness(0.4)
}
```

### Thermostats

```swift
if case .thermostat(let thermostat) = entity {
    try await thermostat.setTargetTemperature(21.5)
    try await thermostat.setMode(.schedule)
}
```

The target is clamped to the thermostat's own minimum and maximum. Not
every thermostat exposes a mode or a power switch; `setMode` and
`setActive` do nothing when ``ThermostatEntity/supportsMode`` or
``ThermostatEntity/supportsPower`` is `false`. A thermostat is not a
light: ``ThermostatEntity/isActive`` says whether it controls the heating,
and ``BoundEntity/switchable`` leaves thermostats out on purpose.

### Shutters

```swift
if case .cover(let shutter) = entity {
    try await shutter.setPosition(50)   // 0 closed … 100 open
    if shutter.supportsStop { try await shutter.stop() }
}
```

`stop()` and `setTilt(_:)` do nothing on a shutter whose interface has no
stop action or tilt; check ``CoverEntity/supportsStop`` and
``CoverEntity/supportsTilt`` first.

### Scenes and buttons

```swift
if case .sceneTrigger(let scene) = entity {
    try await scene.run()
}
```
