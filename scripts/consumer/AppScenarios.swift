// Consumer scenarios: what an app does with the library, written against
// the public API only and compiled by scripts/check-doc-snippets.py as a
// package that depends on this one. They are never run; they prove that
// the advertised imports and calls exist for an app, which the package's
// own targets, built with package access, cannot.
import Foundation
import GrentonKit

/// Download once, start from the archive, observe, control, read once.
func appLifecycle(archive: Data) async throws {
    let system = try GrentonSystem(interfaceArchive: archive)
    await system.start()

    for entity in system.entities {
        guard let updates = entity.updates() else { continue }
        Task { for await _ in updates { _ = entity.name } }
    }
    if let light = system.entities.first?.switchable {
        try await light.turnOn()
    }
    if case .thermostat(let thermostat)? = system.entities.first {
        try await thermostat.setTargetTemperature(21)
        _ = thermostat.currentTemperature
    }
    let refs = system.devices.flatMap { $0.descriptor.entities.flatMap(\.stateRefs) }
    for slot in await system.fetch(refs) {
        if case .value(let value) = slot { _ = value }
    }
    for (cluId, health) in await system.diagnostics() where health.state != .ready {
        _ = (cluId, health.sinceLastReply, health.consecutivePingTimeouts)
    }
    await system.stop()
}

/// The devices without a connection, from a project file.
func offlineDevices(projectFile: Data) throws {
    let project = try ProjectFile(data: projectFile)
    let interface = try project.interface()
    for descriptor in DeviceMapper.descriptors(for: interface) {
        _ = (descriptor.id, descriptor.kind, descriptor.name)
    }
}

/// Every entity kind an app can meet. The enum is `@nonexhaustive`: a
/// library release may add a kind, and `@unknown default` keeps this
/// compiling (and warns here when a known case is unhandled).
func describe(_ entity: BoundEntity) -> String {
    switch entity {
    case .toggle(let e): return e.name
    case .dimmableLight(let e): return e.name
    case .hsbLight(let e): return e.name
    case .contactSensor(let e): return e.name
    case .sensor(let e): return e.name
    case .numberSetting(let e): return e.name
    case .cover(let e): return e.name
    case .stateSensor(let e): return e.name
    case .trigger(let e): return e.name
    case .sceneTrigger(let e): return e.name
    case .camera(let e): return e.name
    case .thermostat(let e): return e.name
    @unknown default: return "unsupported"
    }
}

/// Errors an app tells apart.
func explain(_ error: any Error) -> String {
    switch error {
    case SessionError.notConnected: return "not connected"
    case SessionError.timeout: return "no answer"
    case ProvisioningError.authenticationFailed: return "wrong PIN"
    default: return String(describing: error)   // also any case added later
    }
}
