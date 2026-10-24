// swift-tools-version: 6.2.3
import Foundation
import PackageDescription

// The DocC plugin is needed only to build the documentation site
// (scripts/docs.sh sets GRENTON_DOCS=1); apps depending on this package never
// resolve or fetch it.
let buildingDocumentation = ProcessInfo.processInfo.environment["GRENTON_DOCS"] == "1"

let package = Package(
    name: "GrentonCoreSwift",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "GrentonModel", targets: ["GrentonModel"]),
        .library(name: "GrentonRuntime", targets: ["GrentonRuntime"]),
        .library(name: "GrentonProvisioning", targets: ["GrentonProvisioning"]),
        .library(name: "GrentonDevices", targets: ["GrentonDevices"]),
        .library(name: "GrentonKit", targets: ["GrentonKit"]),
        .library(name: "GrentonSimulation", targets: ["GrentonSimulation"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
    ] + (buildingDocumentation
        ? [.package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0")]
        : []),
    targets: [
        .target(name: "GrentonModel"),
        .target(name: "GrentonRuntime", dependencies: ["GrentonModel"]),
        .target(name: "GrentonDevices", dependencies: ["GrentonModel", "GrentonRuntime"]),
        // The umbrella (spec §2): one import for apps, plus the conveniences
        // that join Provisioning and Devices. No rule lives here.
        .target(name: "GrentonKit", dependencies: ["GrentonModel", "GrentonRuntime", "GrentonProvisioning", "GrentonDevices"]),
        // The same devices over an in-memory store, for app tests. Not part
        // of GrentonKit: a test target imports it on its own.
        .target(name: "GrentonSimulation", dependencies: ["GrentonModel", "GrentonRuntime", "GrentonDevices"]),
        .target(name: "GrentonTestSupport", dependencies: ["GrentonModel", "GrentonRuntime"]),
        .executableTarget(
            name: "grenton-cli",
            dependencies: ["GrentonKit"],
            path: "Examples/grenton-cli",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "fetch-interface",
            dependencies: ["GrentonKit"],
            path: "Examples/fetch-interface",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "list-devices",
            dependencies: ["GrentonKit"],
            path: "Examples/list-devices",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "watch-state",
            dependencies: ["GrentonKit"],
            path: "Examples/watch-state",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "switch-light",
            dependencies: ["GrentonKit"],
            path: "Examples/switch-light",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "set-thermostat",
            dependencies: ["GrentonKit"],
            path: "Examples/set-thermostat",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "run-scene",
            dependencies: ["GrentonKit"],
            path: "Examples/run-scene",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "read-values",
            dependencies: ["GrentonKit"],
            path: "Examples/read-values",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "import-project",
            dependencies: ["GrentonKit"],
            path: "Examples/import-project",
            // Built as an app would build: only the public API.
            packageAccess: false
        ),
        .executableTarget(
            name: "probe-register",
            dependencies: ["GrentonModel", "GrentonProvisioning", "GrentonRuntime", "GrentonDevices"],
            path: "Examples/probe-register"
            // A research tool: keeps package access to the wire primitives.
        ),
        .target(
            name: "GrentonProvisioning",
            dependencies: [
                "GrentonModel",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .testTarget(
            name: "GrentonModelTests",
            dependencies: ["GrentonModel"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GrentonRuntimeTests",
            dependencies: ["GrentonRuntime", "GrentonTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GrentonProvisioningTests",
            dependencies: ["GrentonProvisioning"]
        ),
        .testTarget(
            name: "GrentonConformanceTests",
            dependencies: ["GrentonModel", "GrentonRuntime", "GrentonProvisioning", "GrentonDevices", "GrentonKit"],
            exclude: ["port.json"]
        ),
        .testTarget(
            name: "GrentonDevicesTests",
            dependencies: ["GrentonDevices", "GrentonTestSupport"],
            resources: [.copy("Fixtures")]
        ),
        .testTarget(
            name: "GrentonKitTests",
            dependencies: ["GrentonKit", "GrentonSimulation"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
