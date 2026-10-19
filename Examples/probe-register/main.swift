import Foundation
import GrentonModel
import GrentonProvisioning
import GrentonRuntime
import GrentonDevices

/// Research probe: what do the three leading arguments of `clientRegister`
/// mean, and does `clientDestroy` exist in the mobile form?
///
///     swift run probe-register <interface.zip> <clu-id> <watched-object> [seconds-per-phase] [host-ip] [--phases A,B,…]
///
/// Hypothesis under test: `SYSTEM:clientRegister(ip, port, session, {keys})`,
/// where `ip = 0, port = 0` means "report to the sender's address and port",
/// and `session` is echoed as `clientReport:<session>:`. The spec (§5.3.2)
/// currently calls the second argument `sessionId` and treats the first and
/// third as unexplained constants.
///
/// Every phase opens fresh sockets, registers the watched object's key
/// first plus up to 29 other keys of the CLU in one form, and counts the
/// pushes (`msg_id 00000000`) that arrive on each socket. Pushes only come
/// when a value changes, so during each phase toggle the watched object (a
/// light on this CLU) a few times, from a wall switch or the myGrenton app.
/// Its value is always position #0.
///
/// Read-only: the probe sends only pings, registrations and `clientDestroy`,
/// never an action. Run it from Terminal.app (Local Network access).

// Line-buffered output, so progress shows up live even through `| tee`.
setvbuf(stdout, nil, _IOLBF, 0)

// Flags: `--phases E,H` runs only those phases; `--extra OBJ:IDX,…` adds
// keys outside the interface; `--scan` turns the watched argument into
// `OBJ:FROM-TO` and only reads those features. The rest are positional.
var arguments = CommandLine.arguments
@MainActor func takeFlag(_ name: String, hasValue: Bool = true) -> String? {
    guard let flag = arguments.firstIndex(of: name) else { return nil }
    if !hasValue { arguments.remove(at: flag); return "" }
    guard flag + 1 < arguments.count else { return nil }
    let value = arguments[flag + 1]
    arguments.removeSubrange(flag...(flag + 1))
    return value
}
let selectedPhases = takeFlag("--phases").map { Set($0.uppercased().split(separator: ",").map(String.init)) }
let extraSpec = takeFlag("--extra")
let scanMode = takeFlag("--scan", hasValue: false) != nil
guard arguments.count >= 4 else {
    print("""
        usage: probe-register <interface.zip> <clu> <watched> [seconds-per-phase] [host-ip] [--phases A,B,…] [--extra OBJ:IDX,…]
               probe-register <interface.zip> <clu> <OBJ:FROM-TO> --scan
          <clu>     a CLU id or name from the interface, or <object-name>@<ip> for one outside it
          <watched> an object or variable of the interface (its first key), or OBJ:IDX for any feature
        """)
    exit(2)
}
let phaseSeconds = arguments.count > 4 ? Int(arguments[4]) ?? 30 : 30

let interface = try ProvisioningClient.parseInterfaceArchive(
    Data(contentsOf: URL(fileURLWithPath: arguments[1])))

/// The CLU under test: from the interface, or `<object-name>@<ip>`.
struct Target: Sendable {
    let id: String
    let ip: String
    let port: Int
}
let clu: Target
if let dto = interface.clus.first(where: { $0.id == arguments[2] || $0.name == arguments[2] }) {
    clu = Target(id: dto.id, ip: dto.ip, port: dto.port)
} else if let at = arguments[2].firstIndex(of: "@") {
    clu = Target(id: String(arguments[2][..<at]), ip: String(arguments[2][arguments[2].index(after: at)...]), port: 1234)
} else {
    print("no CLU \(arguments[2]); the interface has: "
          + interface.clus.map { "\($0.id) (\($0.name))" }.joined(separator: ", ")
          + "; for another CLU pass <object-name>@<ip>")
    exit(2)
}
let cipher = try AesCbcCipher(encryption: interface.encryption)

