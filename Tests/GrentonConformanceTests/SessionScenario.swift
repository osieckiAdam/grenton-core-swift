import Foundation
import GrentonModel
import GrentonRuntime

/// Runs one `session.scenario` case (conformance.md §4b) against a real
/// `CluSession`, playing the CLU with a scripted transport and moving a
/// virtual clock. Returns `{completed: true}`, or where and why it failed.
final class SessionScenario: @unchecked Sendable {
    /// Key and IV of spec §9.1 — scenarios work on plaintext frames.
    static let keyBase64 = "AAECAwQFBgcICQoLDA0ODw=="
    static let ivBase64 = "EBESExQVFhcYGRobHB0eHw=="

    private let clock = ManualClock()
    private let transport = ScriptedTransport()
    private let cipher: AesCbcCipher
    private let session: CluSession
    private let cluIp: String

    private var labels: [String: ScriptedSocket] = [:]
    private var captures: [String: String] = [:]
    private var calls: [String: Task<JSON, Never>] = [:]
    private let reportLock = NSLock()
    private var reports: [ChunkReport] = []
    private var reportTask: Task<Void, Never>?

    init(input: JSON) throws {
        guard let clu = input["clu"], let id = clu["id"]?.stringValue, let ip = clu["ip"]?.stringValue,
              let port = clu["port"]?.intValue, let timeout = input["responseTimeoutMs"]?.intValue else {
            throw SuiteError("session.scenario: bad clu or responseTimeoutMs")
        }
        cipher = try AesCbcCipher(keyBase64: Self.keyBase64, ivBase64: Self.ivBase64)
        cluIp = ip
        session = CluSession(
            clu: Clu(id: id, serialNumber: "0", name: id, ip: ip, port: port, connectionType: .localOnly),
            cipher: cipher, socketFactory: transport, clock: clock,
            responseTimeout: .milliseconds(timeout),
            // An omitted interval is the port's default (conformance.md §4b).
            pingInterval: input["pingIntervalMs"]?.intValue.map { .milliseconds($0) } ?? CluSession.defaultPingInterval,
            registerInterval: input["registerIntervalMs"]?.intValue.map { .milliseconds($0) }
                ?? CluSession.defaultRegisterInterval)
    }

    func run(_ steps: [JSON]) async -> JSON {
        let stream = await session.reports()
        reportTask = Task { [weak self] in
            for await report in stream { self?.appendReport(report) }
        }
        defer {
            reportTask?.cancel()
            calls.values.forEach { $0.cancel() }
        }
        for (index, step) in steps.enumerated() {
            do {
                try await perform(step)
            } catch {
                await session.stop()
                return .object(["completed": .bool(false), "failedStep": .number(Double(index)),
                                "step": step, "observed": .string(String(describing: error))])
            }
        }
        await session.stop()
        return .object(["completed": .bool(true)])
    }

    private func appendReport(_ report: ChunkReport) {
        reportLock.withLock { reports.append(report) }
    }

