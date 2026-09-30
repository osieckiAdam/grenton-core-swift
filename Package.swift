// swift-tools-version: 6.0
import PackageDescription

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
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.19"),
        // Documentation only: `swift package generate-documentation`.
        .package(url: "https://github.com/swiftlang/swift-docc-plugin", from: "1.4.0"),
    ],
    targets: [
        .target(name: "GrentonModel"),
        .target(name: "GrentonRuntime", dependencies: ["GrentonModel"]),
        .target(name: "GrentonDevices", dependencies: ["GrentonModel", "GrentonRuntime"]),
        .target(name: "GrentonTestSupport", dependencies: ["GrentonModel", "GrentonRuntime"]),
        .executableTarget(
            name: "grenton-cli",
            dependencies: ["GrentonProvisioning", "GrentonDevices"],
            path: "Examples/grenton-cli"
        ),
        .executableTarget(
            name: "fetch-interface",
            dependencies: ["GrentonProvisioning", "GrentonDevices"],
            path: "Examples/fetch-interface"
        ),
        .executableTarget(
            name: "list-devices",
            dependencies: ["GrentonProvisioning", "GrentonDevices"],
            path: "Examples/list-devices"
        ),
        .executableTarget(
            name: "watch-state",
            dependencies: ["GrentonProvisioning", "GrentonRuntime", "GrentonDevices"],
            path: "Examples/watch-state"
        ),
        .executableTarget(
            name: "switch-light",
            dependencies: ["GrentonProvisioning", "GrentonRuntime", "GrentonDevices"],
            path: "Examples/switch-light"
        ),
        .executableTarget(
            name: "set-thermostat",
            dependencies: ["GrentonProvisioning", "GrentonRuntime", "GrentonDevices"],
            path: "Examples/set-thermostat"
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
            dependencies: ["GrentonModel", "GrentonRuntime", "GrentonProvisioning", "GrentonDevices"],
            exclude: ["port.json"]
        ),
        .testTarget(
            name: "GrentonDevicesTests",
            dependencies: ["GrentonDevices", "GrentonTestSupport"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