/// `OBJ:IDX` as an attribute of the CLU under test.
@MainActor func attribute(_ spec: Substring) -> ValueRef? {
    let parts = spec.split(separator: ":")
    guard parts.count == 2 else { return nil }
    return .attribute(cluId: clu.id, objectName: String(parts[0]), index: String(parts[1]))
}

// The keys the library would register for this CLU, in interface order.
var cluKeys: [ValueRef] = []
for device in DeviceMapper.descriptors(for: interface) {
    for entity in device.entities {
        for ref in entity.stateRefs where !cluKeys.contains(ref) {
            switch ref {
            case .variable(let cluId, _), .attribute(let cluId, _, _):
                if cluId == clu.id { cluKeys.append(ref) }
            }
        }
    }
}
for spec in (extraSpec ?? "").split(separator: ",") {
    guard let ref = attribute(spec) else {
        print("bad --extra key \(spec); use OBJ:IDX")
        exit(2)
    }
    if !cluKeys.contains(ref) { cluKeys.append(ref) }
}

let watched: ValueRef
if scanMode {
    watched = .attribute(cluId: clu.id, objectName: "-", index: "0")   // unused
} else if arguments[3].contains(":") {
    guard let ref = attribute(Substring(arguments[3])) else {
        print("bad watched key \(arguments[3]); use OBJ or OBJ:IDX")
        exit(2)
    }
    watched = ref
} else if let ref = cluKeys.first(where: {
    switch $0 {
    case .attribute(_, let objectName, _): return objectName == arguments[3]
    case .variable(_, let name): return name == arguments[3]
    }
}) {
    watched = ref
} else {
    print("no key of object \(arguments[3]) on CLU \(clu.id); pass OBJ:IDX")
    exit(2)
}
// One registration stays at 30 keys (spec §5.3.2); larger ones may get no reply.
let others = Array(cluKeys.filter { $0 != watched }.prefix(29))
guard scanMode || others.count >= 2 else {
    print("CLU \(clu.id) has \(others.count) other key(s); add some with --extra OBJ:IDX,…")
    exit(2)
}
func render(_ refs: [ValueRef]) -> String {
    "{" + refs.map(\.wireSubscriptionKey).joined(separator: ",") + "}"
}
let keys = [watched] + others
let renderedKeys = render(keys)
// Both halves start with the watched key, so a toggle changes #0 in each.
let half = others.count / 2
let firstHalfKeys = [watched] + others[..<half]
let secondHalfKeys = [watched] + others[half...]
let firstHalf = render(firstHalfKeys)
let secondHalf = render(secondHalfKeys)

/// The local IPv4 address the OS would use to reach `host` (no packet is sent).
func localAddress(towards host: String, port: Int) -> String? {
    let fd = socket(AF_INET, SOCK_DGRAM, 0)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    var peer = sockaddr_in()
    peer.sin_family = sa_family_t(AF_INET)
    peer.sin_port = UInt16(port).bigEndian
    guard inet_pton(AF_INET, host, &peer.sin_addr) == 1 else { return nil }
    let connected = withUnsafePointer(to: &peer) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    guard connected == 0 else { return nil }
    var local = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let named = withUnsafeMutablePointer(to: &local) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
    }
    guard named == 0 else { return nil }
    return String(cString: inet_ntoa(local.sin_addr))
}
guard let hostIp = arguments.count > 5 ? arguments[5] : localAddress(towards: clu.ip, port: clu.port) else {
    print("cannot find this Mac's address towards \(clu.ip); pass it as the fifth argument")
    exit(2)
}

// MARK: - Frames

struct Frame: Sendable {
    let phase: String
    let socket: String
    let response: WireResponse
    let report: ClientReport?
    let at: ContinuousClock.Instant
}

