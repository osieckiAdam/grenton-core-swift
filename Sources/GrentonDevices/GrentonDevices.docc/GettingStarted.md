# Getting Started

Download the interface from Object Manager, connect to the CLUs and switch
a light.

## Overview

You need a Mac or iPhone on the same network as the CLU controllers, and a
computer running Grenton Object Manager for the first step.

### Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/osieckiAdam/grenton-core-swift.git", from: "0.9.1"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "GrentonProvisioning", package: "grenton-core-swift"),
            .product(name: "GrentonDevices", package: "grenton-core-swift"),
            .product(name: "GrentonRuntime", package: "grenton-core-swift"),
        ]
    ),
]
```

`GrentonRuntime` holds the types the other two hand you — `SessionState`,
`SessionError`, `GrentonLogger` — so import it wherever you check a
state or catch an error. An iOS app also needs two `Info.plist` keys
before any of this works: see <doc:RunningOnApplePlatforms>.

### Download the interface

In Object Manager, select the mobile interface and click **Send to mobile
devices**. The dialog shows the computer's IP address, the port and a
token, the PIN. Keep it open while you download:

```swift
import GrentonProvisioning

let client = ProvisioningClient(host: "192.168.1.50")
let archive = try await client.fetchInterfaceArchive(pin: "149 853")
try archive.write(to: URL(fileURLWithPath: "interface.zip"))
```

The PIN may contain the space Object Manager shows. The archive holds the
encryption key of your CLUs: store it privately, like a password.

The alternative to the download is the project file you save in Object
Manager (`.omp`): it holds the same interface and the same key, and
`ProjectFile` reads it without a PIN and without Object Manager running.
Pass the imported interface to ``GrentonSystem/init(interface:socketFactory:logger:pingInterval:registerInterval:responseTimeout:)``:

```swift
let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: "house.omp")))
let fromProject = try GrentonSystem(interface: project.interface())
```

### Start the system

Later runs load the saved archive; no PIN and no Object Manager needed:

```swift
import GrentonDevices

let system = try GrentonSystem(
    interfaceArchive: Data(contentsOf: URL(fileURLWithPath: "interface.zip")))
await system.start()
```

``GrentonSystem/init(interface:socketFactory:logger:pingInterval:registerInterval:responseTimeout:)``
takes an already parsed interface instead, for example one imported from a
project file.

``GrentonSystem/start()`` returns once every CLU has answered its first
subscription, so all current values are already known.

### Switch a light

Every entity has an id and a name. Find one and turn it on:

```swift
if let light = system.entities.first(where: { $0.name == "Ceiling" })?.switchable {
    try await light.turnOn()
}
```

When you are done, stop the system to close its connections:

```swift
await system.stop()
```

<doc:ConnectionLifecycle> covers what happens between `start()` and
`stop()`, and the errors a command can throw.

The repository's `Examples` directory has a complete program for each
step; each is one `main.swift` meant to be read:

- [fetch-interface](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/fetch-interface/main.swift) — download the interface with the PIN and save it
- [import-project](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/import-project/main.swift) — read the interface from a project file instead
- [list-devices](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/list-devices/main.swift) — devices and entities, offline
- [watch-state](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/watch-state/main.swift) — every value, then changes as they happen
- [read-values](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/read-values/main.swift) — read any CLU value once, without subscribing
- [switch-light](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/switch-light/main.swift) — turn a light on or off and wait for the CLU to confirm
- [set-thermostat](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/set-thermostat/main.swift) — set a target temperature and confirm it
- [run-scene](https://github.com/osieckiAdam/grenton-core-swift/blob/main/Examples/run-scene/main.swift) — run a scene by its name
