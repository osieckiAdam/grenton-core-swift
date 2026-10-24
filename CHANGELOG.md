# Changelog

Versions follow the specification the port implements; see README,
"Versioning and stability".

## Unreleased

- Requires Swift 6.2.3 (Xcode 26.2) to build; apps still run on iOS 16 /
  macOS 13. The catalogue enums (`BoundEntity`, `EntityDescriptor`,
  `DeviceKind`, `SensorKind`, `ObjectKey.Kind`, `WidgetDTO`, `PageItemDTO`,
  `LedComponentDTO`, the `Grenton…` value enums, `ValueSlot`, `CoverMotion`,
  `ThermostatMode`, `LegacyShutterState`) and the error enums are
  `@nonexhaustive`: a new case is a minor release, and a `switch` over
  them in an app needs `@unknown default`. `GrentonValue`, `ValueRef`,
  `SessionState` and `DeviceNumberFormat` stay exhaustive by design.
- `StrictJSONParser` accepts 64 levels of nesting instead of 512: the
  deeper limit let a crafted project file overflow the stack of a
  secondary thread in a debug build before the limit was reached.
- Follows spec 0.11.1 (suite 0.11.1, unchanged cases). An entity's
  `updates()` can no longer lose a signal: the store filters by key under
  its lock and keeps a flag per subscriber, instead of a forwarding task
  over the shared, bounded change stream, where a burst of other keys'
  changes could displace the entity's own before the task ran (spec §6.5).
  `GrentonSystem.changes()` is documented as best effort.
- `GrentonSystem.diagnostics()` and `CluSession.diagnostics`: a
  `SessionDiagnostics` snapshot per CLU — state, time since the last
  reply and the last report, the last ping's round trip, requested key
  count, whether recovery is pending, unanswered pings in a row (spec
  §5.4.5). Every CLU of the interface is listed, `idle` before `start()`.
- `GrentonKit`, the umbrella module: `import GrentonKit` re-exports the
  four modules, and `GrentonSystem(interfaceArchive:)` lives there, so
  `GrentonDevices` depends on Model and Runtime only again (spec §2). The
  app-facing examples build against the public API only
  (`packageAccess: false`) with that one import.
- `GrentonSimulation`: `SimulatedGrentonSystem` builds the same devices
  and entities over values a test sets (`set(_:to:)`, `clear(_:)`), records
  every command (`executedActions`) and fails them on request. For an
  app's test target; not part of `GrentonKit`. Article "Testing Your App".
- `RegistrationSlot` is `ValueSlot` (deprecated alias kept); it is the
  result of a one-shot read as much as of a registration.
  `StateChange` has a public initializer. `BoundDevice` and `BoundEntity`
  are no longer `Hashable`: by-id equality made handles of different
  systems interchangeable. They stay `Identifiable`.
- Gates: the doc-snippet check compiles each snippet group with exactly
  the imports it shows (`GrentonKit` when none) and the consumer
  scenarios in `scripts/consumer/` — complete app code against the public
  API, no `@testable`. `scripts/docs.sh` puts the working tree's
  `Package.resolved` back byte for byte as soon as the generation ends
  (it restored the index's copy, on exit). The DocC plugin is a dependency
  only when `GRENTON_DOCS` is exactly `1`.
- Gates: `scripts/check.sh` fails when the git hooks are not enabled or the
  installation-data gate differs from the spec's copy; that gate also reads
  a declared `.omp` (`git config grenton.project`), scans ZIP/.omp files
  and knows the key material; the spec-sync check only warns at commit
  time. The agent guard also stops `commit -n` and `core.hooksPath`.
- API surface before 1.0: the helpers and plumbing an app never needed are
  `package` (`mapRange`, `clamp`, `asInt`…, `DeviceContext`, `DeviceBinder`,
  `CommandExecuting`, `StateStore`, `Payloads`, `WireFrame`); the system
  offers `value(for:)` and `changes()` instead of its store.
  `BoundDevice`, `BoundEntity`, `DeviceDescriptor`, `EntityDescriptor` and
  `PhysicalObject` are `Identifiable` (entities and devices `Hashable` by
  id); an HSB channel's range is a `ChannelRange` instead of a tuple.
  `SensorEntity` gains `number` and `unit`. The thermostat's `isOn`,
  `turnOn()` and `turnOff()` are `isActive` and `setActive(_:)`.
- Follows spec 0.10.1 (suite 0.10.1, 232 cases). The `.omp` import converts
  every widget type of the mobile interface — `CAMERA`, `LED`,
  `CONTACT_SENSOR`, `CONTACT_SENSOR_DOUBLE`, `SLIDER`, `MULTISENSOR`, the
  legacy `ROLLER_SHUTTER` — and the new `TV_REMOTE_CONTROL` (known, not
  mapped); a widget never sent to a phone, which has no `dtoId`, gets the
  stand-in id `omp-<editor id>`, and two widgets with one id fail the
  import. Checked against a real installation: an interface imported from
  its project equals the one downloaded for it, field for field.
- A registration with a failed chunk is recovered by the next answered
  ping in any state (now stated by the spec); every conformance scenario
  ends with an implicit quiet check.
- `GrentonSystem(interfaceArchive:)` starts from the downloaded or saved
  archive directly; `GrentonDevices` now depends on `GrentonProvisioning`.
  `GrentonSystem.clus` lists the CLUs, so an app can name the one behind a
  session state. New examples `read-values` and `run-scene`.
- Documentation: "Running on iOS and macOS" (Info.plist keys, the first
  prompt, background and foreground, keeping the key) and "Connection
  Lifecycle" (states, recovery, what `stop()` does, every error a call can
  throw); a units table, the semantics of `updates()`, the `supports…`
  checks, and doc comments on the runtime types an app sees.
- The DocC plugin is no longer a dependency apps resolve: `Package.swift`
  adds it only while `GRENTON_DOCS` is set, which `scripts/docs.sh` does.

## 0.9.1 — 2026-10-21

First tagged release. Implements spec 0.9.1 and passes conformance suite
0.9.1 (230 cases: `stateless`, `mapping`, `session`, `project`).

- Provisioning: download from Object Manager, or import from an `.omp`
  project file (`ProjectFile`), both giving the same interface.
- Runtime: one UDP socket per CLU session, chunked subscriptions by frame
  size, re-registration every 30 s, `clientDestroy` on stop, one-shot reads
  (`fetch`), report values split outside quotes and nested braces.
- Lifecycle: nothing is sent before `start()`; three unanswered pings
  replace the socket; no renewal while degraded; a session dropped without
  `stop()` closes its socket.
- Devices: switches, dimmers, RGB lights, contact sensors, sensors, number
  settings, covers, state sensors, triggers, scenes, cameras and thermostats
  from the mobile interface, with normalized entities and `GrentonSystem`.
- Hardening: no trap on out-of-range numbers from the wire, bounded ZIP
  extraction, the PIN never appears in error text.