/// Every decrypted frame, from every socket, in arrival order.
actor Recorder {
    private(set) var frames: [Frame] = []
    var phase = "-"
    // Last values per socket and session, to show which positions a push changed.
    private var last: [String: [GrentonValue]] = [:]

    func setPhase(_ name: String) { phase = name }

    func record(socket: String, response: WireResponse) {
        let report = Payloads.parseClientReport(response.payload)
        let frame = Frame(phase: phase, socket: socket, response: response, report: report, at: .now)
        frames.append(frame)
        guard let report else { return }
        let slot = "\(socket)/\(report.sessionId)"
        let previous = last[slot]
        last[slot] = report.values
        if response.isNotification {
            var changed = "no previous values"
            if let previous, previous.count == report.values.count {
                let positions = report.values.indices.filter { report.values[$0] != previous[$0] }
                changed = positions.isEmpty ? "nothing changed"
                    : "changed " + positions.map { "#\($0) → \(report.values[$0])" }.joined(separator: ", ")
            }
            print("    ← push on \(socket): clientReport:\(report.sessionId), \(report.values.count) value(s), \(changed)")
        }
    }

    func reply(to msgId: String) -> WireResponse? {
        frames.last { $0.response.msgId == msgId }?.response
    }

    func pushes(phase: String) -> [Frame] {
        frames.filter { $0.phase == phase && $0.response.isNotification }
    }
}
let recorder = Recorder()

/// An unconnected socket whose every frame goes to the recorder under `label`.
struct ProbeSocket {
    let label: String
    let socket: any UdpSocket
    let reader: Task<Void, Never>
    let cipher: AesCbcCipher
    let recorder: Recorder
    var port: Int { socket.localPort ?? 0 }

    static func open(_ label: String, to clu: Target, cipher: AesCbcCipher, recorder: Recorder) async throws -> ProbeSocket {
        let socket = try await AnySourceUdpSocketFactory().open(host: clu.ip, port: clu.port)
        let reader = Task {
            for await datagram in socket.incoming {
                guard let plain = cipher.decrypt(datagram),
                      let text = String(data: plain, encoding: .utf8),
                      let response = WireFrame.parseResponse(text.trimmingCharacters(in: .whitespacesAndNewlines))
                else { continue }
                await recorder.record(socket: label, response: response)
            }
        }
        return ProbeSocket(label: label, socket: socket, reader: reader, cipher: cipher, recorder: recorder)
    }

    /// Sends `payload` and waits up to 5 s for the reply with the same msg_id.
    func request(_ payload: String, quiet: Bool = false) async -> WireResponse? {
        let msgId = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
        let frame = WireFrame.request(msgId: msgId, payload: payload)
        if !quiet { print("    → \(label): \(payload.count > 90 ? String(payload.prefix(90)) + "…" : payload)") }
        do {
            try await socket.send(cipher.encrypt(Data(frame.utf8)))
        } catch {
            print("    ✗ send failed: \(error)")
            return nil
        }
        for _ in 0..<100 {
            if let reply = await recorder.reply(to: msgId) {
                if !quiet { print("    ← \(label) reply: \(reply.payload.count > 90 ? String(reply.payload.prefix(90)) + "…" : reply.payload)") }
                return reply
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        if !quiet { print("    ✗ no reply within 5 s") }
        return nil
    }

    func close() {
        socket.close()
        reader.cancel()
    }
}

// MARK: - Phases

func openSocket(_ label: String) async throws -> ProbeSocket {
    try await ProbeSocket.open(label, to: clu, cipher: cipher, recorder: recorder)
}

print("""
    CLU \(clu.id) at \(clu.ip):\(clu.port), this Mac \(hostIp)
    \(keys.count) key(s), \(phaseSeconds) s per phase.
    During each phase, toggle \(arguments[3]) a few times; it is position #0.

    """)

// Pings keep the CLU-side client alive (spec §5.3.1). They come from their
// own socket, so they never count as a registration's socket.
let pinger = try await openSocket("ping")
guard await pinger.request(Payloads.checkAlive) != nil else {
    print("the CLU does not answer checkAlive; check the network and Local Network access")
    exit(1)
}
/// Pings every 5 s from `socket`; nil stops pinging.
var pingLoop: Task<Void, Never>?
@MainActor func pingEvery5s(from socket: ProbeSocket?) {
    pingLoop?.cancel()
    pingLoop = socket.map { socket in
        Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                let msgId = (0..<4).map { _ in String(format: "%02x", UInt8.random(in: .min ... .max)) }.joined()
                try? await socket.socket.send(socket.cipher.encrypt(Data(WireFrame.request(msgId: msgId, payload: Payloads.checkAlive).utf8)))
            }
        }
    }
}
pingEvery5s(from: pinger)

