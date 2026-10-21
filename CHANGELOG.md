# Changelog

Versions follow the specification the port implements; see README,
"Versioning and stability".

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
