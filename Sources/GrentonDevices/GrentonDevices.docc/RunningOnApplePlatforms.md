# Running on iOS and macOS

What an app needs from the system before the library can reach the CLUs.

## Overview

The library talks to the CLUs over UDP on the local network and, for the
first download, to Object Manager over plain HTTP. Both need permissions
that are not granted by default.

### Info.plist

Two keys, for every app that uses the library:

- `NSLocalNetworkUsageDescription` — iOS shows this text the first time
  the app sends a packet to the local network, and refuses the packets
  until the user agrees. Without the key the request fails silently.
- `NSAppTransportSecurity` with `NSAllowsLocalNetworking` set to `true` —
  Object Manager serves the interface over `http://`, which App Transport
  Security blocks otherwise. Only `ProvisioningClient` needs this; an
  app that imports the interface from a project file (`ProjectFile`)
  or loads a saved archive can leave it out.

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>Connects to the Grenton controllers in your home.</string>
<key>NSAppTransportSecurity</key>
<dict>
    <key>NSAllowsLocalNetworking</key>
    <true/>
</dict>
```

A sandboxed macOS app also needs the outgoing-connections entitlement,
`com.apple.security.network.client`. A command-line tool is not sandboxed;
macOS asks once per app whether it may access the local network.

### The first start

The local-network prompt appears when the first packet goes out, which is
the first ping of ``GrentonSystem/start()``. That ping usually times out
while the prompt is on screen, so the session is `degraded` and every
value is `nil` until the user agrees; the next ping, five seconds later,
succeeds and the library subscribes. Nothing has to be retried by hand.
If the user declines, the sessions stay `degraded`: show
``GrentonSystem/sessionStates()`` and point to Settings.

### Background and foreground

iOS suspends an app in the background, and the CLUs stop pushing to a
suspended app after about a minute anyway. Stop the system when the app
leaves the foreground and start it again when it returns; the entities
keep their last values in between, and `start()` re-subscribes:

```swift
func appDidEnterBackground() async {
    await system.stop()
}

func appWillEnterForeground() async {
    await system.start()
}
```

A command sent while the system is stopped throws
`SessionError.notConnected`. See <doc:ConnectionLifecycle> for what
happens to commands and subscriptions around `stop()`.

### macOS: sleep, wake and menu-bar apps

A Mac app keeps running, so start the system once and leave it running:
the CLUs push every change to it, and a started system costs one ping
per CLU every five seconds plus the renewal every thirty. Do not stop
and start it around every opening of a menu or window — `start()` opens
the sockets, pings every CLU and subscribes to every value again, which
takes a second or two for a few hundred values, and the values are `nil`
until the first report arrives. After the Mac sleeps, nothing needs
doing: the subscriptions expired on the CLUs meanwhile, the first ping
after waking finds the socket dead or the CLU silent, the session goes
`degraded`, and the next answered ping subscribes again (within about
ten seconds). Watch ``GrentonSystem/sessionStateUpdates()`` to show it.
Stop the system when the app quits, so the CLUs stop pushing to a closed
port at once instead of a minute later.

### Keeping the interface

The interface archive and the `.omp` project file both contain the AES key
of the installation. Keep them where only the app can read them. The
`GrentonKit` module's `InterfaceStore` is that place for both — `save(_:)`
for the archive, `save(project:interfaceId:)` for a project file: the app's
own folder under Application Support, written atomically and, on iOS, with
`.completeFileProtection`, so the file stays encrypted while the device is
locked; it also tells a newer export apart by its `version`. Never put the
archive in a shared location, in `UserDefaults` or in logs. The library
itself never writes the key anywhere and keeps it out of error messages.
