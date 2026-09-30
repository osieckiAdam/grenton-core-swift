import Foundation
import GrentonModel

/// Opens the `any Clock<Duration>` existential — the protocol's
/// `sleep(until:tolerance:)` needs a concrete `Instant` type.
func sleepOn<C: Clock>(_ clock: C, for duration: C.Duration) async throws {
    try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
}

// One CLU's protocol session (spec §5.4): main socket for pings/actions,
// one dedicated socket per ≤30-key subscription chunk, request/response
// correlation with timeout, and report routing by socket.
//
// Concurrency model (Swift plan §4.4):
// - every socket has exactly ONE router task reading its `incoming`
//   stream; operations never read sockets directly — they await
//   continuations the router resumes;
// - every datagram is validated against the identity of its source
//   (main-socket generation / endpoint id) before it may resume a pending
//   request or publish a report — a stale router that already dequeued a
//   datagram cannot affect a restarted session or replaced subscription;
// - multi-step operations (`start`, `register`, `stop`) run behind a
//   cancellation-aware FIFO gate because actors are reentrant across
//   `await`; a caller cancelled while queued never runs its operation;
// - `stop()` fails pending requests and cancels in-flight socket opens
//   immediately (before taking the gate), so nothing drains slowly;
// - recovery from `degraded` re-registers the last desired subscription
//   set before the session becomes `ready` again (spec §5.4.5);
// - the maintenance loops (spec §5.4.4) run on the injected clock: a ping
//   every `pingInterval` after the previous loop ping ends, and a
//   re-registration `registerInterval` after ANY registration ends.
/// The connection to one CLU. `GrentonSystem` runs one per CLU; you rarely need it directly.
public actor CluSession {
    public let clu: Clu

    private let cipher: any GrentonCipher
    private let socketFactory: any UdpSocketFactory
    private let clock: any Clock<Duration>
    private let random: any RandomSource
    private let logger: GrentonLogger
    private let responseTimeout: Duration
    private let pingInterval: Duration
    private let registerInterval: Duration
    private let maxKeysPerRegister: Int

    /// Constant per session; every ping reuses it as its message id
    /// (spec §5.3.1).
    private let keepAliveId: String

    public private(set) var state: SessionState = .idle

    /// How long after the previous loop ping ends the next one is sent (spec §5.4.4).
    public static let defaultPingInterval: Duration = .seconds(5)
    /// How long after a registration ends the keys are registered again (spec §5.4.4).
    public static let defaultRegisterInterval: Duration = .seconds(45)

    // MARK: Main socket

    private var mainSocket: (any UdpSocket)?
    private var mainRouterTask: Task<Void, Never>?
    /// Bumped on every install; datagrams and close callbacks from an older
    /// generation are ignored.
    private var mainSocketGeneration = 0
    /// Single-flight guard for concurrent main-socket opens.
    private var mainOpenTask: Task<Void, Never>?

    // MARK: Subscription endpoints

    private struct Endpoint {
        let id: UUID
        let socket: any UdpSocket
        let keys: [ValueRef]
        let sessionId: Int
        var routerTask: Task<Void, Never>?
    }

    private var endpoints: [Endpoint] = []

    /// The last key set requested via `register` — recovery re-registers it.
    private var desiredKeys: [ValueRef] = []
    private var needsRecovery = false

    // MARK: Maintenance loops (spec §5.4.4)

    private var pingLoopTask: Task<Void, Never>?
    /// Sleeps until the next re-registration; replaced whenever a
    /// registration ends, so the interval counts from the latest one.
    private var registerLoopTask: Task<Void, Never>?

    // MARK: Correlation & subscribers

    private var pending: [String: CheckedContinuation<WireResponse, any Error>] = [:]
    private var reportSubscribers: [UUID: AsyncStream<ChunkReport>.Continuation] = [:]

    /// In-flight socket-factory opens, cancellable by `stop()`.
    private var activeOpens: [UUID: Task<any UdpSocket, any Error>] = [:]

    // MARK: Serialization gate

    private var operationInProgress = false
    private var waiterOrder: [UUID] = []
    private var waiterContinuations: [UUID: CheckedContinuation<Bool, Never>] = [:]

    public init(
        clu: Clu,
        cipher: any GrentonCipher,
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        clock: any Clock<Duration> = ContinuousClock(),
        random: any RandomSource = SystemRandomSource(),
        logger: GrentonLogger = .disabled,
        responseTimeout: Duration = .seconds(5),
        pingInterval: Duration = CluSession.defaultPingInterval,
        registerInterval: Duration = CluSession.defaultRegisterInterval,
        maxKeysPerRegister: Int = 30
    ) {
        self.clu = clu
        self.cipher = cipher
        self.socketFactory = socketFactory
        self.clock = clock
        self.random = random
        self.logger = logger
        self.responseTimeout = responseTimeout
        self.pingInterval = pingInterval
        self.registerInterval = registerInterval
        // At most 30 keys per request (spec §10 pt 4); at least one, or
        // chunking cannot advance.
        self.maxKeysPerRegister = min(max(maxKeysPerRegister, 1), 30)
        self.keepAliveId = random.messageId()
    }

    // MARK: - Lifecycle (spec §5.4.5)

    /// Idempotent. Opens the main socket, performs the initial ping and
    /// starts the ping loop. Failure is not fatal: the session ends up
    /// `degraded` and every later ping retries (including reopening the
    /// socket).
    public func start() async {
        guard await beginOperation() else { return }
        defer { endOperation() }
        guard state == .idle || state == .stopped else { return }
        state = .starting
        _ = await pingInternal(gateHeld: true)
        if state != .stopped { startPingLoop() }
    }

    /// Idempotent. After `stop()` the session may be started again
    /// (mobile background/foreground cycle); the desired subscription set
    /// is retained and restored on the next successful ping.
    public func stop() async {
        guard state != .stopped else { return }
        state = .stopped
        needsRecovery = !desiredKeys.isEmpty
        pingLoopTask?.cancel()
        pingLoopTask = nil
        registerLoopTask?.cancel()
        registerLoopTask = nil

        for (_, task) in activeOpens { task.cancel() }
        failAllPending(SessionError.connectionClosed)
        closeEndpoints()
        mainSocket?.close()
        mainSocket = nil
        mainRouterTask?.cancel()
        mainRouterTask = nil
        mainSocketGeneration += 1   // invalidate any stale router immediately

        // Drain any in-flight gated operation (its awaits just failed).
        await beginOperationUncancellable()
        endOperation()
    }

    // MARK: - Ping (spec §5.3.1, §5.4.4)

    @discardableResult
    public func ping() async -> Bool {
        await pingInternal(gateHeld: false)
    }

    private func pingInternal(gateHeld: Bool) async -> Bool {
        guard state != .stopped else { return false }

        // A ping is already in flight (they all share keepAliveId) — don't
        // race it and don't disturb the state it will set.
        guard pending[keepAliveId] == nil else { return false }

        if mainSocket == nil {
            // Degraded retry reopens the main socket first (spec §5.4.5).
            await ensureMainSocketOpen()
        }
        guard let socket = mainSocket else {
            if state != .stopped { state = .degraded; needsRecovery = needsRecovery || !desiredKeys.isEmpty }
            return false
        }
        // Recheck after the open await: a concurrent ping may have won the
        // race and already put its request in flight.
        guard pending[keepAliveId] == nil else { return false }
        do {
            _ = try await sendRequest(Payloads.checkAlive, msgId: keepAliveId, over: socket)
            guard state != .stopped else { return false }
            if needsRecovery && !desiredKeys.isEmpty {
                await recoverSubscriptions(gateHeld: gateHeld)
            }
            if state != .stopped { state = .ready }
            return true
        } catch {
            // A racing ping owns the in-flight request — let its outcome
            // decide the state.
            if case SessionError.duplicateMessageId = error { return false }
            // stop() cancelled it — not a CLU failure, and no reason to degrade.
            if error is CancellationError { return false }
            logger.warning("[\(clu.name)] Ping failed: \(error)")
            if state != .stopped { state = .degraded; needsRecovery = needsRecovery || !desiredKeys.isEmpty }
            return false
        }
    }

    /// Re-registers the desired key set after recovery; publishes the
    /// fresh initial values through the report pipeline so consumers
    /// resynchronise (spec §5.4.5).
    private func recoverSubscriptions(gateHeld: Bool) async {
        let keys = desiredKeys
        let slots: [RegistrationSlot]
        if gateHeld {
            slots = await registerLocked(keys)
        } else {
            guard await beginOperation() else { return }
            defer { endOperation() }
            slots = await registerLocked(keys)
        }
        scheduleReregistration()
        guard !slots.allSatisfy({ $0 == .failed }) else { return }
        // Partial failure keeps the flag — retried on the next ping.
        needsRecovery = slots.contains(.failed)
        publishReport(ChunkReport(keys: keys, slots: slots))
    }

    /// Single-flight main-socket open: concurrent callers share one attempt
    /// and exactly one socket gets installed.
    private func ensureMainSocketOpen() async {
        if mainSocket != nil { return }
        if let task = mainOpenTask {
            await task.value
            return
        }
        let task = Task { await self.openAndInstallMainSocket() }
        mainOpenTask = task
        await task.value
        mainOpenTask = nil
    }

    private func openAndInstallMainSocket() async {
        do {
            let socket = try await openTracked()
            guard state != .stopped, mainSocket == nil else {
                socket.close()
                return
            }
            mainSocket = socket
            mainSocketGeneration += 1
            mainRouterTask = makeRouter(
                for: socket, source: .main(generation: mainSocketGeneration))
            logger.debug("[\(clu.name)] Opened main UDP socket to \(clu.ip):\(clu.port)")
        } catch {
            logger.error("[\(clu.name)] Failed to open main UDP socket: \(error)")
        }
    }

    /// Factory open wrapped in a task `stop()` can cancel. Refuses to even
    /// begin once stopped — an open racing `stop()` must not slip past the
    /// cancellation sweep and hang untracked.
    private func openTracked() async throws -> any UdpSocket {
        guard state != .stopped else { throw SessionError.notConnected }
        let id = UUID()
        let task = Task { [socketFactory, clu] in
            try await socketFactory.open(host: clu.ip, port: clu.port)
        }
        activeOpens[id] = task
        defer { activeOpens[id] = nil }
        return try await task.value
    }

    // MARK: - Registration (spec §5.4.2)

    /// Replaces all subscriptions with `keys`, chunked at
    /// `maxKeysPerRegister` with one dedicated socket per chunk. Returns
    /// slots positionally aligned with `keys`; a failed chunk contributes
    /// `.failed` at its positions. A cancelled caller performs nothing and
    /// receives all-failed slots.
    public func register(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        guard await beginOperation() else { return keys.map { _ in .failed } }
        defer { endOperation() }
        desiredKeys = keys
        let slots = await registerLocked(keys)
        // Any failed position leaves the CLU with an incomplete lease —
        // the next successful ping must re-register (spec §5.4.5). A fully
        // clean registration clears the flag.
        needsRecovery = !keys.isEmpty && slots.contains(.failed)
        scheduleReregistration()
        return slots
    }

    // MARK: - Maintenance loops (spec §5.4.4)

    private func startPingLoop() {
        pingLoopTask?.cancel()
        pingLoopTask = Task { [weak self, clock, pingInterval] in
            while true {
                do { try await sleepOn(clock, for: pingInterval) } catch { return }
                guard let self, !Task.isCancelled, await self.isRunning else { return }
                // A lost ping is normal on UDP; the session degrades and
                // this loop keeps retrying (spec §5.4.4, §5.4.5).
                _ = await self.ping()
            }
        }
    }

    private var isRunning: Bool { state != .stopped }

    /// Re-registers `registerInterval` after the latest registration ends,
    /// while there are keys to renew.
    private func scheduleReregistration() {
        registerLoopTask?.cancel()
        registerLoopTask = nil
        guard state != .stopped, !desiredKeys.isEmpty else { return }
        registerLoopTask = Task { [weak self, clock, registerInterval] in
            do { try await sleepOn(clock, for: registerInterval) } catch { return }
            guard let self, !Task.isCancelled else { return }
            await self.reregister()
        }
    }

    /// Renews the lease and resynchronises every value; the values reach
    /// consumers through the report path, like a recovery (spec §5.4.4).
    private func reregister() async {
        guard await beginOperation() else { return }
        defer { endOperation() }
        guard state != .stopped, !desiredKeys.isEmpty else { return }
        let keys = desiredKeys
        let slots = await registerLocked(keys)
        needsRecovery = slots.contains(.failed)
        scheduleReregistration()
        guard !slots.allSatisfy({ $0 == .failed }) else { return }
        publishReport(ChunkReport(keys: keys, slots: slots))
    }

    /// Body of `register` — requires the operation gate to be held.
    private func registerLocked(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        guard state != .stopped else { return keys.map { _ in .failed } }
        closeEndpoints()
        guard !keys.isEmpty else { return [] }

        let chunks = stride(from: 0, to: keys.count, by: maxKeysPerRegister).map {
            Array(keys[$0..<min($0 + maxKeysPerRegister, keys.count)])
        }

        // One chunk at a time (spec §5.4.2). With all chunks in flight at
        // once, the two CLUs that need 4–5 chunks timed out on some of them
        // in every live run, while single-chunk CLUs never did; sequential
        // registration removed every timeout (live, 2026-09-30).
        var results: [RegistrationSlot] = []
        for chunk in chunks {
            results += await setupChunk(chunk)
        }
        return results
    }

    private func setupChunk(_ chunk: [ValueRef]) async -> [RegistrationSlot] {
        let failed = chunk.map { _ in RegistrationSlot.failed }
        guard state != .stopped else { return failed }

        let socket: any UdpSocket
        do {
            socket = try await openTracked()
        } catch {
            logger.error("[\(clu.name)] Failed to open subscription socket: \(error)")
            return failed
        }
        guard state != .stopped else {
            socket.close()
            return failed
        }
        // The second clientRegister argument must be 0: with any non-zero
        // value (bound port, random, 1, 5) the CLUs never pushed a single
        // clientReport; with 0 they push on every change, to the
        // registering socket (bisected live 2026-09-27; spec §5.3.2).
        let sessionId = 0

        let endpointId = UUID()
        var endpoint = Endpoint(
            id: endpointId, socket: socket, keys: chunk, sessionId: sessionId, routerTask: nil)
        endpoint.routerTask = makeRouter(for: socket, source: .endpoint(id: endpointId))
        endpoints.append(endpoint)
        logger.debug("[\(clu.name)] Opened subscription socket sid=\(sessionId) for \(chunk.count) key(s)")

        do {
            let payload = try Payloads.clientRegister(sessionId: sessionId, keys: chunk)
            let response = try await sendRequest(
                payload, msgId: random.messageId(), over: socket)
            guard let report = Payloads.parseClientReport(response.payload),
                  report.values.count == chunk.count
            else {
                logger.error("[\(clu.name)] Malformed register response (sid=\(sessionId))")
                return failed
            }
            return report.values.map(RegistrationSlot.value)
        } catch is CancellationError {
            return failed   // stop() cancelled it — not a CLU failure
        } catch {
            logger.warning("[\(clu.name)] Registration failed (sid=\(sessionId)): \(error)")
            return failed
        }
    }

    // MARK: - Actions (spec §5.3.4)

    public func execute(_ action: ActionRef) async throws {
        guard state != .stopped, let socket = mainSocket else {
            throw SessionError.notConnected
        }
        _ = try await sendRequest(
            try Payloads.action(action), msgId: random.messageId(), over: socket)
    }

    // MARK: - Reports

    /// A NEW stream per call (multi-subscriber, Swift plan §4.5). Streams
    /// stay open across stop/start cycles; they just idle while stopped.
    public func reports() -> AsyncStream<ChunkReport> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            reportSubscribers[id] = continuation
            continuation.onTermination = { _ in
                Task { await self.removeReportSubscriber(id) }
            }
        }
    }

    private func removeReportSubscriber(_ id: UUID) {
        reportSubscribers[id] = nil
    }

    private func publishReport(_ report: ChunkReport) {
        for sink in reportSubscribers.values {
            sink.yield(report)
        }
    }

    // MARK: - Request/response core (spec §5.4.1)

    /// Identity of the socket a datagram arrived on; validated before the
    /// datagram may touch `pending` or publish reports.
    private enum DatagramSource: Equatable {
        case main(generation: Int)
        case endpoint(id: UUID)
    }

    private func sendRequest(
        _ payload: String,
        msgId: String,
        over socket: any UdpSocket
    ) async throws -> WireResponse {
        let id = msgId.lowercased()
        guard pending[id] == nil else { throw SessionError.duplicateMessageId }

        let frame = WireFrame.request(msgId: id, payload: payload)
        let datagram = try cipher.encrypt(Data(frame.utf8))
        logger.debug("[\(clu.name)][\(id)] Sent: \(frame)")

        let timeoutTask = Task { [clock, responseTimeout] in
            try? await sleepOn(clock, for: responseTimeout)
            guard !Task.isCancelled else { return }
            self.failPending(id, error: SessionError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WireResponse, any Error>) in
                guard state != .stopped else {
                    cont.resume(throwing: SessionError.notConnected)
                    return
                }
                pending[id] = cont
                Task {
                    do {
                        try await socket.send(datagram)
                    } catch {
                        self.failPending(id, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failPending(id, error: CancellationError()) }
        }
    }

    private func failPending(_ id: String, error: any Error) {
        if let cont = pending.removeValue(forKey: id) {
            cont.resume(throwing: error)
        }
    }

    private func failAllPending(_ error: any Error) {
        let continuations = pending.values
        pending.removeAll()
        for cont in continuations {
            cont.resume(throwing: error)
        }
    }

    // MARK: - Datagram routing (spec §5.4.1, §5.4.3)

    private func makeRouter(
        for socket: any UdpSocket, source: DatagramSource
    ) -> Task<Void, Never> {
        Task { [weak self] in
            for await datagram in socket.incoming {
                guard let self else { return }
                await self.handleDatagram(datagram, from: source)
            }
            if case .main(let generation) = source {
                await self?.mainSocketClosed(generation: generation)
            }
        }
    }

    private func mainSocketClosed(generation: Int) {
        guard generation == mainSocketGeneration, state != .stopped else { return }
        logger.warning("[\(clu.name)] Main socket closed unexpectedly")
        failAllPending(SessionError.connectionClosed)
        mainSocket = nil
        mainRouterTask = nil
        mainSocketGeneration += 1
        state = .degraded
        needsRecovery = needsRecovery || !desiredKeys.isEmpty
    }

    /// `true` when the source still identifies a live socket of the CURRENT
    /// session topology; datagrams from stale sources are dropped whole.
    private func isCurrent(_ source: DatagramSource) -> Bool {
        switch source {
        case .main(let generation):
            return generation == mainSocketGeneration && mainSocket != nil
        case .endpoint(let id):
            return endpoints.contains { $0.id == id }
        }
    }

    private func handleDatagram(_ data: Data, from source: DatagramSource) {
        guard isCurrent(source) else {
            logger.debug("[\(clu.name)] Dropping datagram from a stale socket")
            return
        }
        guard let plaintext = cipher.decrypt(data) else {
            logger.warning("[\(clu.name)] Failed to decrypt datagram (\(data.count) bytes)")
            return
        }
        guard let text = String(data: plaintext, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        else {
            logger.warning("[\(clu.name)] Failed to decode decrypted datagram")
            return
        }
        guard let response = WireFrame.parseResponse(text) else {
            logger.debug("[\(clu.name)] Unsupported message: \(text)")
            return
        }
        logger.debug("[\(clu.name)][\(response.msgId)] Received: \(text)")

        if let cont = pending.removeValue(forKey: response.msgId) {
            cont.resume(returning: response)
            return
        }

        if response.isClientReport, case .endpoint(let endpointId) = source {
            // Keys come from the CURRENT endpoint record, never a capture.
            guard let endpoint = endpoints.first(where: { $0.id == endpointId }) else { return }
            guard let report = Payloads.parseClientReport(response.payload),
                  !report.values.isEmpty
            else {
                logger.debug("[\(clu.name)] Ignoring malformed/empty client report")
                return
            }
            publishReport(ChunkReport(
                keys: endpoint.keys,
                slots: report.values.map(RegistrationSlot.value)))
        } else {
            logger.debug("[\(clu.name)][\(response.msgId)] Response with no pending request")
        }
    }

    // MARK: - Endpoint teardown

    private func closeEndpoints() {
        for endpoint in endpoints {
            endpoint.socket.close()
            endpoint.routerTask?.cancel()
        }
        if !endpoints.isEmpty {
            logger.debug("[\(clu.name)] Closed \(endpoints.count) subscription socket(s)")
        }
        endpoints = []
    }

    // MARK: - Serialization gate (spec §5.4.5)

    /// FIFO, cancellation-aware: returns `false` (without acquiring) when
    /// the caller was cancelled before its turn — the operation must not run.
    private func beginOperation() async -> Bool {
        if Task.isCancelled { return false }
        if !operationInProgress {
            operationInProgress = true
            return true
        }
        let id = UUID()
        let acquired = await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
                if Task.isCancelled {
                    cont.resume(returning: false)
                    return
                }
                waiterOrder.append(id)
                waiterContinuations[id] = cont
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
        if acquired && Task.isCancelled {
            endOperation()
            return false
        }
        return acquired
    }

    /// `stop()` must always run its cleanup, even from a cancelled task.
    private func beginOperationUncancellable() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        let id = UUID()
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            waiterOrder.append(id)
            waiterContinuations[id] = cont
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let cont = waiterContinuations.removeValue(forKey: id) else { return }
        waiterOrder.removeAll { $0 == id }
        cont.resume(returning: false)
    }

    private func endOperation() {
        while let id = waiterOrder.first {
            waiterOrder.removeFirst()
            if let cont = waiterContinuations.removeValue(forKey: id) {
                cont.resume(returning: true)
                return
            }
        }
        operationInProgress = false
    }
}
