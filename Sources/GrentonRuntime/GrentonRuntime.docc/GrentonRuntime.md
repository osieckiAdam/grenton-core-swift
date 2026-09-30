# ``GrentonRuntime``

The encrypted UDP connection to the CLU controllers.

## Overview

Most apps never use this module directly: `GrentonSystem`
runs one ``CluSession`` per CLU, keeps the subscriptions alive and stores
every value in a ``StateStore``. Reach for GrentonRuntime to log what the
library does, to read raw values, or to supply your own transport.

## Topics

### Logging and Health

- ``GrentonLogger``
- ``SessionState``

### State

- ``StateStore``
- ``StateChange``

### Sessions and Transport

- ``CluSession``
- ``UdpSocketFactory``
- ``NetworkUdpSocketFactory``
- ``AnySourceUdpSocketFactory``
