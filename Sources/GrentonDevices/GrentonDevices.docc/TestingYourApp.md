# Testing Your App

Run your views and view models against real entities without a CLU.

## Overview

The `GrentonSimulation` module builds the same devices and entities as a
live ``GrentonSystem`` — the same normalization, limits and command
formatting — over values you set, and records every command. No network,
no key, no `start()`. Add it to your test target only; it is not part of
`GrentonKit`:

```swift
.testTarget(
    name: "MyAppTests",
    dependencies: [
        "MyApp",
        .product(name: "GrentonSimulation", package: "grenton-core-swift"),
    ]
),
```

### Build the simulation from your interface

Keep a small interface in your test fixtures — one exported from Object
Manager, or `data.json` written by hand with the widgets your test needs —
and build the simulation from it:

```swift
import GrentonKit
import GrentonSimulation

let simulation = SimulatedGrentonSystem(interface: interface)
let thermostats = simulation.entities.compactMap { entity -> ThermostatEntity? in
    if case .thermostat(let thermostat) = entity { return thermostat } else { return nil }
}
```

Your code takes entities (`ToggleEntity`, `ThermostatEntity`, …) or a
`BoundDevice`; it never needs to know whether a `GrentonSystem` or a
simulation made them.

### Set values and read them back

Every value is unknown until you set it, as before a CLU's first report.
Set it as the CLU would report it — the raw value — and the entity shows
it normalized:

```swift
let thermostat = thermostats[0]
simulation.set(thermostat.descriptor.currentTemperature, to: .double(21.5))
// thermostat.currentTemperature == 21.5
simulation.set(thermostat.descriptor.currentTemperature, to: .null)
// thermostat.currentTemperature == nil: the CLU reported nothing
simulation.clear(thermostat.descriptor.currentTemperature)
// thermostat.currentTemperature == nil: not reported yet
```

A set value signals the entity's `updates()` exactly as a report does.

### Assert the commands

Commands are recorded before they return, in order, and change no value
— on a real CLU the new value arrives as a report, later:

```swift
try await thermostat.setTargetTemperature(22)
let action = simulation.executedActions.last
// action?.value == "22.0"
simulation.set(thermostat.descriptor.targetTemperature, to: .double(22))
```

To test the failure path, make the commands throw:

```swift
simulation.failCommands(with: SessionError.notConnected)
// try await thermostat.setTargetTemperature(22) now throws
simulation.failCommands(with: nil)
```

`SimulatedGrentonSystem` is not a `GrentonSystem`: there is no
`start()`, no `stop()` and no `diagnostics()`. Give your code the
entities, not the system, and it needs none of them.
