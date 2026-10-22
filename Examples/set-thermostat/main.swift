import Foundation
import GrentonProvisioning
import GrentonRuntime
import GrentonDevices

/// Example: set a thermostat's manual set point through the library and
/// check that the CLU applied it.
///
///     swift run set-thermostat <interface.zip> <object-name> <celsius>
///     swift run set-thermostat dist/interface.zip THE1001 25
///
/// The thermostat is found by its CLU object (e.g. THE1001) through
/// `physicalObjects`, so it does not matter how many widgets show it. The
/// previous target is read first and printed, so it can be restored. Nothing
/// is written if the current target cannot be read.

let arguments = CommandLine.arguments
guard arguments.count == 4, let newTarget = Double(arguments[3]) else {
    print("usage: set-thermostat <interface.zip> <object-name> <celsius>")
    exit(2)
}
let (interfacePath, objectName) = (arguments[1], arguments[2])

// 1. Load the interface saved from Object Manager (fetch-interface).
let archive = try Data(contentsOf: URL(fileURLWithPath: interfacePath))
let interface = try ProvisioningClient.parseInterfaceArchive(archive)
// Library warnings and errors (unreachable CLU, timeouts) go to stderr.
let logger = GrentonLogger { level, message in
    if level >= .warning { FileHandle.standardError.write(Data("[grenton] \(message)\n".utf8)) }
}
let system = try GrentonSystem(interface: interface, logger: logger)

// 2. Find the thermostat by its CLU object; one object may be shown by
//    several widgets, all operating the same thermostat.
guard let object = system.physicalObjects.first(where: { $0.key.name == objectName }),
      let entityId = object.widgets.first?.entityIds.first,
      case .thermostat(let thermostat)? = system.entities.first(where: { $0.id == entityId })
else {
    print("no thermostat for object \(objectName)")
    exit(1)
}
print("\(objectName) is shown as: "
      + object.widgets.map { "\"\($0.name)\" (page \($0.page.name))" }.joined(separator: ", "))

func describe() -> String {
    func celsius(_ value: Double?) -> String { value.map { "\($0) °C" } ?? "?" }
    return "current \(celsius(thermostat.currentTemperature)), target \(celsius(thermostat.targetTemperature)), "
        + "mode \(thermostat.mode.map { "\($0)" } ?? "?"), running \(thermostat.isOn.map { "\($0)" } ?? "?")"
}

func waitUntil(seconds: Double, _ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(250))
    }
    return condition()
}

// 3. Connect; the initial registration delivers the current values.
await system.start()

// Stop early when no CLU answered — every value would be unknown.
let sessions = await system.sessionStates()
print("CLUs: " + sessions.sorted { $0.key < $1.key }.map { "\($0.key) \($0.value)" }.joined(separator: ", "))
guard sessions.values.contains(.ready) else {
    print("""
        no CLU answered. Check that this Mac is on the installation's network and that \
        your terminal app may use it: System Settings → Privacy & Security → Local Network.
        """)
    await system.stop()
    exit(1)
}
guard try await waitUntil(seconds: 10, { thermostat.targetTemperature != nil }),
      let previous = thermostat.targetTemperature
else {
    print("current target not received within 10 s — nothing was written")
    await system.stop()
    exit(1)
}
print("before: \(describe())")
guard previous != newTarget else {
    print("the target is already \(newTarget) °C — nothing to verify; pick another value")
    await system.stop()
    exit(0)
}

// 4. Write the set point and wait for the CLU to report the new target.
try await thermostat.setTargetTemperature(newTarget)
let applied = try await waitUntil(seconds: 15, { thermostat.targetTemperature == newTarget })
print("after:  \(describe())")
print(applied
      ? "✓ the CLU applied \(newTarget) °C"
      : "✗ the target did not change within 15 s (mode not manual, or the value was rejected)")
print("to restore: swift run set-thermostat \(interfacePath) \(objectName) \(previous)")
await system.stop()
