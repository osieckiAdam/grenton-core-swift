# Controlling Devices

Switch lights, set a thermostat, move a shutter, run a scene.

## Overview

Commands are `async` and throw when the CLU does not answer. The CLU then
pushes the new state back, so an entity reflects the change a moment
after the command returns.

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

The target is clamped to the thermostat's own minimum and maximum.

### Shutters

```swift
if case .cover(let shutter) = entity {
    try await shutter.setPosition(50)   // 0 closed … 100 open
}
```

### Scenes and buttons

```swift
if case .sceneTrigger(let scene) = entity {
    try await scene.run()
}
```