// --scan: read features FROM…TO of one object, one registration each, twice
// 5 s apart, so ticking features show up. Then stop.
if scanMode {
    let parts = arguments[3].split(separator: ":")
    let bounds = parts.count == 2 ? parts[1].split(separator: "-").compactMap { Int($0) } : []
    guard bounds.count == 2, bounds[0] <= bounds[1] else {
        print("scan wants OBJ:FROM-TO, e.g. \(clu.id):0-20")
        exit(2)
    }
    let object = String(parts[0])
    let r = try await openSocket("R")
    var first: [Int: String] = [:]
    for round in 1...2 {
        print("\nscan round \(round)")
        for index in bounds[0]...bounds[1] {
            let reply = await r.request("SYSTEM:clientRegister(0,0,1,{{\(object),\(index)}})")
            let value = reply.flatMap { Payloads.parseClientReport($0.payload)?.values.first }.map { "\($0)" } ?? "no value"
            if round == 1 { first[index] = value }
            else { print("    \(object):\(index) = \(value)\(first[index] != value ? "   ← changed" : "")") }
        }
        if round == 1 { try? await Task.sleep(for: .seconds(5)) }
    }
    _ = await r.request("SYSTEM:clientDestroy(0,0,1)")
    r.close()
    exit(0)
}

struct Outcome {
    let phase: String
    let question: String
    let result: String
}
var outcomes: [Outcome] = []

func countByLabel(_ frames: [Frame]) -> String {
    let counts = Dictionary(grouping: frames, by: \.socket).mapValues(\.count)
    guard !counts.isEmpty else { return "no pushes" }
    return counts.sorted { $0.key < $1.key }.map { "\($0.value) on \($0.key)" }.joined(separator: ", ")
}

func sessions(_ frames: [Frame]) -> String {
    let ids = Set(frames.compactMap { $0.report?.sessionId }).sorted()
    return ids.isEmpty ? "-" : ids.map(String.init).joined(separator: ",")
}

func listen(_ phase: String, seconds: Int) async {
    print("    … listening \(seconds) s, toggle the watched object now")
    try? await Task.sleep(for: .seconds(seconds))
}

/// Starts `phase` when it is selected; false skips it.
@MainActor func begin(_ phase: String, _ title: String) async -> Bool {
    if let selectedPhases, !selectedPhases.contains(phase) { return false }
    await recorder.setPhase(phase)
    print("\n[\(phase)] \(title)")
    return true
}

// A — baseline, the form the library sends today.
if await begin("A", "clientRegister(0,0,1,…) from R") {
    let r = try await openSocket("R")
    let ack = await r.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    await listen("A", seconds: phaseSeconds)
    let pushes = await recorder.pushes(phase: "A")
    outcomes.append(Outcome(phase: "A", question: "baseline: pushes to R?",
        result: "ack session \(ack.flatMap { Payloads.parseClientReport($0.payload)?.sessionId }.map(String.init) ?? "none"); \(countByLabel(pushes)); push sessions \(sessions(pushes))"))
    r.close()
}

// B — second argument = the port of ANOTHER socket, L, which never sends.
if await begin("B", "clientRegister(0,<port of L>,1,…) from R") {
    let r = try await openSocket("R")
    let l = try await openSocket("L")
    _ = await r.request("SYSTEM:clientRegister(0,\(l.port),1,\(renderedKeys))")
    await listen("B", seconds: phaseSeconds)
    outcomes.append(Outcome(phase: "B", question: "2nd arg = report port? (expect pushes on L)",
        result: countByLabel(await recorder.pushes(phase: "B"))))
    r.close(); l.close()
}

