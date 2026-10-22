import Foundation
import GrentonKit

/// Example: read the mobile interface from an Object Manager project file.
///
///     swift run import-project <project.omp> [interface-id]
///
/// No PIN and no running Object Manager: the `.omp` you save in Object
/// Manager already holds every mobile interface of the project, the CLUs
/// and the encryption key. With one interface in the project the id can be
/// omitted; with several, run once without it to see their ids.
///
/// The devices are listed the way `list-devices` does. The key is never
/// printed; the file contains it, so keep the file private.

let arguments = CommandLine.arguments
guard arguments.count == 2 || arguments.count == 3 else {
    print("usage: import-project <project.omp> [interface-id]")
    exit(2)
}

// 1. Open the project: the archive and its XML are validated here.
let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
print("\(project.interfaces.count) interface(s) in the project")
for entry in project.interfaces {
    print("  \(entry.id)  \(entry.name)")
}

// 2. Import one of them — the same MobileInterfaceDTO a download gives.
let interface: MobileInterfaceDTO
do {
    interface = try project.interface(id: arguments.count == 3 ? arguments[2] : nil)
} catch ProvisioningError.interfaceAmbiguous {
    print("\nseveral interfaces: pass the id of the one to import")
    exit(2)
}
print("\nimported \"\(interface.name)\": \(interface.clus.count) CLU(s), \(interface.pages.count) page(s)")

// 3. From here on nothing depends on the source.
let devices = DeviceMapper.descriptors(for: interface)
print("\(devices.count) devices")
for device in devices {
    print("\(device.kind.rawValue) \"\(device.name)\" — page \(device.page.name)")
}
for skipped in interface.skippedWidgets {
    print("skipped widget of type \(skipped.type ?? "?")")
}
