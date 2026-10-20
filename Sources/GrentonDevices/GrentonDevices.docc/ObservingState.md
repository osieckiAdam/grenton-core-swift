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

### Read values once

A subscription keeps values fresh for as long as the system runs. For a
value nobody watches, or to read back right after an action, ask the CLU
once; the answer also updates the store:

```swift
let refs = system.devices.flatMap { $0.descriptor.entities.flatMap(\.stateRefs) }
let slots = await system.fetch(refs)
for (ref, slot) in zip(refs, slots) {
    if case .value(let value) = slot { print(ref, value) }
}
```

A slot is `failed` when the CLU did not answer in time.

### When values are unknown

A value is `nil` until its CLU reports it. If every value stays `nil`,
check ``GrentonSystem/sessionStates()``: a CLU that never answered is
`SessionState.degraded`. On a Mac, the app running your
code needs access to the local network (System Settings, Privacy &
Security, Local Network).