// B2 — second argument = R's own port: the bisect saw no pushes here.
if await begin("B2", "clientRegister(0,<port of R>,1,…) from R") {
    let r = try await openSocket("R")
    _ = await r.request("SYSTEM:clientRegister(0,\(r.port),1,\(renderedKeys))")
    await listen("B2", seconds: phaseSeconds)
    outcomes.append(Outcome(phase: "B2", question: "2nd arg = own port (bisect: none)",
        result: countByLabel(await recorder.pushes(phase: "B2"))))
    r.close()
}

// C — the Object Manager form: explicit IP and report port.
if await begin("C", "clientRegister(\"\(hostIp)\",<port of L>,1,…) from R") {
    let r = try await openSocket("R")
    let l = try await openSocket("L")
    _ = await r.request("SYSTEM:clientRegister(\"\(hostIp)\",\(l.port),1,\(renderedKeys))")
    await listen("C", seconds: phaseSeconds)
    outcomes.append(Outcome(phase: "C", question: "1st arg = client IP? (expect pushes on L)",
        result: countByLabel(await recorder.pushes(phase: "C"))))
    r.close(); l.close()
}

// D — third argument 2: is it echoed in clientReport?
if await begin("D", "clientRegister(0,0,2,…) from R") {
    let r = try await openSocket("R")
    let ack = await r.request("SYSTEM:clientRegister(0,0,2,\(renderedKeys))")
    await listen("D", seconds: phaseSeconds)
    let pushes = await recorder.pushes(phase: "D")
    outcomes.append(Outcome(phase: "D", question: "3rd arg = session? (expect clientReport:2)",
        result: "ack session \(ack.flatMap { Payloads.parseClientReport($0.payload)?.sessionId }.map(String.init) ?? "none"); \(countByLabel(pushes)); push sessions \(sessions(pushes))"))
    r.close()
}

// E — two sessions with different keys on ONE socket.
if await begin("E", "sessions 1 (\(firstHalfKeys.count) keys) and 2 (\(secondHalfKeys.count) keys) on R") {
    let r = try await openSocket("R")
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(firstHalf))")
    _ = await r.request("SYSTEM:clientRegister(0,0,2,\(secondHalf))")
    await listen("E", seconds: phaseSeconds)
    let pushes = await recorder.pushes(phase: "E")
    let shapes = Set(pushes.compactMap { f in f.report.map { "session \($0.sessionId): \($0.values.count) values" } })
    outcomes.append(Outcome(phase: "E", question: "several sessions per socket? (expect both shapes)",
        result: "\(countByLabel(pushes)); \(shapes.isEmpty ? "-" : shapes.sorted().joined(separator: "; "))"))
    r.close()
}

// F — does the same triple replace the registration, and does the mobile
// form of clientDestroy stop the pushes?
if await begin("F", "register (0,0,1) twice, then clientDestroy(0,0,1), on R") {
    let r = try await openSocket("R")
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(firstHalf))")
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(secondHalf))")
    await listen("F", seconds: phaseSeconds / 2)
    let beforeDestroy = await recorder.pushes(phase: "F")
    let shapes = Set(beforeDestroy.compactMap { $0.report?.values.count }).sorted()
    let destroyReply = await r.request("SYSTEM:clientDestroy(0,0,1)")
    await recorder.setPhase("F-after")
    await listen("F-after", seconds: phaseSeconds / 2)
    outcomes.append(Outcome(phase: "F", question: "same triple replaces? (expect only \(secondHalfKeys.count)-value pushes)",
        result: "\(countByLabel(beforeDestroy)); value counts \(shapes.map(String.init).joined(separator: ","))"))
    outcomes.append(Outcome(phase: "F", question: "clientDestroy(0,0,1) stops pushes?",
        result: "reply \(destroyReply?.payload ?? "none"); after: \(countByLabel(await recorder.pushes(phase: "F-after")))"))
    r.close()
}

