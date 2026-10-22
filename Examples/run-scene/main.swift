import Foundation
import GrentonKit

/// Example: run a scene from the mobile interface.
///
///     swift run run-scene <interface.zip> <scene>
///     swift run run-scene dist/interface.zip "Return to base"
///
/// `<scene>` is the scene's name as shown in the app, or its entity id
/// (`list-devices` prints both). A scene is a script on a CLU; running it
/// does whatever the script does — lights, blinds, a vacuum — so choose
/// one whose effect you want. The CLU answers when it has started the
/// script; a scene has no state to read back.

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    print("usage: run-scene <interface.zip> <scene name or entity id>")
    exit(2)
}

let system = try GrentonSystem(
    interfaceArchive: Data(contentsOf: URL(fileURLWithPath: arguments[1])))

// 1. Scenes are entities like any other; find one by name or id.
let scenes = system.entities.compactMap { entity -> SceneTriggerEntity? in
    if case .sceneTrigger(let scene) = entity { return scene }
    return nil
}
guard let scene = scenes.first(where: { $0.name == arguments[2] || $0.id == arguments[2] }) else {
    print("no scene named \"\(arguments[2])\". Scenes in this interface:")
    for scene in scenes { print("  \(scene.id)  \(scene.name)") }
    exit(2)
}

// 2. Connect: the scene's CLU must answer before a command can be sent.
await system.start()
let states = await system.sessionStates()
guard states.values.contains(.ready) else {
    print("no CLU answered (\(system.clus.map(\.id).joined(separator: ", "))); is this app allowed on the local network?")
    await system.stop()
    exit(1)
}

// 3. Run it. The call returns once the CLU acknowledged the script.
do {
    try await scene.run()
    print("ran \"\(scene.name)\"")
} catch {
    print("\"\(scene.name)\" failed: \(error)")
    await system.stop()
    exit(1)
}
await system.stop()
