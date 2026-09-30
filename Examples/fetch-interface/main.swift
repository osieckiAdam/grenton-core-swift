import Foundation
import GrentonProvisioning

/// Example: download the mobile interface from Object Manager and save it.
///
///     swift run fetch-interface <om-host>[:port] <output.zip> <pin>
///     swift run fetch-interface 192.168.1.50 dist/interface.zip 149 853
///
/// The PIN is the token shown in Object Manager's "Send to mobile devices"
/// dialog, which must stay open while this runs. It goes last, so it can be
/// typed exactly as the dialog shows it: `149 853` arrives as two arguments
/// and is joined back (the library ignores whitespace in a PIN anyway). The
/// port defaults to 9998; the dialog shows it, e.g. `192.168.1.50:9999`.
///
/// The saved ZIP lets later runs start without a PIN. It contains the CLU
/// encryption key, so it is written readable by the owner only.

let arguments = CommandLine.arguments
guard arguments.count >= 4 else {
    print("usage: fetch-interface <om-host>[:port] <output.zip> <pin>")
    exit(2)
}
let outputPath = arguments[2]
let pin = arguments[3...].joined()

// "host:port" for a hostname or IPv4 address; an IPv6 literal has several
// colons and keeps the default port.
var host = arguments[1]
var port = ProvisioningClient.defaultPort
if host.filter({ $0 == ":" }).count == 1, let colon = host.firstIndex(of: ":") {
    guard let parsed = Int(host[host.index(after: colon)...]) else {
        print("bad port in \(host)")
        exit(2)
    }
    port = parsed
    host = String(host[..<colon])
}

// 1. One HTTP request to Object Manager returns the interface as a ZIP.
let client = ProvisioningClient(host: host, port: port)
let archive: Data
do {
    archive = try await client.fetchInterfaceArchive(pin: pin)
} catch ProvisioningError.authenticationFailed {
    print("Object Manager rejected the PIN — check the token and keep its dialog open")
    exit(1)
} catch ProvisioningError.connection {
    print("cannot reach Object Manager at \(host):\(port) — check the IP and port in its "
          + "\"Send to mobile devices\" dialog, and keep that dialog open")
    exit(1)
}

// 2. Parse it to check it is a valid interface before saving.
let interface = try ProvisioningClient.parseInterfaceArchive(archive)
print("interface \"\(interface.name)\" (version \(interface.version))")
for clu in interface.clus {
    print("  CLU \(clu.name) at \(clu.ip):\(clu.port)")
}

// 3. Save it, owner-readable only (mode 600).
let directory = URL(fileURLWithPath: outputPath).deletingLastPathComponent()
try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
guard FileManager.default.createFile(
    atPath: outputPath, contents: archive, attributes: [.posixPermissions: 0o600])
else {
    print("cannot write \(outputPath)")
    exit(1)
}
print("saved to \(outputPath)")
