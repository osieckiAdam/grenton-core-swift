# ``GrentonSimulation``

The devices of an interface without any CLU, for your app's tests.

## Overview

`SimulatedGrentonSystem` builds the same devices and entities as a live
`GrentonSystem` — the same normalization, limits and command formatting —
over values you set, and records every command the entities execute. No
network, no key, no `start()`.

Import it in a test target only; it is not part of `GrentonKit`.

```swift
import GrentonSimulation
```

## Topics

### Simulating a system

- ``SimulatedGrentonSystem``
