# Connection Lifecycle

What `start()` and `stop()` do, how a lost CLU comes back, and which
errors a command can throw.

## Overview

``GrentonSystem`` keeps one session per CLU. A session is `idle` until
``GrentonSystem/start()``, then `ready` while the CLU answers, `degraded`
while it does not, and `stopped` after ``GrentonSystem/stop()``.

### Starting

`start()` connects to every CLU, subscribes to every value an entity
reads, and returns once each CLU has answered or timed out. It does not
throw: a CLU that is off or unreachable leaves its session `degraded` and
its values `nil`, while the other CLUs work. Check
``GrentonSystem/sessionStates()`` after `start()` when you want to tell
the user:

```swift
await system.start()
let states = await system.sessionStates()
for (cluId, state) in states where state != .ready {
    print("CLU \(cluId) is \(state)")
}
```

Calling `start()` twice does nothing the second time.

### Following the connection

``GrentonSystem/sessionStateUpdates()`` fires whenever any CLU's state
changes, and on `start()` and `stop()`; read ``GrentonSystem/sessionStates()``
or ``GrentonSystem/diagnostics()`` then. It is a flag, like an entity's
`updates()`: changes coalesce while you are busy, none is lost.

```swift
Task {
    for await _ in await system.sessionStateUpdates() {
        let states = await system.sessionStates()
        print(states.values.allSatisfy { $0 == .ready } ? "connected" : "a CLU is not answering")
    }
}
```

### Telling the user how the house answers

``GrentonSystem/diagnostics()`` describes each CLU connection: its
state, how long ago the CLU last answered a request and last pushed a
report, how long the last ping took, how many keys are subscribed, whether
they wait to be subscribed again, and how many pings in a row went
unanswered. Every CLU of the interface is listed, as `idle` before
`start()`. It sends nothing and is cheap to call from a timer:

```swift
for (cluId, health) in await system.diagnostics() {
    switch health.state {
    case .ready:
        print("CLU \(cluId) answered \(health.sinceLastReply ?? .zero) ago, ping \(health.lastPingRoundTrip ?? .zero)")
    case .degraded:
        print("CLU \(cluId) silent for \(health.consecutivePingTimeouts) pings")
    default:
        print("CLU \(cluId) is \(health.state)")
    }
}
```

Each entry is one consistent view of one CLU; the dictionary is not one
instant of the whole installation. The times restart with every
`start()`, and `stop()` clears them.

### Staying connected

Every five seconds the library pings each CLU, and every thirty seconds it
renews its subscriptions and re-reads every value, so a report lost on the
network is corrected within half a minute. A CLU that stops answering
makes its session `degraded`; nothing else changes, and the library keeps
pinging. When the CLU answers again, the session subscribes again, reads
every value, and is `ready`. After three unanswered pings in a row the
library also replaces the connection, which helps when the device changed
networks.

### Stopping

`stop()` unsubscribes from every CLU, closes the connections and returns.
Entities keep their last values. A command still waiting for an answer
fails with `SessionError.connectionClosed`; commands sent afterwards fail
with `SessionError.notConnected` until `start()` is called again. The same
system can be started again any number of times.

A system you drop without calling `stop()` closes its connections as
well, but does not unsubscribe: the CLUs keep sending for about a minute
to nobody. Prefer `stop()`.

### Errors

Every call that talks to a CLU or to Object Manager throws one of these:

| Thrown by | Error | Meaning |
|---|---|---|
| ``GrentonSystem/init(interface:socketFactory:logger:pingInterval:registerInterval:responseTimeout:)`` | `CryptoError.invalidKeyMaterial` | The interface's key or IV is not valid base64 of 16, 24 or 32 bytes. |
| `ProvisioningClient` | `ProvisioningError.authenticationFailed` | Object Manager rejected the PIN, or its dialog is closed. |
| `ProvisioningClient` | `ProvisioningError.connection` | Object Manager could not be reached. The text is safe to log; it never contains the PIN. |
| `ProvisioningClient`, `ProjectFile` | `ProvisioningError.invalidData` | The archive or project file is not what it should be. |
| `ProjectFile` | `ProvisioningError.interfaceNotFound`, `.interfaceAmbiguous` | No interface with that id, or several and none chosen. |
| any command | `SessionError.notConnected` | The system is not started, or stopped. |
| any command | `SessionError.timeout` | The CLU did not answer within `responseTimeout` (5 s by default). |
| any command | `SessionError.connectionClosed` | `stop()` ran, or the connection was replaced, while the command waited. |
| ``GrentonSystem/execute(_:)`` | `PayloadError.unresolvedPlaceholder` | The action still carries Object Manager's `$value$` placeholder. |

A command that returns without throwing was received by the CLU; the new
state arrives as a report a moment later. Commands an entity cannot
perform on its hardware — `stop()` on a shutter without a stop action,
`setMode` or `setActive` on a thermostat without them — return without doing anything;
check ``CoverEntity/supportsStop``, ``CoverEntity/supportsTilt``,
``ThermostatEntity/supportsMode`` and ``ThermostatEntity/supportsPower``
before offering those controls.

### Logging

Pass a `GrentonLogger` to see what the library does: every frame sent
and received at `debug`, timeouts and recoveries at `warning`. Frames
carry action values and reported states, never the key.
