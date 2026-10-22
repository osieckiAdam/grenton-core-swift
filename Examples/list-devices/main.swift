import Foundation
import GrentonKit

/// Example: list the devices of an installation, offline.
///
///     swift run list-devices <interface.zip>
///
/// Mapping needs no network: devices come from the interface alone. Each
/// widget is one device with its entities. `physicalObjects` groups the
/// widgets that operate the same CLU object, such as a thermostat shown on
/// two pages under two names.

let arguments = CommandLine.arguments
guard arguments.count == 2 else {
    print("usage: list-devices <interface.zip>")
    exit(2)
}

let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let interface = try ProvisioningClient.parseInterfaceArchive(archive)
let devices = DeviceMapper.descriptors(for: interface)

// Devices: one per widget, in page order.
print("\(devices.count) devices")
for device in devices {
    print("\(device.kind.rawValue) \"\(device.name)\" — page \(device.page.name)")
    for entity in device.entities {
        print("  \(entity.id): \(entity.name)")
    }
}

// Widgets the library could not read (unknown type or broken data).
for skipped in interface.skippedWidgets {
    print("skipped widget of type \(skipped.type ?? "?")")
}

// Physical objects shown by more than one widget.
let shared = DeviceMapper.physicalObjects(for: devices).filter { $0.widgets.count > 1 }
print("\n\(shared.count) objects shown by several widgets")
for object in shared {
    let names = object.widgets.map { "\"\($0.name)\" (page \($0.page.name))" }
    print("\(object.key.name): " + names.joined(separator: ", "))
}
