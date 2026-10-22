import Foundation
import GrentonKit

/// Live-installation smoke tool (milestone 7): fetches the interface from
/// a running Object Manager, lists the canonical devices, connects to the
/// CLUs, and streams state changes.
///
///     grenton-cli <om-host> <pin> [options]
///     grenton-cli --interface-file <path> [options]
///
/// Requires the same LAN as the OM/CLUs. On macOS the first run may ask
/// for local-network permission.
///
/// Top-level code is MainActor-isolated: a Task created here inherits that
/// isolation, so blocking the main thread (semaphore, wait) deadlocks it.
/// The tool therefore runs on top-level `await` (SE-0343).

let arguments = CommandLine.arguments

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func usage(exitCode: Int32 = 2) -> Never {
    print("""
    usage: grenton-cli <om-host> <pin> [options]
           grenton-cli --interface-file <path> [options]

      Loads the myGrenton interface (from the Object Manager, or from a file
      saved earlier with --save-interface), prints the canonical device list,
      then connects to the CLUs and streams state changes.

    options:
      --port <n>                OM port (default 9998)
      --watch <seconds>         how long to stream changes (default 30; 0 = list only)
      --any-source              one unconnected BSD socket per CLU (accepts any sender)
      --on <entity-id>          turn a switch or light ON after connecting (repeatable)
      --off <entity-id>         turn a switch or light OFF after connecting (repeatable)
      --set-temperature <entity-id>=<celsius>
                                set a thermostat's manual set point; prints its
                                state first so the old value can be restored
      --save-interface <path>   write the fetched interface ZIP (contains the
                                AES key — keep it out of the repo)
      --interface-file <path>   load a saved ZIP (or bare data.json) — no pin needed
    """)
    exit(exitCode)
}

/// The value after an option; another option token is never taken as a
/// value (`--save-interface --any-source` must not name a file
/// "--any-source"). Use `./-name` for a file that starts with a dash.
func optionValue(_ option: String, at index: Int) -> String {
    guard index < arguments.count, !arguments[index].hasPrefix("-") else {
        fail("\(option) needs a value")
    }
    return arguments[index]
}

var positional: [String] = []
var port = ProvisioningClient.defaultPort
var watchSeconds = 30
var anySource = false
/// `--on`/`--off` requests in command-line order: (entity id, target state).
var switchRequests: [(id: String, on: Bool)] = []
var temperatureRequests: [(id: String, celsius: Double)] = []
var saveInterfacePath: String?
var interfaceFilePath: String?

var index = 1
while index < arguments.count {
    switch arguments[index] {
    case "--port":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]),
              (1...65535).contains(value) else { fail("--port needs a number in 1...65535") }
        port = value
    case "--watch":
        index += 1
        guard index < arguments.count, let value = Int(arguments[index]),
              value >= 0 else { fail("--watch needs a number >= 0") }
        watchSeconds = value
    case "--any-source":
        anySource = true
    case "--on", "--off":
        let option = arguments[index]
        index += 1
        switchRequests.append((optionValue(option, at: index), option == "--on"))
    case "--set-temperature":
        index += 1
        let value = optionValue("--set-temperature", at: index)
        let parts = value.split(separator: "=", maxSplits: 1)
        guard parts.count == 2, let celsius = Double(parts[1]) else {
            fail("--set-temperature needs <entity-id>=<celsius>, e.g. k3Xq9TzA_0=21")
        }
        temperatureRequests.append((String(parts[0]), celsius))
    case "--save-interface":
        index += 1
        saveInterfacePath = optionValue("--save-interface", at: index)
    case "--interface-file":
        index += 1
        interfaceFilePath = optionValue("--interface-file", at: index)
    case "-h", "--help":
        usage(exitCode: 0)
    case let option where option.hasPrefix("--"):
        fail("unknown option \(option)")
    default:
        positional.append(arguments[index])
    }
    index += 1
}

/// Atomic write that is owner-only from the first byte: the archive
/// carries the CLU AES key, so it must never exist world-readable — not
/// even as the temp file of `Data.write(options: .atomic)`.
func writeOwnerOnly(_ data: Data, to url: URL) throws {
    let temp = url.deletingLastPathComponent()
        .appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString).tmp")
    let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
    guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    do {
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temp.path, url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    } catch {
        unlink(temp.path)
        throw error
    }
}

/// A saved interface is either the OM's ZIP or a bare `data.json`.
func loadInterface(fromFile path: String) throws -> MobileInterfaceDTO {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    if data.starts(with: [0x50, 0x4B]) {   // "PK" — ZIP local file header
        return try ProvisioningClient.parseInterfaceArchive(data)
    }
    return try MobileInterfaceDTO.decode(from: data)
}

