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
and build the simulation from it. This is the smallest `data.json` that
decodes: the installation's key (any 16 bytes, base64), one CLU, one page
with a section header and a switch:

```json
{"id": "test", "version": 1, "name": "Test", "icon": "home", "theme": "GRENTON",
 "encryption": {"key": "AAECAwQFBgcICQoLDA0ODw==", "iv": "EBESExQVFhcYGRobHB0eHw=="},
 "clus": [{"id": "CLU_1", "serialNumber": "1", "name": "CLU", "ip": "10.0.0.1", "port": 1234, "connectionType": "LOCAL_ONLY"}],
 "pushNotifications": [],
 "pages": [{"name": "Salon", "icon": "star", "isFullscreenWidget": false, "widgets": [
   {"id": "h1", "type": "HEADER", "components": [{"label": "Oświetlenie", "rowId": 0, "unit": "UNKNOWN", "type": "HEADER"}]},
   {"id": "w1", "type": "ON_OFF", "components": [{"label": "Lampa", "rowId": 0, "unit": "UNKNOWN", "type": "BUTTON_BISTABLE",
     "onIndication": "On", "offIndication": "Off",
     "state": {"cluId": "CLU_1", "objectName": "DOU1001", "index": "0", "callType": "ATTRIBUTE"},
     "actions": [
       {"event": "ON", "cluId": "CLU_1", "objectName": "DOU1001", "index": "0", "value": "1", "callType": "ATTRIBUTE"},
       {"event": "OFF", "cluId": "CLU_1", "objectName": "DOU1001", "index": "0", "value": "0", "callType": "ATTRIBUTE"}]}]
 }]}
```

A `HEADER` is its `id` and the first component's `label`; the switch
after it gets `section.title == "Oświetlenie"`.

A hand-written widget with a wrong field is **skipped silently**, as the
library promises for interfaces from Object Manager (the page survives,
the widget lands in `skippedWidgets`): an `ON_OFF_DOUBLE` whose components
say `BUTTON_BISTABLE` instead of `BUTTON_BISTABLE_V2` simply yields no
lights. Guard every fixture with one assertion:

```swift
precondition(interface.skippedWidgets.isEmpty, "the fixture is wrong, not the app")
```

The component type each widget expects is listed in the specification
(`grenton-core-design.md`, §3.5): `ON_OFF` → `BUTTON_BISTABLE`,
`ON_OFF_DOUBLE` → `BUTTON_BISTABLE_V2`, `SCENE` → `BUTTON_MONOSTABLE`,
`CAMERA` → `CAMERA_STREAM`, `LED` → `BUTTON_BISTABLE` plus the three
`SLIDER_*`, the legacy `ROLLER_SHUTTER` → `BUTTON_BISTABLE`.

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

### Previews and demo mode

The simulation is also the way to show your views without a CLU — in
SwiftUI previews, or a demo mode of the app. Create it with
`echoesSwitches: true` and the lights follow their commands as a CLU
would report them; every other command still changes nothing:

```swift
let demo = SimulatedGrentonSystem(interface: interface, echoesSwitches: true)
if let light = demo.entities.compactMap(\.switchable).first {
    try await light.turnOn()
    // light.isOn == true
}
```

Link `GrentonSimulation` into the app for that; it is small and has no
dependency beyond the library.

### In an Xcode project

Xcode's default test target is hosted by the app. When the app links
`GrentonKit` and the test target links `GrentonSimulation`, Xcode builds
the second product as a dynamic framework with its own copy of
`GrentonDevices`, and the test log says every entity class "is
implemented in both" — casts and observation across the two copies are
not reliable. Link `GrentonSimulation` in **one** place: in the app
(it is what a demo mode needs anyway) and let the test target use the
host's copy; or make the test target unhosted. A `swift test` package has
no host app and no such issue.
