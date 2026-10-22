# Changelog

Versions follow the specification the port implements; see README,
"Versioning and stability".

## Unreleased

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
