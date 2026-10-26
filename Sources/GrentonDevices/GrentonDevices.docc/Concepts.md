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

The protocol has no device class: a relay behind a lamp and one behind a
pump are the same switch, and nothing on the wire tells them apart. The
one hint is the **icon** the installer chose in Object Manager, which the
interface carries for every widget and component: `bulb`, `plafond`,
`ceiling_lamp_2`, `power_socket`, `floor_heating`, `vacuum_robot_4`… The
library passes the names on — `BoundEntity/icon`, `DeviceDescriptor/icon`,
`DevicePage/icon` — and does not interpret them; what counts as a light
is your call. See <doc:ControllingDevices>.

Every device knows where the myGrenton app shows it: its `page` (index
and name, often a room) and its `section` — the header above it on that
page, or `nil` above the first header. Devices come in page order, so a
list grouped by `page` and then `section` reproduces the app's layout:

```swift
let grouped = Dictionary(grouping: system.devices) { $0.descriptor.page.index }
for (index, devices) in grouped.sorted(by: { $0.key < $1.key }) {
    print(devices[0].descriptor.page.name)
    for device in devices {
        print("  \(device.descriptor.section?.title ?? "—"): \(device.descriptor.name)")
    }
    _ = index
}
```

### Normalized state

Entities hide how a device encodes its state: a switch is on or off, a
dimmer's brightness runs from 0 to 1, a shutter's position from 0 (closed)
to 100 (open), whatever the device reports internally. Values are `nil`
until the CLU has reported them. A ``SensorEntity`` gives its reading as
a `number` with a `unit` to show, and keeps the reported `value` for the
sensors that report text.

| Entity | Property | Type and range |
|---|---|---|
| ``ToggleEntity`` | `isOn` | `Bool` |
| ``DimmableLightEntity`` | `brightness` | `Double`, 0…1 |
| ``HsbLightEntity`` | `hue`, `saturation`, `brightness` | `Double`: 0…360°, 0…1, 0…1 |
| ``CoverEntity`` | `position`, `tilt` | `Int`, 0 closed … 100 open |
| ``ThermostatEntity`` | `currentTemperature`, `targetTemperature` | `Double`, °C |
| ``NumberSettingEntity`` | `value` | `Double` in the widget's range |
| ``ContactSensorEntity``, ``StateSensorEntity`` | `isOn` / `state` | `Bool` / `GrentonValue` |
| ``SensorEntity`` | `number`, `unit`, `value` | `Double?` with `String?`, and the raw `GrentonValue` |

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
