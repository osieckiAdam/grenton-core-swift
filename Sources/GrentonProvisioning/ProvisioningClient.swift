import Foundation
import GrentonModel
import ZIPFoundation

/// Why downloading the interface failed.
public enum ProvisioningError: Error, Sendable, Equatable {
    /// Object Manager rejected the PIN, or its “Send to mobile devices” dialog is closed.
    case authenticationFailed
    /// Object Manager could not be reached, or answered with an unexpected status.
    case connection(String)
    /// The answer is not a valid interface archive, or the project file is malformed.
    case invalidData(String)
    /// The project file has no interface with the requested id, or none at all.
    case interfaceNotFound
    /// The project file has several interfaces and none was chosen.
    case interfaceAmbiguous
}

// Object Manager client (spec §4): one HTTP GET returns a ZIP whose
// `mygrenton/data.json` is the full mobile-interface definition. Needed
// only while provisioning — the Runtime takes the parsed interface as a
// value and never talks to the OM.
/// Downloads the mobile interface from Grenton Object Manager.
///
/// Object Manager serves the interface over the local network while its “Send to mobile devices” dialog is open. The dialog shows the address, the port and the PIN (token):
///
/// ```swift
/// let client = ProvisioningClient(host: "192.168.1.50")
/// let archive = try await client.fetchInterfaceArchive(pin: "149 853")
/// ```
///
/// Save the archive and load it later with ``parseInterfaceArchive(_:)``. It contains the CLU encryption key, so store it privately.
public struct ProvisioningClient: Sendable {
    /// The port Object Manager uses unless its dialog shows another.
    public static let defaultPort = 9998
    // Caps for the HTTP body and the decompressed JSON (spec §4.3 pt 4) —
    // protection against a zip bomb or a garbage response.
    /// The largest archive, and the largest interface inside it, the client accepts.
    public static let maxPayloadBytes = 10 * 1024 * 1024

    private let host: String
    private let port: Int
    private let session: URLSession

    /// Creates a client for the computer running Object Manager.
    ///
    /// - Parameters:
    ///   - host: The IP address or name shown in Object Manager's dialog.
    ///   - port: The port shown in the dialog.
    ///   - session: The URL session for the request.
    public init(host: String, port: Int = ProvisioningClient.defaultPort, session: URLSession = .shared) {
        self.host = host
        self.port = port
        self.session = session
    }

    /// A pin is one path SEGMENT — `/` must be encoded, not treated as a
    /// separator.
    private static let pinAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    /// Refuses HTTP redirects: any 3xx must surface as its own status and
    /// map to `.connection` (spec §4.2) instead of silently fetching a ZIP
    /// from wherever `Location` points.
    private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate, Sendable {
        static let shared = NoRedirectDelegate()
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest,
            completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }

    func endpointURL(pin: String) throws -> URL {
        guard (1...65535).contains(port) else {
            throw ProvisioningError.connection("invalid port \(port)")
        }
        // OM displays the token grouped ("149 853"); users paste it as seen.
        let pin = pin.filter { !$0.isWhitespace }
        guard !pin.isEmpty,
              let encodedPin = pin.addingPercentEncoding(withAllowedCharacters: Self.pinAllowed)
        else {
            throw ProvisioningError.connection("cannot build OM URL")
        }
        var components = URLComponents()
        components.scheme = "http"
        if host.contains(":") && !host.hasPrefix("[") {
            // Bare IPv6 literal — URLComponents requires the bracketed form.
            components.percentEncodedHost = "[\(host)]"
        } else {
            components.host = host
        }
        components.port = port
        components.percentEncodedPath = "/api/v1/interface/hash/\(encodedPin)"
        guard let url = components.url else {
            throw ProvisioningError.connection("cannot build OM URL")
        }
        return url
    }

    // `GET http://{host}:{port}/api/v1/interface/hash/{pin}` (spec §4.1).
    // Plain HTTP — that is how the OM speaks; the channel is LAN-only.
    // The app embedding this must allow local networking under ATS.
    //
    // The body is STREAMED against the 10 MB cap (spec §4.3 pt 4) — a
    // runaway response is aborted at the limit, never fully buffered.
    // Task cancellation is rethrown as `CancellationError`, not disguised
    // as a connection failure.
    /// Downloads and parses the interface.
    ///
    /// - Parameter pin: The token from Object Manager's dialog. Spaces are ignored.
    /// - Throws: ``ProvisioningError``.
    public func fetchInterface(pin: String) async throws -> MobileInterfaceDTO {
        try Self.parseInterfaceArchive(try await fetchInterfaceArchive(pin: pin))
    }