    private func takeReport(wait: Duration = .seconds(2)) async -> ChunkReport? {
        let deadline = ContinuousClock.now.advanced(by: wait)
        while ContinuousClock.now < deadline {
            if let first = takeFirstReport() { return first }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return takeFirstReport()
    }

    private func takeFirstReport() -> ChunkReport? {
        reportLock.withLock { reports.isEmpty ? nil : reports.removeFirst() }
    }

    /// Real time a negative assertion keeps watching after the barrier
    /// (conformance.md §4b, at least 200 ms).
    static let quietWindow: Duration = .milliseconds(250)

    /// Lets the session finish whatever it can do without time passing or
    /// new datagrams (the barrier of conformance.md §4b).
    private func settle() async {
        for _ in 0..<6 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    // MARK: - Steps

    private func perform(_ step: JSON) async throws {
        if let call = step["call"]?.stringValue {
            try startCall(call, step: step)
        } else if let name = step["await"]?.stringValue {
            guard let task = calls[name] else { throw SuiteError("no call named \(name)") }
            let result = try await awaitWithDeadline(task, name: name)
            let expected = Operations.normalizeExpected(step["result"] ?? .null)
            if let diff = expected.firstDifference(from: result) {
                throw SuiteError("\(name) returned \(result), expected \(expected) (differs at \(diff))")
            }
        } else if let body = step["expectSent"] {
            await settle()
            guard let (socket, datagram) = await transport.nextSent() else { throw SuiteError("nothing was sent") }
            guard let plaintext = cipher.decrypt(datagram), let frame = String(data: plaintext, encoding: .utf8),
                  frame.hasPrefix("req::") else {
                throw SuiteError("sent datagram is not a request frame")
            }
            let rest = frame.dropFirst("req::".count)
            guard let colon = rest.firstIndex(of: ":") else { throw SuiteError("sent frame \(frame) has no msg_id") }
            let msgId = String(rest[..<colon]), payload = String(rest[rest.index(after: colon)...])
            try bind(socket: body.field("socket"), to: socket)
            try match(msgId: body.field("msgId"), observed: msgId)
            let expectedPayload = try body.field("payload")
            guard payload == expectedPayload else {
                throw SuiteError("sent payload \(payload), expected \(expectedPayload)")
            }
        } else if step["expectQuiet"] != nil {
            await settle()
            if let extra = await transport.nextSent(wait: Self.quietWindow) {
                let text = cipher.decrypt(extra.datagram).flatMap { String(data: $0, encoding: .utf8) }
                throw SuiteError("expected nothing sent, but the session sent \(text ?? "an undecryptable datagram")")
            }
        } else if let body = step["respond"] {
            let socket = try labeled(body.field("socket"))
            var msgId = try resolve(msgId: body.field("msgId"))
            if body["upper"]?.boolValue == true { msgId = msgId.uppercased() }
            let frame = "resp:\(cluIp):\(msgId):\(try body.field("payload"))"
            socket.deliver(try cipher.encrypt(Data(frame.utf8)))
            await settle()
        } else if let body = step["deliver"] {
            let socket = try labeled(body.field("socket"))
            let frame = Data(try body.field("frame").utf8)
            guard let encrypted = body["encrypted"]?.boolValue else { throw SuiteError("deliver needs encrypted") }
            socket.deliver(encrypted ? try cipher.encrypt(frame) : frame)
            await settle()
        } else if let milliseconds = step["advance"]?.intValue {
            await settle()
            clock.advance(by: .milliseconds(milliseconds))
            await settle()
        } else if let expected = step["expectState"]?.stringValue {
            await settle()
            let state = "\(await session.state)"
            guard state == expected else { throw SuiteError("state is \(state), expected \(expected)") }
        } else if let body = step["expectReport"] {
            guard let report = await takeReport() else { throw SuiteError("no report arrived") }
            let observed = JSON.object(["keys": .array(report.keys.map(Self.key)),
                                        "values": .array(report.slots.map(Self.slot))])
            let expected = Operations.normalizeExpected(body)
            if let diff = expected.firstDifference(from: observed) {
                throw SuiteError("report \(observed) differs from \(expected) at \(diff)")
            }
        } else if step["expectNoReport"] != nil {
            await settle()
            if let report = await takeReport(wait: Self.quietWindow) {
                throw SuiteError("unexpected report for \(report.keys.count) key(s)")
            }
        } else if let label = step["expectClosed"]?.stringValue {
            await settle()
            guard try labeled(label).isClosed else { throw SuiteError("socket \(label) is still open") }
        } else if let label = step["fail"]?.stringValue {
            try labeled(label).fail()
            await settle()
        } else {
            throw SuiteError("unknown step \(step)")
        }
    }

    private func startCall(_ call: String, step: JSON) throws {
        guard let name = step["as"]?.stringValue, calls[name] == nil else { throw SuiteError("call needs a new name") }
        let session = self.session
        switch call {
        case "start":
            calls[name] = Task { await session.start(); return .null }
        case "stop":
            calls[name] = Task { await session.stop(); return .null }
        case "ping":
            calls[name] = Task { .object(["ok": .bool(await session.ping())]) }
        case "register":
            guard let keyList = step["keys"]?.arrayValue else { throw SuiteError("register needs keys") }
            let keys = try keyList.map(Self.valueRef)
            calls[name] = Task { .object(["slots": .array(await session.register(keys).map(Self.slot))]) }
        case "execute":
            guard let actionJSON = step["action"] else { throw SuiteError("execute needs an action") }
            let action = try ActionRef(dto: JSONDecoder().decode(ActionRefDTO.self, from: actionJSON.data()))
            calls[name] = Task {
                do {
                    try await session.execute(action)
                    return .object(["ok": .bool(true)])
                } catch {
                    return .object(["error": .string(Self.errorCode(error))])
                }
            }
        default:
            throw SuiteError("unknown call \(call)")
        }
    }

    private func awaitWithDeadline(_ task: Task<JSON, Never>, name: String) async throws -> JSON {
        let timeout = Task { try await Task.sleep(for: .seconds(3)); task.cancel() }
        let result = await task.value
        timeout.cancel()
        if task.isCancelled { throw SuiteError("\(name) did not finish") }
        return result
    }

    // MARK: - Labels and captures

    private func bind(socket label: String, to socket: ScriptedSocket) throws {
        if let bound = labels[label] {
            guard bound === socket else { throw SuiteError("\(label) is socket #\(bound.serial), but this came from #\(socket.serial)") }
        } else {
            if let other = labels.first(where: { $0.value === socket }) {
                throw SuiteError("\(label) must be a new socket, but this is \(other.key)")
            }
            labels[label] = socket
        }
    }

    private func labeled(_ label: String) throws -> ScriptedSocket {
        guard let socket = labels[label] else { throw SuiteError("socket \(label) is not bound") }
        return socket
    }

    private func match(msgId expected: String, observed: String) throws {
        if expected.hasPrefix("$") {
            if let bound = captures[expected] {
                guard bound == observed else { throw SuiteError("\(expected) was \(bound), now \(observed)") }
            } else {
                captures[expected] = observed
            }
        } else if expected != observed {
            throw SuiteError("msg_id \(observed), expected \(expected)")
        }
    }

    private func resolve(msgId: String) throws -> String {
        guard msgId.hasPrefix("$") else { return msgId }
        guard let value = captures[msgId] else { throw SuiteError("\(msgId) is not captured") }
        return value
    }

    // MARK: - Projections

    static func valueRef(_ key: JSON) throws -> ValueRef {
        switch key["type"]?.stringValue {
        case "variable":
            return .variable(cluId: "CLU", name: try key.field("name"))
        case "attribute":
            return .attribute(cluId: "CLU", objectName: try key.field("objectName"), index: try key.field("index"))
        default:
            throw SuiteError("bad key \(key)")
        }
    }

    static func key(_ ref: ValueRef) -> JSON {
        switch ref {
        case .variable(_, let name):
            return .object(["type": "variable", "name": .string(name)])
        case .attribute(_, let objectName, let index):
            return .object(["type": "attribute", "objectName": .string(objectName), "index": .string(index)])
        }
    }

    static func slot(_ slot: RegistrationSlot) -> JSON {
        switch slot {
        case .failed: return .object(["failed": .bool(true)])
        case .value(let value): return Operations.tagged(value)
        }
    }

    static func errorCode(_ error: any Error) -> String {
        switch error {
        case SessionError.timeout: return "session.timeout"
        case SessionError.notConnected: return "session.notConnected"
        case SessionError.connectionClosed: return "session.connectionClosed"
        case PayloadError.unresolvedPlaceholder: return "payload.unresolvedPlaceholder"
        default: return "unmapped: \(error)"
        }
    }
}

private extension JSON {
    /// A required string field of a step; a missing one is a runner failure.
    func field(_ key: String) throws -> String {
        guard let value = self[key]?.stringValue else { throw SuiteError("step field `\(key)` missing in \(self)") }
        return value
    }
}
