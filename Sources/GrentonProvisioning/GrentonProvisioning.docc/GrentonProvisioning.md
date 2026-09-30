# ``GrentonProvisioning``

Download the mobile interface from Grenton Object Manager.

## Overview

Object Manager hands the interface to the myGrenton app over the local
network, protected by a short-lived PIN. ``ProvisioningClient`` does the
same: one request returns the interface as a ZIP archive.

Save the archive and load it with
``ProvisioningClient/parseInterfaceArchive(_:)`` on later starts, so only
the first run needs Object Manager and a PIN. The archive contains the
CLU encryption key; store it privately.

See the GrentonDevices article *Getting Started* for the whole flow.

## Topics

### Downloading

- ``ProvisioningClient``
- ``ProvisioningError``
