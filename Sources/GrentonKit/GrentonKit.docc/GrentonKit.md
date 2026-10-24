# ``GrentonKit``

Everything an app needs, in one import.

## Overview

`import GrentonKit` brings in `GrentonModel`, `GrentonRuntime`,
`GrentonProvisioning` and `GrentonDevices`, plus the conveniences that
join them: creating a `GrentonSystem` straight from an interface archive.

```swift
import GrentonKit

let archive = try Data(contentsOf: URL(fileURLWithPath: "interface.zip"))
let system = try GrentonSystem(interfaceArchive: archive)
await system.start()
```

The four modules stay available on their own for an app that wants only
some of them — the devices without the Object Manager client, say — and
none of them depends on this one. The reference for the types lives with
their modules; start with `GrentonDevices`.

This module adds one thing of its own:
`GrentonSystem.init(interfaceArchive:socketFactory:logger:pingInterval:registerInterval:responseTimeout:)`,
which reads the archive `ProvisioningClient` downloaded (or one saved
earlier) and creates the system from it — the `GrentonDevices` initializer
takes a parsed interface instead. For the devices without a connection, see
`GrentonSimulation`.

## Topics

### Starting from an archive

- ``GrentonSystem/init(interfaceArchive:socketFactory:logger:pingInterval:registerInterval:responseTimeout:)``
