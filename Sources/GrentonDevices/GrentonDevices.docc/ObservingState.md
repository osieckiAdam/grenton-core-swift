# Observing State

Read the current state and react when it changes.

## Overview

Every entity reads its state from values the CLUs push to the library. The
state is always current: read it whenever you need it.

```swift
for case .thermostat(let thermostat) in system.entities {
    print(thermostat.name, thermostat.currentTemperature ?? .nan)
}
```

### React to changes

``BoundEntity/updates()`` returns a stream that fires whenever an entity's
state changes. Read the new state from the entity itself:

```swift
for entity in system.entities {
    guard let updates = entity.updates() else { continue }
    Task {
        for await _ in updates {
            print("\(entity.name) changed")
        }
    }
}
```

Buttons, scenes and cameras have no state, so their `updates()` is `nil`.

### When values are unknown

A value is `nil` until its CLU reports it. If every value stays `nil`,
check ``GrentonSystem/sessionStates()``: a CLU that never answered is
`SessionState.degraded`. On a Mac, the app running your
code needs access to the local network (System Settings, Privacy &
Security, Local Network).
