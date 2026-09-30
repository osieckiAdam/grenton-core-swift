import Foundation
import GrentonProvisioning
import GrentonRuntime
import GrentonDevices

/// Example: turn a switch or light on or off and confirm the CLU applied it.
///
///     swift run switch-light <interface.zip> <entity-id> on|off
///
/// Entity ids come from `list-devices`. Works for switches, dimmers and
/// RGB lights.

let arguments = CommandLine.arguments
guard arguments.count == 4, ["on", "off"].contains(arguments[3]) else {
    print("usage: switch-light <interface.zip> <entity-id> on|off")
    exit(2)
}
let (entityId, turnOn) = (arguments[2], arguments[3] == "on")

// Library warnings and errors (unreachable CLU, timeouts) go to stderr.
let logger = GrentonLogger { level, message in
    if level >= .warning { FileHandle.standardError.write(Data("[grenton] \(message)\n".utf8)) }
}
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let system = try GrentonSystem(interface: ProvisioningClient.parseInterfaceArchive(archive), logger: logger)

guard let entity = system.entities.first(where: { $0.id == entityId }) else {
    print("no entity \(entityId)")
    exit(1)
}

// Switches, dimmers and RGB lights share one on/off surface.
guard let light = entity.switchable else {
    print("\(entityId) is not a switch or light")
    exit(1)
}

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
print("\(light.name): \(light.isOn.map { $0 ? "on" : "off" } ?? "unknown")")

try await light.setOn(turnOn)

// The CLU pushes the new state back; wait up to 5 s for it.
let deadline = Date().addingTimeInterval(5)
while light.isOn != turnOn, Date() < deadline {
    try await Task.sleep(for: .milliseconds(200))
}
print(light.isOn == turnOn
      ? "✓ \(light.name) is now \(turnOn ? "on" : "off")"
      : "✗ no confirmation from the CLU within 5 s")
await system.stop()
