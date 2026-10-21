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
        ]
    ),
]
```

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

Without a PIN, read the interface from the project file saved in Object
Manager (`.omp`) instead; it holds the same interface and the same key:

```swift
let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: "house.omp")))
let imported = try project.interface()
```

### Start the system

Later runs load the saved archive; no PIN and no Object Manager needed:

```swift
import GrentonDevices

let interface = try ProvisioningClient.parseInterfaceArchive(
    Data(contentsOf: URL(fileURLWithPath: "interface.zip")))
let system = try GrentonSystem(interface: interface)
await system.start()
```

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

The repository's `Examples` directory has complete programs for each
step: `fetch-interface`, `list-devices`, `watch-state`, `switch-light` and
`set-thermostat`.
