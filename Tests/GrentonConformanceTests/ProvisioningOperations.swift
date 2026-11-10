import Foundation
import GrentonModel
@testable import GrentonProvisioning

/// The `provisioning` profile (`spec/conformance.md` §4d): archives read
/// with the production parser, and downloads by the production client from
/// a real HTTP server on loopback that answers what the case says.
enum ProvisioningOperations {
    static func archive(_ input: JSON) throws -> JSON {
        let data = try fixture(try string(input, "fixture"))
        return projection(try ProvisioningClient.parseInterfaceArchive(data), extra: [:])
    }

    static func fetch(_ input: JSON) async throws -> JSON {
        let pin = try string(input, "pin")
        let server: LoopbackHTTPServer?
        let port: Int
        if input["unreachable"]?.boolValue == true {
            server = nil
            port = try LoopbackHTTPServer.closedPort()
        } else {
            guard let response = input["response"], let status = response["status"]?.intValue else {
                throw SuiteError("provisioning.fetch: no response")
            }
            var body = Data()
            if let fixture = response["body"]?["fixture"]?.stringValue {
                body = try self.fixture(fixture)
            } else if let zeros = response["body"]?["zeros"]?.intValue {
                body = Data(count: zeros)
            }
            var headers: [(String, String)] = []
            if case .object(let h)? = response["headers"] {
                headers = h.compactMap { name, value in value.stringValue.map { (name, $0) } }
            }
            let started = try LoopbackHTTPServer(status: status, headers: headers, body: body)
            server = started
            port = started.port
        }
        defer { server?.stop() }

        // A fresh session per case: no connection or cache shared between cases.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let client = ProvisioningClient(host: "127.0.0.1", port: port, session: session)
        let outcome: JSON
        do {
            let interface = try await client.fetchInterface(pin: pin)
            guard let target = server?.requestTargets.first else {
                throw SuiteError("provisioning.fetch: the server saw no request")
            }
            outcome = projection(interface, extra: ["requestTarget": .string(target)])
        } catch let error as SuiteError {
            throw error
        } catch {
            // §4.2: no text of the error holds the PIN in any form.
            let compact = String(pin.unicodeScalars.filter { !$0.properties.isWhitespace }.map(Character.init))
            let encoded = compact.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed
                .subtracting(CharacterSet(charactersIn: "/"))) ?? compact
            let texts = [String(describing: error), String(reflecting: error), error.localizedDescription,
                         (error as NSError).description]
            for form in [pin, compact, encoded] where !form.isEmpty {
                if let leaked = texts.first(where: { $0.contains(form) }) {
                    return .object(["outcome": .string("leak"), "text": .string(leaked)])
                }
            }
            outcome = .object(["outcome": .string("error"), "code": .string(Operations.errorCode(error))])
        }
        // §4.2: one request per download — more means a redirect was followed.
        if let count = server?.requestTargets.count, count > 1 {
            return .object(["outcome": .string("repeated"), "requests": .number(Double(count))])
        }
        return outcome
    }

    static func projection(_ interface: MobileInterfaceDTO, extra: [String: JSON]) -> JSON {
        var value = extra
        value["interface"] = ProjectProjection.root(interface)
        value["mapping"] = MappingProjection.interface(interface)
        return .object(["outcome": .string("ok"), "value": .object(value)])
    }

    static func fixture(_ path: String) throws -> Data {
        try Data(contentsOf: ConformanceSuite.conformanceRoot.appendingPathComponent(path))
    }

    static func string(_ json: JSON, _ key: String) throws -> String {
        guard let value = json[key]?.stringValue else { throw SuiteError("missing string `\(key)`") }
        return value
    }
}

/// An HTTP/1.1 server on 127.0.0.1 that answers every request with one
/// fixed response and closes the connection. BSD sockets, one thread that
/// polls the listener, so `stop()` always ends it.
final class LoopbackHTTPServer: @unchecked Sendable {
    let port: Int
    private let listener: Int32
    private let lock = NSLock()
    private var targets: [String] = []
    private var stopped = false

    var requestTargets: [String] { lock.withLock { targets } }

    init(status: Int, headers: [(String, String)], body: Data) throws {
        let (fd, port) = try Self.bindLoopback()
        guard listen(fd, 8) == 0 else { close(fd); throw SuiteError("listen failed") }
        listener = fd
        self.port = port
        var head = "HTTP/1.1 \(status) Status\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
        for (name, value) in headers { head += "\(name): \(value)\r\n" }
        let response = Data((head + "\r\n").utf8) + body
        let thread = Thread { [self] in serve(response) }
        thread.start()
    }

    private func serve(_ response: Data) {
        defer { close(listener) }
        while true {
            if lock.withLock({ stopped }) { return }
            var poller = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&poller, 1, 20) > 0 else { continue }
            let client = accept(listener, nil, nil)
            if client < 0 { continue }
            var request = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while request.range(of: Data("\r\n\r\n".utf8)) == nil {
                let n = read(client, &buffer, buffer.count)
                if n <= 0 { break }
                request.append(contentsOf: buffer[0..<n])
            }
            if let line = String(data: request, encoding: .utf8)?.components(separatedBy: "\r\n").first {
                let parts = line.split(separator: " ")
                if parts.count >= 2 { lock.withLock { targets.append(String(parts[1])) } }
            }
            response.withUnsafeBytes { raw in
                var offset = 0
                while offset < raw.count {
                    let n = write(client, raw.baseAddress! + offset, raw.count - offset)
                    if n <= 0 { break }
                    offset += n
                }
            }
            shutdown(client, SHUT_WR)
            close(client)
        }
    }

    func stop() {
        lock.withLock { stopped = true }
    }

    /// A loopback port on which nothing listens.
    static func closedPort() throws -> Int {
        let (fd, port) = try bindLoopback()
        close(fd)
        return port
    }

    private static func bindLoopback() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SuiteError("socket failed") }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else { close(fd); throw SuiteError("bind failed") }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return (fd, Int(UInt16(bigEndian: address.sin_port)))
    }
}
