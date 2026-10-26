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

### Lights only

Switches, dimmers and RGB lights share ``SwitchableEntity``; the icon
tells which of the switches are lights. The names come from Object
Manager's icon set — the ones for lamps contain `lamp`, `bulb` or
`plafond` — so a filter is yours to define and easy to adjust:

```swift
func isLight(_ entity: BoundEntity) -> Bool {
    guard entity.switchable != nil, let icon = entity.icon else { return false }
    return ["lamp", "bulb", "plafond", "light"].contains { icon.contains($0) }
}
let lights = system.entities.filter(isLight)
```

A dimmer or an RGB light is a light whatever its icon says; the check
above keeps them only when the installer chose a lamp icon, so widen it
to `entity.switchable != nil && !(entity is a toggle)` if you prefer.

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

### Schedules

An event scheduler holds up to 16 rules, each a time of day on chosen
weekdays. The CLU reports them as a list; add and delete them by number:

```swift
if case .eventSchedule(let schedule) = entity {
    for rule in schedule.rules ?? [] {
        print(rule.id, rule.isEnabled, rule.hour ?? 0, rule.minute ?? 0, rule.days ?? [])
    }
    try await schedule.addRule(hour: 22, minute: 30, days: [.saturday, .sunday])
    if let stale = schedule.rules?.first(where: { !$0.isEnabled }) {
        try await schedule.deleteRule(stale.id)
    }
}
```

A new rule gets its number from the CLU and shows up in
``EventScheduleEntity/rules`` with the next report. ``ScheduleRule/days``
is `nil` for a rule written in Object Manager with CRON features the app
does not use (a day of month, a step); ``ScheduleRule/cron`` always has
the text.

### TV remotes

```swift
if case .tvRemote(let remote) = entity, remote.buttons.contains(.volumeUp) {
    try await remote.press(.volumeUp)
}
```

A remote may have no buttons at all until they are assigned in Object
Manager; ``TvRemoteEntity/press(_:)`` does nothing for a button the remote
does not have.
