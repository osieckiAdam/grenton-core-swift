import Testing
import Foundation
import GrentonModel
import ZIPFoundation
@testable import GrentonProvisioning

/// HTTP layer stubbed with a URLProtocol — no real networking; ZIPs are
/// built in memory with ZIPFoundation itself.
final class StubURLProtocol: URLProtocol {
    /// (status, body) served for every request; the request URL is recorded.
    nonisolated(unsafe) static var response: (status: Int, body: Data) = (200, Data())
    nonisolated(unsafe) static var headers: [String: String]? = nil
    nonisolated(unsafe) static var lastURL: URL?
    nonisolated(unsafe) static var failWith: (any Error)?
    /// Never respond — for cancellation tests.
    nonisolated(unsafe) static var stall = false

    static func reset() {
        response = (200, Data())
        headers = nil
        lastURL = nil
        failWith = nil
        stall = false
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastURL = request.url
        if Self.stall { return }
        if let error = Self.failWith {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        let http = HTTPURLResponse(
            url: request.url!, statusCode: Self.response.status,
            httpVersion: "HTTP/1.1", headerFields: Self.headers)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.response.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// The stub uses shared mutable state — run serialized.
@Suite(.serialized) struct ProvisioningTests {

    static let minimalInterfaceJSON = """
    {
      "id": "interface-prov-test",
      "version": 1,
      "name": "Dom",
      "icon": "home",
      "theme": "GRENTON",
      "encryption": { "key": "AAECAwQFBgcICQoLDA0ODw==", "iv": "EBESExQVFhcYGRobHB0eHw==" },
      "clus": [
        { "id": "CLU_1", "serialNumber": "1", "name": "CLU", "ip": "192.168.1.10",
          "port": 1234, "connectionType": "LOCAL_ONLY" }
      ],
      "pushNotifications": [],
      "pages": [
        { "name": "P", "icon": "i", "isFullscreenWidget": false, "widgets": [
          { "type": "SCENE", "id": "w-scene", "components": [
            { "type": "BUTTON_MONOSTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
              "actions": [ { "event": "CLICK", "cluId": "CLU_1", "objectName": "scr",
                             "value": "", "callType": "SCRIPT" } ] } ] } ] }
      ]
    }
    """

    func makeClient() -> ProvisioningClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return ProvisioningClient(
            host: "192.168.1.5", port: 9998,
            session: URLSession(configuration: configuration))
    }

    func makeZip(entryPath: String = "mygrenton/data.json",
                 content: Data = Data(minimalInterfaceJSON.utf8)) throws -> Data {
        let archive = try Archive(accessMode: .create)
        try archive.addEntry(
            with: entryPath, type: .file,
            uncompressedSize: Int64(content.count),
            compressionMethod: .deflate
        ) { position, size in
            content.subdata(in: Int(position)..<(Int(position) + size))
        }
        guard let data = archive.data else {
            throw ProvisioningError.invalidData("test zip build failed")
        }
        return data
    }

    @Test func fetchesAndParsesInterface() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, try makeZip())
        let interface = try await makeClient().fetchInterface(pin: "1234")

        #expect(interface.id == "interface-prov-test")
        #expect(interface.clus.count == 1)
        #expect(interface.allWidgets.count == 1)
        // Exact endpoint shape (spec §4.1).
        #expect(StubURLProtocol.lastURL?.absoluteString
            == "http://192.168.1.5:9998/api/v1/interface/hash/1234")
    }

    @Test func unauthorizedMapsToAuthenticationFailed() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (401, Data())
        await #expect(throws: ProvisioningError.authenticationFailed) {
            _ = try await makeClient().fetchInterface(pin: "0000")
        }
    }

    @Test(arguments: [404, 500, 302])
    func otherStatusesMapToConnection(status: Int) async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (status, Data())
        await #expect(throws: ProvisioningError.connection("HTTP \(status)")) {
            _ = try await makeClient().fetchInterface(pin: "1234")
        }
    }

    @Test func redirectWithLocationIsNotFollowed() async throws {
        // A 3xx must surface as its own status (spec §4.2), never fetch
        // the Location target.
        StubURLProtocol.reset()
        StubURLProtocol.headers = ["Location": "http://evil.example/other.zip"]
        StubURLProtocol.response = (302, Data())
        await #expect(throws: ProvisioningError.connection("HTTP 302")) {
            _ = try await makeClient().fetchInterface(pin: "1234")
        }
    }

    @Test func cancellationIsNotDisguisedAsConnectionError() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.stall = true
        let client = makeClient()
        let task = Task {
            try await client.fetchInterface(pin: "1234")
        }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("expected throw")
        } catch is CancellationError {
            // expected
        } catch {
            Issue.record("expected CancellationError, got \(error)")
        }
    }

    @Test func transportFailureMapsToConnection() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.failWith = URLError(.cannotConnectToHost)
        defer { StubURLProtocol.failWith = nil }
        do {
            _ = try await makeClient().fetchInterface(pin: "1234")
            Issue.record("expected throw")
        } catch let error as ProvisioningError {
            guard case .connection = error else {
                Issue.record("expected .connection, got \(error)")
                return
            }
        }
    }

    @Test func badZipBytesAreInvalidData() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, Data("definitely not a zip".utf8))
        await #expect(throws: ProvisioningError.invalidData("bad zip")) {
            _ = try await makeClient().fetchInterface(pin: "1234")
        }
    }

    @Test func missingEntryIsInvalidData() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, try makeZip(entryPath: "mygrenton/other.json"))
        await #expect(throws: ProvisioningError.invalidData("missing mygrenton/data.json")) {
            _ = try await makeClient().fetchInterface(pin: "1234")
        }
    }

    @Test func corruptedStoredEntryFailsChecksum() throws {
        // Stored (uncompressed) entry → flipping a payload byte cannot
        // break inflation, only the CRC (spec: reject corrupt data).
        let content = Data(Self.minimalInterfaceJSON.utf8)
        let archive = try Archive(accessMode: .create)
        try archive.addEntry(
            with: "mygrenton/data.json", type: .file,
            uncompressedSize: Int64(content.count),
            compressionMethod: .none
        ) { position, size in
            content.subdata(in: Int(position)..<(Int(position) + size))
        }
        var zip = try #require(archive.data)
        // Corrupt one byte inside the stored payload (find a known marker).
        let marker = Data("interface-prov-test".utf8)
        let range = try #require(zip.range(of: marker))
        zip[range.lowerBound] ^= 0xFF

        do {
            _ = try ProvisioningClient.parseInterfaceArchive(zip)
            Issue.record("expected throw")
        } catch let error as ProvisioningError {
            guard case .invalidData = error else {
                Issue.record("expected .invalidData, got \(error)")
                return
            }
        }
    }

    @Test func brokenJsonIsInvalidData() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, try makeZip(content: Data("{ not json".utf8)))
        do {
            _ = try await makeClient().fetchInterface(pin: "1234")
            Issue.record("expected throw")
        } catch let error as ProvisioningError {
            guard case .invalidData = error else {
                Issue.record("expected .invalidData, got \(error)")
                return
            }
        }
    }

    @Test func oversizedResponseIsRejected() throws {
        let oversized = Data(count: ProvisioningClient.maxPayloadBytes + 1)
        #expect(throws: ProvisioningError.invalidData(
            "response larger than \(ProvisioningClient.maxPayloadBytes) bytes")) {
            _ = try ProvisioningClient.parseInterfaceArchive(oversized)
        }
    }

    @Test func oversizedHttpBodyIsAbortedAtTheCap() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, Data(count: ProvisioningClient.maxPayloadBytes + 1))
        await #expect(throws: ProvisioningError.invalidData(
            "response larger than \(ProvisioningClient.maxPayloadBytes) bytes")) {
            _ = try await makeClient().fetchInterface(pin: "1234")
        }
    }

    @Test func pinIsPercentEncodedInPath() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, try makeZip())
        _ = try await makeClient().fetchInterface(pin: "12?34")
        #expect(StubURLProtocol.lastURL?.absoluteString
            == "http://192.168.1.5:9998/api/v1/interface/hash/12%3F34")
    }

    @Test(arguments: ["149 853", " 149853\n", "149\u{00A0}853", "149\t853"])
    func whitespaceInPinIsStripped(pin: String) throws {
        let url = try makeClient().endpointURL(pin: pin)
        #expect(url.absoluteString == "http://192.168.1.5:9998/api/v1/interface/hash/149853")
    }

    @Test func whitespaceOnlyPinIsRejected() {
        #expect(throws: ProvisioningError.self) {
            _ = try makeClient().endpointURL(pin: " \t ")
        }
    }

    @Test func slashInPinStaysOneSegment() async throws {
        StubURLProtocol.reset()
        StubURLProtocol.response = (200, try makeZip())
        _ = try await makeClient().fetchInterface(pin: "12/34")
        #expect(StubURLProtocol.lastURL?.absoluteString
            == "http://192.168.1.5:9998/api/v1/interface/hash/12%2F34")
    }

    @Test func ipv6HostIsBracketed() throws {
        let client = ProvisioningClient(host: "fe80::1", port: 9998)
        let url = try client.endpointURL(pin: "1234")
        #expect(url.absoluteString == "http://[fe80::1]:9998/api/v1/interface/hash/1234")
    }

    @Test func archiveParserIsUsableStandalone() throws {
        // Consumers may hand over a ZIP obtained without HTTP (spec §4).
        let interface = try ProvisioningClient.parseInterfaceArchive(try makeZip())
        #expect(interface.id == "interface-prov-test")
    }
}
