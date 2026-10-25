# ``GrentonSwiftUI``

Show an entity in SwiftUI and let the view follow the CLU.

## Overview

A Grenton entity is a handle: its state lives in the system and changes
when the CLU reports. ``Observed`` wraps such an entity so that a view
reading it re-renders after every reported change — no `.task`, no
manual refresh.

```swift
import SwiftUI
import GrentonKit
import GrentonSwiftUI

@MainActor
final class RoomModel {
    let thermostat: Observed<ThermostatEntity>
    init(thermostat: ThermostatEntity) { self.thermostat = Observed(thermostat) }
}
```

```swift
struct RoomView: View {
    let model: RoomModel
    var body: some View {
        let thermostat = model.thermostat.value
        VStack {
            Text(thermostat.name)
            Text(thermostat.currentTemperature.map { "\($0) °C" } ?? "—")
            Button("Warmer") {
                Task { try? await thermostat.setTargetTemperature((thermostat.targetTemperature ?? 20) + 0.5) }
            }
        }
    }
}
```

Requires iOS 17 / macOS 14 (the Observation framework); the rest of the
library runs on iOS 16 / macOS 13, which is why this is a separate
module. Entities without state — buttons, scenes, cameras, remotes —
need no observation: call their intents directly.

## Topics

### Observing an entity

- ``Observed``