do {
    let interface: MobileInterfaceDTO
    if let interfaceFilePath {
        guard positional.isEmpty else { fail("--interface-file takes no <om-host> <pin>") }
        guard saveInterfacePath == nil else { fail("--save-interface needs an OM fetch, not a file") }
        print("→ loading interface from \(interfaceFilePath) …")
        interface = try loadInterface(fromFile: interfaceFilePath)
    } else {
        // `149 853` typed unquoted (as OM displays it) arrives as two args.
        guard positional.count >= 2 else { usage() }
        let (host, pin) = (positional[0], positional[1...].joined())
        print("→ fetching interface from http://\(host):\(port) …")
        let archive = try await ProvisioningClient(host: host, port: port)
            .fetchInterfaceArchive(pin: pin)
        interface = try ProvisioningClient.parseInterfaceArchive(archive)
        if let saveInterfacePath {
            let url = URL(fileURLWithPath: saveInterfacePath)
            try writeOwnerOnly(archive, to: url)
            print("✓ saved interface ZIP to \(url.path) (mode 600)")
        }
    }
    print("✓ interface \"\(interface.name)\" (id \(interface.id), version \(interface.version))")
    for clu in interface.clus {
        print("  CLU \(clu.name) [\(clu.id)] at \(clu.ip):\(clu.port) (\(clu.connectionType.rawValue))")
    }
    for diagnostic in interface.skippedWidgets {
        print("  ! skipped widget type=\(diagnostic.type ?? "?"): \(diagnostic.reason.prefix(120))")
    }

    let factory: any UdpSocketFactory =
        anySource ? AnySourceUdpSocketFactory() : NetworkUdpSocketFactory()
    let system = try GrentonSystem(
        interface: interface,
        socketFactory: factory,
        logger: .standardOutput)

    print("\nDevices (\(system.devices.count)):")
    for device in system.devices {
        print("  \(device.descriptor.typeName) [\(device.descriptor.id)]")
        for entity in device.entities {
            print("    - \(entity.id): \(entity.name)")
        }
    }

    let objects = system.physicalObjects
    let shared = objects.filter { $0.widgets.count > 1 }
    print("\nPhysical objects (\(objects.count), \(shared.count) shown by several widgets):")
    for object in shared {
        print("  \(object.key.name)\(object.key.index.map { " / \($0)" } ?? "") [\(object.key.kind.rawValue)]")
        for widget in object.widgets {
            print("    - \(widget.name) — page \"\(widget.page.name)\" (\(widget.entityIds.joined(separator: ", ")))")
        }
    }

    if watchSeconds > 0 {
        print("\n→ connecting to CLUs (\(anySource ? "any-source" : "connected")), watching for \(watchSeconds)s …")
        let changes = system.changes()
        let interruptHandler = stopOnInterrupt(system)
        await system.start()
        print("✓ sessions: \(await system.sessionStates())")

        let watcher = Task {
            for await change in changes {
                print("  Δ \(change.key) : \(String(describing: change.oldValue)) → \(change.newValue)")
            }
        }

        if !temperatureRequests.isEmpty {
            try await Task.sleep(for: .seconds(3))
            for (id, celsius) in temperatureRequests {
                guard let entity = system.entities.first(where: { $0.id == id }),
                      case .thermostat(let thermostat) = entity else {
                    print("  ! --set-temperature: no thermostat with id \(id)")
                    continue
                }
                func show(_ value: Double?) -> String { value.map { "\($0)" } ?? "?" }
                print("  thermostat \(id) (\(thermostat.name)): current \(show(thermostat.currentTemperature)) °C, "
                      + "target \(show(thermostat.targetTemperature)) °C, "
                      + "range \(show(thermostat.minTemperature))…\(show(thermostat.maxTemperature)), "
                      + "mode \(thermostat.mode.map { "\($0)" } ?? "?"), active \(thermostat.isActive.map { "\($0)" } ?? "?")")
                do {
                    try await thermostat.setTargetTemperature(celsius)
                    print("  ✓ set point of \(id) sent: \(celsius) °C — restore with --set-temperature \(id)=\(show(thermostat.targetTemperature))")
                } catch {
                    print("  ! --set-temperature \(id) failed: \(error)")
                }
            }
        }

        if !switchRequests.isEmpty {
            // Give the sessions a moment to settle, then fire the actions —
            // a live test of the command path AND of push-on-change.
            try await Task.sleep(for: .seconds(3))
            for (id, on) in switchRequests {
                let option = on ? "--on" : "--off"
                guard let entity = system.entities.first(where: { $0.id == id }) else {
                    print("  ! \(option): no entity with id \(id)")
                    continue
                }
                guard let light = entity.switchable else {
                    print("  ! \(option): \(id) is not a switch or light")
                    continue
                }
                do {
                    try await light.setOn(on)
                    print("  ✓ turned \(on ? "ON" : "OFF") \(id) (\(entity.name))")
                } catch {
                    print("  ! \(option) \(id) failed: \(error)")
                }
            }
        }

        try await Task.sleep(for: .seconds(watchSeconds))
        watcher.cancel()
        await system.stop()
        interruptHandler.cancel()
        print("✓ done")
    }
} catch {
    FileHandle.standardError.write(Data("error: \(error)\n".utf8))
    exit(1)
}

/// Ctrl+C disconnects first, so every CLU gets `clientDestroy` and stops
/// pushing at once, instead of pushing to a closed port for up to a minute.
func stopOnInterrupt(_ system: GrentonSystem) -> any DispatchSourceSignal {
    signal(SIGINT, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
    source.setEventHandler {
        Task {
            print("\ninterrupted, disconnecting…")
            await system.stop()
            exit(130)
        }
    }
    source.resume()
    return source
}