// G — the Object Manager form of clientDestroy.
if await begin("G", "register (\"\(hostIp)\",<port of L>,1), then clientDestroy with the same triple") {
    let r = try await openSocket("R")
    let l = try await openSocket("L")
    _ = await r.request("SYSTEM:clientRegister(\"\(hostIp)\",\(l.port),1,\(renderedKeys))")
    await listen("G", seconds: phaseSeconds / 2)
    let beforeDestroy = await recorder.pushes(phase: "G")
    let destroyReply = await r.request("SYSTEM:clientDestroy(\"\(hostIp)\",\(l.port),1)")
    await recorder.setPhase("G-after")
    await listen("G-after", seconds: phaseSeconds / 2)
    outcomes.append(Outcome(phase: "G", question: "OM-form clientDestroy stops pushes?",
        result: "before: \(countByLabel(beforeDestroy)); reply \(destroyReply?.payload ?? "none"); after: \(countByLabel(await recorder.pushes(phase: "G-after")))"))
    r.close(); l.close()
}

// H — a re-registration from a NEW socket while the old one stays open:
// does the CLU keep pushing to the old socket too?
if await begin("H", "register (0,0,1) from R1, then the same from R2 with R1 still open") {
    let r1 = try await openSocket("R1")
    _ = await r1.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    let r2 = try await openSocket("R2")
    _ = await r2.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    await listen("H", seconds: phaseSeconds)
    outcomes.append(Outcome(phase: "H", question: "old socket keeps its registration? (pushes on R1 too)",
        result: countByLabel(await recorder.pushes(phase: "H"))))
    _ = await r1.request("SYSTEM:clientDestroy(0,0,1)")
    _ = await r2.request("SYSTEM:clientDestroy(0,0,1)")
    r1.close(); r2.close()
}

// L — the largest registration the CLU answers, in keys and in bytes.
// Three series with keys of different lengths: if the limit is in bytes,
// the largest datagram is about the same in each series while the key
// count differs. Read-only, nothing to toggle.
if await begin("L", "largest registration the CLU answers") {
    let r = try await openSocket("R")
    /// One registration of `refs`: answered with exactly one value per key?
    func fits(_ refs: [ValueRef]) async -> (ok: Bool, plain: Int, datagram: Int, reply: Int) {
        let payload = "SYSTEM:clientRegister(0,0,1,\(render(refs)))"
        let plain = WireFrame.request(msgId: "00000000", payload: payload).utf8.count
        let datagram = (plain / 16 + 1) * 16   // AES-CBC with PKCS#7 padding
        // A lost datagram looks like a refusal, so a miss is retried once.
        for _ in 0..<2 {
            if let reply = await r.request(payload, quiet: true),
               let report = Payloads.parseClientReport(reply.payload), report.values.count == refs.count {
                return (true, plain, datagram, reply.payload.utf8.count)
            }
        }
        return (false, plain, datagram, 0)
    }
    func largest(_ name: String, _ pool: [ValueRef]) async -> String {
        print("    series \(name): \(pool.count) keys available")
        var lo = 0, hi = pool.count   // pool[..<lo] fits; pool[..<(hi + 1)] does not
        let all = await fits(pool)
        if all.ok { return "\(name): all \(pool.count) keys fit (\(all.datagram) B datagram)" }
        while lo < hi - 1 {
            let mid = (lo + hi) / 2
            let attempt = await fits(Array(pool[..<mid]))
            print("      \(mid) keys, \(attempt.datagram) B datagram: \(attempt.ok ? "answered" : "no reply")")
            if attempt.ok { lo = mid } else { hi = mid }
        }
        let good = await fits(Array(pool[..<lo]))
        let bad = await fits(Array(pool[..<hi]))
        return "\(name): largest \(lo) keys = \(good.plain) B plain / \(good.datagram) B datagram (reply \(good.reply) B); "
            + "\(hi) keys = \(bad.plain) B / \(bad.datagram) B \(bad.ok ? "answered on recheck" : "no reply")"
    }
    // Repeat a key until the pool is clearly past any plausible limit.
    func repeated(_ ref: ValueRef, count: Int) -> [ValueRef] { Array(repeating: ref, count: count) }
    let byLength = cluKeys.sorted { $0.wireSubscriptionKey.count > $1.wireSubscriptionKey.count }
    let shortest = byLength.last ?? watched
    let longest = byLength.first ?? watched
    let probeDuplicate = await fits(repeated(shortest, count: 2))
    print("    duplicate keys in one registration: \(probeDuplicate.ok ? "accepted" : "refused")")
    var results: [String] = []
    if probeDuplicate.ok {
        results.append(await largest("short key \(shortest.wireSubscriptionKey) ×N", repeated(shortest, count: 400)))
        results.append(await largest("long key \(longest.wireSubscriptionKey) ×N", repeated(longest, count: 400)))
    }
    results.append(await largest("interface keys in order", cluKeys))
    for result in results {
        print("    → \(result)")
        outcomes.append(Outcome(phase: "L", question: "largest registration", result: result))
    }
    _ = await r.request("SYSTEM:clientDestroy(0,0,1)", quiet: true)
    r.close()
}

