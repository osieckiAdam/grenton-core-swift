import Foundation
import GrentonModel
import GrentonProvisioning
import GrentonDevices

/// Example: read a CLU value once, without subscribing to it.
///
///     swift run read-values <interface.zip> <clu-id> <OBJ:IDX> [<OBJ:IDX> …]
///     swift run read-values dist/interface.zip CLU220000001 DOU1001:0 THE1001:14
///
/// A running system subscribes to every value its entities show. Anything
/// else — a feature no widget shows, an object that is not on the
/// interface at all — can still be read with one request. The answer is
/// stored like a report, so an entity watching that key would update too.
/// Nothing is changed on the CLU.

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: read-values <interface.zip> <clu-id> <OBJ:IDX> [<OBJ:IDX> …]")
    exit(2)
}

let system = try GrentonSystem(
    interfaceArchive: Data(contentsOf: URL(fileURLWithPath: arguments[1])))
let cluId = arguments[2]

// 1. The keys to read: an object name and a feature index each.
let refs: [ValueRef] = try arguments[3...].map { spec in
    let parts = spec.split(separator: ":")
    guard parts.count == 2 else {
        print("bad key \(spec); use OBJ:IDX, e.g. DOU1001:0")
        exit(2)
    }
    return .attribute(cluId: cluId, objectName: String(parts[0]), index: String(parts[1]))
}

// 2. Connect; the CLU must answer before anything can be read.
await system.start()
guard await system.sessionStates()[cluId] == .ready else {
    print("CLU \(cluId) did not answer (known CLUs: \(system.clus.map(\.id).joined(separator: ", ")))")
    await system.stop()
    exit(1)
}

// 3. One request per CLU, no subscription left behind.
let slots = await system.fetch(refs)
for (spec, slot) in zip(arguments[3...], slots) {
    switch slot {
    case .value(let value): print("\(spec) = \(text(value))")
    case .failed: print("\(spec): no answer")
    }
}
await system.stop()

/// A value the way the CLU wrote it: `1`, `21.5`, `"ON"`, `true`, `nil`.
func text(_ value: GrentonValue) -> String {
    switch value {
    case .null: return "nil"
    case .bool(let b): return String(b)
    case .int(let i): return String(i)
    case .double(let d): return String(d)
    case .string(let s): return "\"\(s)\""
    }
}
