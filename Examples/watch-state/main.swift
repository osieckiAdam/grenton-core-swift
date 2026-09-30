import Foundation
import GrentonProvisioning
import GrentonRuntime
import GrentonDevices

/// Example: connect to the CLUs, print every entity's state, then stream
/// changes as they happen.
///
///     swift run watch-state <interface.zip> [seconds]
///
/// Read-only: nothing is sent to the CLUs except subscriptions and pings.
/// State is read from the entities, already normalized (a switch is on/off,
/// a cover is a 0…100 position), never from raw CLU values.

let arguments = CommandLine.arguments
guard arguments.count >= 2 else {
    print("usage: watch-state <interface.zip> [seconds]")
    exit(2)
}
let seconds = arguments.count > 2 ? Int(arguments[2]) ?? 30 : 30

// Library warnings and errors (unreachable CLU, timeouts) go to stderr.
let logger = GrentonLogger { level, message in
    if level >= .warning { FileHandle.standardError.write(Data("[grenton] \(message)\n".utf8)) }
}
let archive = try Data(contentsOf: URL(fileURLWithPath: arguments[1]))
let system = try GrentonSystem(interface: ProvisioningClient.parseInterfaceArchive(archive), logger: logger)

/// A one-line reading of an entity's current state; nil for entities
/// without state (buttons, scenes, cameras).
func state(of entity: BoundEntity) -> String? {
    func show<T>(_ value: T?) -> String { value.map { "\($0)" } ?? "?" }
    switch entity {
    case .toggle(let e): return show(e.isOn.map { $0 ? "on" : "off" })
    case .dimmableLight(let e): return "\(show(e.isOn.map { $0 ? "on" : "off" })), brightness \(show(e.brightness))"
    case .hsbLight(let e): return "\(show(e.isOn.map { $0 ? "on" : "off" })), hue \(show(e.hue)), brightness \(show(e.brightness))"
    case .contactSensor(let e): return show(e.isActive.map { $0 ? "active" : "inactive" })
    case .sensor(let e): return show(e.value)
    case .numberSetting(let e): return show(e.value)
    case .cover(let e): return "position \(show(e.position)), \(e.motion)"
    case .stateSensor(let e): return "\(e.state)"
    case .thermostat(let e): return "\(show(e.currentTemperature)) °C, target \(show(e.targetTemperature)) °C"
    case .trigger, .sceneTrigger, .camera: return nil
    }
}

// start() returns after the initial registration, which delivers every
// current value — so the snapshot below is complete.
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
print("state of \(system.entities.count) entities:")
for entity in system.entities {
    if let reading = state(of: entity) {
        print("  \(entity.name) [\(entity.id)]: \(reading)")
    }
}

// Subscribe after the snapshot, so the initial values are not printed twice.
// A change in the few milliseconds in between would be missed, but the
// current state is always readable from the entity.
let watchers = system.entities.compactMap { entity -> Task<Void, Never>? in
    guard let stream = entity.updates() else { return nil }
    return Task {
        for await _ in stream {
            print("Δ \(entity.name) [\(entity.id)]: \(state(of: entity) ?? "")")
        }
    }
}

print("\nwatching for \(seconds) s…")
try await Task.sleep(for: .seconds(seconds))
watchers.forEach { $0.cancel() }
await system.stop()
