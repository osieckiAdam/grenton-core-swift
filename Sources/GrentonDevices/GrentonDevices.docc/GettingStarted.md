# Getting Started

Download the interface from Object Manager, connect to the CLUs and switch
a light.

## Overview

You need a Mac or iPhone on the same network as the CLU controllers, a
computer running Grenton Object Manager for the first step, and Xcode
26.2 or later (Swift 6.2.3) to build.

### Add the package

In `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/osieckiAdam/grenton-core-swift.git", from: "0.13.1"),
],
targets: [
    .executableTarget(
        name: "MyApp",
        dependencies: [
            .product(name: "GrentonKit", package: "grenton-core-swift"),
        ]
    ),
]
```

`import GrentonKit` brings in every module: the devices (`GrentonDevices`),
the Object Manager client and project-file import (`GrentonProvisioning`),
the connection types you check or catch — `SessionState`, `SessionError`,
`GrentonLogger` (`GrentonRuntime`) — and the interface model
(`GrentonModel`). Each is also a product of its own for an app that wants
only some of them. An iOS app also needs two `Info.plist` keys before any
of this works: see <doc:RunningOnApplePlatforms>.

### Download the interface

In Object Manager, select the mobile interface and click **Send to mobile
devices**. The dialog shows the computer's IP address, the port and a
token, the PIN. Keep it open while you download:

```swift
import Foundation
import GrentonKit

let store = try InterfaceStore()
let client = ProvisioningClient(host: "192.168.1.50")
let archive = try await client.fetchInterfaceArchive(pin: "149 853")
try store.save(archive)
```

The PIN may contain the space Object Manager shows. The archive holds the
encryption key of your CLUs: `InterfaceStore` keeps it in the app's own
folder under Application Support, with complete file protection on iOS —
never write it to a plain file or `UserDefaults`. (A command-line tool has
no bundle identifier and gives the store a URL instead.)

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
import Foundation
import GrentonKit

let system = try InterfaceStore().system()
await system.start()
```

`GrentonSystem(interfaceArchive:)` does the same from archive bytes you
keep elsewhere. When your app also needs the interface itself — the
pages' icons, the list of CLUs, the raw widgets — take it from the store
and create the system from it:

```swift
import GrentonKit

let saved = try InterfaceStore()
if let interface = try saved.interface() {
    let system = try GrentonSystem(interface: interface)
    print(interface.name, interface.pages.map(\.name))
    _ = system
}
```

A project file works the same way: `store.save(project:interfaceId:)`
keeps it, and `interface()` and `system()` read it.

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
`stop()`, and the errors a command can throw. <doc:TestingYourApp> shows
how to test your code against these entities without a CLU. In a SwiftUI
app, the `GrentonSwiftUI` module's `Observed` makes a view follow an
entity (see <doc:ObservingState>).

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
