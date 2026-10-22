# Concepts

How an installation is described, and how the library models it.

## Overview

### The mobile interface

In Object Manager you design a *mobile interface*: pages with widgets for
the myGrenton app. The library reads the same interface, so it sees
exactly what you put on those pages. Each widget becomes one device.
Widgets of a type the library does not know are skipped and listed in
`MobileInterfaceDTO.skippedWidgets`.

### CLUs

A CLU is a Grenton controller. The interface lists every CLU with its
address and the key used to encrypt their traffic. ``GrentonSystem``
keeps one session per CLU and reports its health through
``GrentonSystem/sessionStates()``.

### Devices and entities

A device is one widget: a switch, a dimmer, a thermostat, a double relay.
A device holds one or more entities, the things you actually read and
control. A double relay is one device with two switch entities; a door
sensor with a button is one device with a sensor and a trigger.

Entity ids are stable: the widget id plus a suffix, such as `k3Xq9TzA_0`.
Use them to store your own settings per entity.

### Normalized state

Entities hide how a device encodes its state: a switch is on or off, a
dimmer's brightness runs from 0 to 1, a shutter's position from 0 (closed)
to 100 (open), whatever the device reports internally. Values are `nil`
until the CLU has reported them. The one exception is ``SensorEntity``,
whose `value` is the reported `GrentonValue` itself, with the unit and
precision of its descriptor to present it.

| Entity | Property | Type and range |
|---|---|---|
| ``ToggleEntity`` | `isOn` | `Bool` |
| ``DimmableLightEntity`` | `brightness` | `Double`, 0…1 |
| ``HsbLightEntity`` | `hue`, `saturation`, `brightness` | `Double`: 0…360°, 0…1, 0…1 |
| ``CoverEntity`` | `position`, `tilt` | `Int`, 0 closed … 100 open |
| ``ThermostatEntity`` | `currentTemperature`, `targetTemperature` | `Double`, °C |
| ``NumberSettingEntity`` | `value` | `Double` in the widget's range |
| ``ContactSensorEntity``, ``StateSensorEntity`` | `isOn` / `state` | `Bool` / `GrentonValue` |
| ``SensorEntity`` | `value` | `GrentonValue`, see `SensorDescriptor` |

### Physical objects

The same thermostat or shutter often appears on several pages under
different names, such as "Temperature" on the room page and "Living room"
on the heating page. Each widget is still its own device, so its ids stay
stable, but ``GrentonSystem/physicalObjects`` groups them by what they
operate on the CLU:

```swift
for object in system.physicalObjects where object.widgets.count > 1 {
    let names = object.widgets.map { "\($0.name) (\($0.page.name))" }
    print(object.key.name, names.joined(separator: ", "))
}
```

Show one entry per ``PhysicalObject`` when you want each piece of hardware
once, for example in a Home app.
