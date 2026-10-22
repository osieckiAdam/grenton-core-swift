# ``GrentonDevices``

Control a Grenton smart-home installation from Swift: lights, switches,
shutters, thermostats, scenes and sensors.

## Overview

GrentonDevices turns the mobile interface you design in Grenton Object
Manager into devices you can read and control. Start a ``GrentonSystem``
from the interface, and it connects to the CLU controllers, keeps every
value up to date, and gives you typed entities: a light that turns on and
off, a thermostat with a target temperature, a shutter with a position.

```swift
let system = try GrentonSystem(interface: interface)
await system.start()

for entity in system.entities {
    if let light = entity.switchable {
        print(light.name, light.isOn == true ? "on" : "off")
    }
}
```

The library speaks the same local protocol as the myGrenton app. It needs
the Mac or iPhone to be on the installation's network; there is no cloud
connection.

Get the interface once from Object Manager with
`ProvisioningClient` and save it, so later starts need
no PIN.

## Topics

### Essentials

- <doc:GettingStarted>
- <doc:Concepts>
- <doc:RunningOnApplePlatforms>
- <doc:ConnectionLifecycle>
- ``GrentonSystem``

### Working with Devices

- <doc:ObservingState>
- <doc:ControllingDevices>
- ``BoundDevice``
- ``BoundEntity``
- ``SwitchableEntity``

### Entities

- ``ToggleEntity``
- ``DimmableLightEntity``
- ``HsbLightEntity``
- ``ThermostatEntity``
- ``CoverEntity``
- ``ContactSensorEntity``
- ``SensorEntity``
- ``NumberSettingEntity``
- ``StateSensorEntity``
- ``TriggerEntity``
- ``SceneTriggerEntity``
- ``CameraEntity``

### Physical Objects

- ``PhysicalObject``
- ``ObjectKey``

### Devices Without a Connection

- ``DeviceMapper``
- ``DeviceDescriptor``
- ``DeviceKind``
- ``DevicePage``
- ``EntityDescriptor``
