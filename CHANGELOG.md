# Changelog

Versions follow the specification the port implements; see README,
"Versioning and stability".

## Unreleased

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
