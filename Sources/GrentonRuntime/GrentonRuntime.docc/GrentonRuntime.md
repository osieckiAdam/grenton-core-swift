# ``GrentonRuntime``

The encrypted UDP connection to the CLU controllers.

## Overview

Most apps never use this module directly: `GrentonSystem`
runs one ``CluSession`` per CLU, keeps the subscriptions alive and stores
every value; `GrentonSystem.value(for:)` and `GrentonSystem.changes()`
read them. Reach for GrentonRuntime to log what the library does, to
catch its errors, or to supply your own transport.

## Topics

### Logging and Health

- ``GrentonLogger``
- ``SessionState``
- ``SessionDiagnostics``

### State

- ``StateChange``
- ``ValueSlot``

### Sessions and Transport

- ``CluSession``
- ``UdpSocketFactory``
- ``NetworkUdpSocketFactory``
- ``AnySourceUdpSocketFactory``
