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

The stream tells you *that* something changed, not what: read the
entity. Subscribe first, then read the state once, then wait — a change
between the read and the subscription would otherwise go unseen. The
stream only fires for changes after the subscription, never for what was
known before it. Several changes while you are busy may arrive as one
signal, but a signal is never lost: after every change of the entity's
values at least one follows, however many other values change meanwhile,
and the entity already holds the new value when it arrives.

`GrentonSystem.changes()` is different: a stream of every value change of
every CLU, for logging. It keeps the newest 64 when a consumer falls
behind and promises no complete history; the entities' `updates()` are
the way to show state.

### In SwiftUI

The `GrentonSwiftUI` module (iOS 17 / macOS 14) wraps an entity so a view
re-renders on every reported change, without a `.task` of your own:

```swift
import SwiftUI
import GrentonKit
import GrentonSwiftUI

struct LightRow: View {
    let light: Observed<ToggleEntity>
    var body: some View {
        Toggle(light.value.name, isOn: Binding(
            get: { light.value.isOn == true },
            set: { on in Task { try? await light.value.setOn(on) } }))
    }
}
```

Create the `Observed` where the entity lives (a view model or `@State`),
not in `body`. Entities without state — buttons, scenes, cameras,
remotes — need no observation.

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
check ``GrentonSystem/diagnostics()``: a CLU that never answered is
`SessionState.degraded` with no reply time (see <doc:ConnectionLifecycle>). On a Mac, the app running your
code needs access to the local network (System Settings, Privacy &
Security, Local Network).
