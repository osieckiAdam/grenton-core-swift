// The widgets of 0.12: a schedule and a remote, plus the archive store,
// as an app uses them through the public API.
import Foundation
import GrentonKit

func scheduleAndRemote(system: GrentonSystem) async throws {
    for entity in system.entities {
        switch entity {
        case .eventSchedule(let schedule):
            if let next = schedule.nextRule { _ = (next.hour, next.minute, next.days) }
            try await schedule.addRule(hour: 7, minute: 30, days: [.monday, .friday])
            if let rule = schedule.rules?.last { try await schedule.deleteRule(rule.id) }
        case .tvRemote(let remote) where remote.buttons.contains(.on):
            try await remote.press(.on)
        default:
            break
        }
    }
}

func keepTheInterface() async throws {
    let store = try InterfaceStore()
    if try store.load() == nil {
        let archive = try await ProvisioningClient(host: "192.168.1.50").fetchInterfaceArchive(pin: "149 853")
        try store.save(archive)
    }
    let system = try store.system()
    await system.start()
    await system.stop()
}