// I1–I3 — how long a registration lives when it is never renewed. Pushes
// come from any changing value (a flapping temperature is enough); a
// registration counts as dead after `leaseQuiet` without a push. Each
// variant is capped at the phase time (at least 180 s).
let leaseQuiet: Duration = .seconds(120)

@MainActor func observeLease(_ phase: String, _ r: ProbeSocket) async -> String {
    let start = ContinuousClock.now
    let cap = Duration.seconds(max(phaseSeconds, 180))
    var lastReport = start
    print("    … observing up to \(cap), dead after \(leaseQuiet) without a push")
    while true {
        try? await Task.sleep(for: .seconds(5))
        let pushes = await recorder.pushes(phase: phase).filter { $0.socket == r.label }
        let now = ContinuousClock.now
        let last = pushes.last?.at
        if now - lastReport >= .seconds(60) {
            lastReport = now
            print("    t=\(Int((now - start).components.seconds)) s: \(pushes.count) push(es), last at t=\(last.map { String(Int(($0 - start).components.seconds)) } ?? "-") s")
        }
        let silence = now - (last ?? start)
        if silence >= leaseQuiet || now - start >= cap {
            let lastAt = last.map { "last push at t=\(Int(($0 - start).components.seconds)) s" } ?? "no push at all"
            let verdict = silence >= leaseQuiet ? "silent for \(Int(silence.components.seconds)) s" : "still pushing at the cap"
            return "\(pushes.count) push(es), \(lastAt), \(verdict)"
        }
    }
}

if await begin("I1", "lease without any ping from this Mac") {
    pingEvery5s(from: nil)
    let r = try await openSocket("R")
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    let result = await observeLease("I1", r)
    outcomes.append(Outcome(phase: "I1", question: "lives without pings?", result: result))
    _ = await r.request("SYSTEM:clientDestroy(0,0,1)")
    r.close()
    pingEvery5s(from: pinger)
}

if await begin("I2", "lease with pings from ANOTHER socket (the library's layout)") {
    pingEvery5s(from: pinger)
    let r = try await openSocket("R")
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    let result = await observeLease("I2", r)
    outcomes.append(Outcome(phase: "I2", question: "lives with pings from another socket?", result: result))
    _ = await r.request("SYSTEM:clientDestroy(0,0,1)")
    r.close()
}

if await begin("I3", "lease with pings from the registration socket itself") {
    let r = try await openSocket("R")
    pingEvery5s(from: r)
    _ = await r.request("SYSTEM:clientRegister(0,0,1,\(renderedKeys))")
    let result = await observeLease("I3", r)
    outcomes.append(Outcome(phase: "I3", question: "lives with pings from its own socket?", result: result))
    pingEvery5s(from: pinger)
    _ = await r.request("SYSTEM:clientDestroy(0,0,1)")
    r.close()
}

pingEvery5s(from: nil)
pinger.close()

print("\nSummary")
for outcome in outcomes {
    print("  \(outcome.phase.padding(toLength: 3, withPad: " ", startingAt: 0)) \(outcome.question)\n      \(outcome.result)")
}
let stray = await recorder.frames.filter { $0.response.isNotification && $0.socket == "ping" }.count
if stray > 0 { print("  note: \(stray) push(es) arrived on the ping socket") }