    // The raw interface ZIP, unparsed — for consumers that cache it so a
    // later start needs no (short-lived) pin. Same transport rules as
    // `fetchInterface`; parse with `parseInterfaceArchive`.
    /// Downloads the interface as a ZIP archive, without parsing it.
    ///
    /// Save the archive so later starts need no PIN, and parse it with ``parseInterfaceArchive(_:)``.
    ///
    /// - Parameter pin: The token from Object Manager's dialog. Spaces are ignored.
    /// - Throws: ``ProvisioningError``.
    public func fetchInterfaceArchive(pin: String) async throws -> Data {
        let url = try endpointURL(pin: pin)

        let byteStream: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (byteStream, response) = try await session.bytes(
                from: url, delegate: NoRedirectDelegate.shared)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProvisioningError.connection(String(describing: error))
        }

        guard let http = response as? HTTPURLResponse else {
            throw ProvisioningError.connection("non-HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401:
            throw ProvisioningError.authenticationFailed
        default:
            throw ProvisioningError.connection("HTTP \(http.statusCode)")
        }

        var body = Data()
        if let expected = http.expectedContentLength as Int64?, expected > 0,
           expected <= Int64(Self.maxPayloadBytes) {
            body.reserveCapacity(Int(expected))
        }
        do {
            for try await byte in byteStream {
                body.append(byte)
                if body.count > Self.maxPayloadBytes {
                    throw ProvisioningError.invalidData(
                        "response larger than \(Self.maxPayloadBytes) bytes")
                }
            }
        } catch let error as ProvisioningError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            throw ProvisioningError.connection(String(describing: error))
        }

        return body
    }

    // ZIP → `mygrenton/data.json` → `MobileInterfaceDTO` (spec §4.3).
    // Exposed for tests and for consumers that obtained the ZIP another
    // way (file, QR-transferred blob).
    /// Reads the interface from a ZIP archive saved earlier.
    ///
    /// - Throws: ``ProvisioningError/invalidData(_:)`` when the archive is damaged or holds no interface.
    public static func parseInterfaceArchive(_ zipData: Data) throws -> MobileInterfaceDTO {
        guard zipData.count <= maxPayloadBytes else {
            throw ProvisioningError.invalidData("response larger than \(maxPayloadBytes) bytes")
        }

        let archive: Archive
        do {
            archive = try Archive(data: zipData, accessMode: .read)
        } catch {
            throw ProvisioningError.invalidData("bad zip")
        }

        // Exact path match, no normalization (spec §4.3 pt 4); exactly one
        // regular-file entry — duplicates would make provisioning ambiguous.
        let entryPath = "mygrenton/data.json"
        let matches = archive.filter { $0.path == entryPath }
        guard let entry = matches.first else {
            throw ProvisioningError.invalidData("missing \(entryPath)")
        }
        guard matches.count == 1 else {
            throw ProvisioningError.invalidData("duplicate \(entryPath) entries")
        }
        guard entry.type == .file else {
            throw ProvisioningError.invalidData("\(entryPath) is not a regular file")
        }
        guard entry.uncompressedSize <= maxPayloadBytes else {
            throw ProvisioningError.invalidData("data.json larger than \(maxPayloadBytes) bytes")
        }

        var json = Data()
        do {
            let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
                json.append(chunk)
            }
            // The consumer overload computes but does not verify the CRC.
            guard checksum == entry.checksum else {
                throw ProvisioningError.invalidData("data.json checksum mismatch")
            }
        } catch let error as ProvisioningError {
            throw error
        } catch {
            throw ProvisioningError.invalidData("ZIP extraction failed")
        }

        do {
            return try MobileInterfaceDTO.decode(from: json)
        } catch {
            throw ProvisioningError.invalidData("interface JSON does not decode: \(error)")
        }
    }
}
