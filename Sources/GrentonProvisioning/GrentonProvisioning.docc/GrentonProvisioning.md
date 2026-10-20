# ``GrentonProvisioning``

Get the mobile interface: download it from Grenton Object Manager, or read it from a project file.

## Overview

Object Manager hands the interface to the myGrenton app over the local
network, protected by a short-lived PIN. ``ProvisioningClient`` does the
same: one request returns the interface as a ZIP archive.

Save the archive and load it with
``ProvisioningClient/parseInterfaceArchive(_:)`` on later starts, so only
the first run needs Object Manager and a PIN. The archive contains the
CLU encryption key; store it privately.

### From a project file

A project saved in Object Manager (`.omp`) already holds every mobile
interface of the project, the CLUs and the key. ``ProjectFile`` reads it
without a PIN and without Object Manager running:

```swift
let project = try ProjectFile(data: Data(contentsOf: URL(fileURLWithPath: "house.omp")))
let interface = try project.interface()
```

A project with several interfaces needs the id of the one to import;
``ProjectFile/interfaces`` lists them. Both sources give the same
`MobileInterfaceDTO`; one difference is that an imported
interface has `version` 0, because the project stores no export counter.

See the GrentonDevices article *Getting Started* for the whole flow.

## Topics

### Downloading

- ``ProvisioningClient``
- ``ProvisioningError``

### Importing a project file

- ``ProjectFile``
- ``ProjectInterface``
