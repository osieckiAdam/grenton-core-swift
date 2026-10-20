import Foundation
import GrentonModel

/// Opens the `any Clock<Duration>` existential — the protocol's
/// `sleep(until:tolerance:)` needs a concrete `Instant` type.
func sleepOn<C: Clock>(_ clock: C, for duration: C.Duration) async throws {
    try await clock.sleep(until: clock.now.advanced(by: duration), tolerance: nil)
}

/// Whether `drainSends` saw every send finish; written once under `ResumeOnce`.
private final class DrainOutcome: @unchecked Sendable {
    var value = false
}

/// Runs its body once, whichever caller comes first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func run(_ body: () -> Void) {
        lock.lock()
        let first = !done
        done = true
        lock.unlock()
        if first { body() }
    }
}

extension Clock where Duration == Swift.Duration {
    /// `duration` from now, as an opaque deadline for `sleep(untilDeadline:)`
    /// — callable on an `any Clock<Duration>`, unlike `now.advanced(by:)`.
    func deadline(after duration: Duration) -> any Sendable {
        now.advanced(by: duration)
    }

    /// Sleeps until a deadline made by `deadline(after:)` on this clock; a
    /// deadline already past returns at once.
    func sleep(untilDeadline deadline: any Sendable) async throws {
        guard let instant = deadline as? Instant else { return }
        try await sleep(until: instant, tolerance: nil)
    }
}

// One CLU's protocol session (spec §5.4): ONE socket for pings, actions,
// registrations and notifications; every subscription chunk is registered
// from it under its own number, and notifications are routed by that
// number. Request/response correlation with timeout.
//
// Concurrency model (Swift plan §4.4):
// - every socket has exactly ONE router task reading its `incoming`
//   stream; operations never read sockets directly — they await
//   continuations the router resumes;
// - every datagram is validated against the main-socket generation before
//   it may resume a pending request or publish a report — a stale router
//   that already dequeued a datagram cannot affect a restarted session;
// - multi-step operations (`start`, `register`, `stop`) run behind a
//   cancellation-aware FIFO gate because actors are reentrant across
//   `await`; a caller cancelled while queued never runs its operation;
// - `stop()` fails pending requests and cancels in-flight socket opens
//   immediately (before taking the gate), so nothing drains slowly;
// - recovery from `degraded` re-registers the last desired subscription
//   set before the session becomes `ready` again (spec §5.4.5);
// - the maintenance loops (spec §5.4.4) run on the injected clock: a ping
//   every `pingInterval` after the previous loop ping ends, and a
//   re-registration `registerInterval` after ANY registration STARTED (its
//   first chunk sent), but never before that registration ended.
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
    private let registerFrameLimit: Int

    /// Constant per session; every ping reuses it as its message id
    /// (spec §5.3.1).
    private let keepAliveId: String

    public private(set) var state: SessionState = .idle

    /// How long after the previous loop ping ends the next one is sent (spec §5.4.4).
    public static let defaultPingInterval: Duration = .seconds(5)
    /// How long after a registration starts the keys are registered again (spec §5.4.4).
    public static let defaultRegisterInterval: Duration = .seconds(30)

    // MARK: Main socket

    private var mainSocket: (any UdpSocket)?
    private var mainRouterTask: Task<Void, Never>?
    /// Bumped on every install; datagrams and close callbacks from an older
    /// generation are ignored.
    private var mainSocketGeneration = 0
    /// Single-flight guard for concurrent main-socket opens.
    private var mainOpenTask: Task<Void, Never>?

    // MARK: Subscription chunks (spec §5.4.2)

    private struct Chunk: Equatable {
        let number: Int
        let keys: [ValueRef]
    }

    /// The chunks of the current key list, in key order.
    private var chunks: [Chunk] = []
    /// Every number the CLU may still push for, with its keys: a chunk is
    /// remembered from the moment its request is sent, and forgotten when
    /// it is destroyed. Notifications are routed through this table.
    private var subscriptions: [Int: [ValueRef]] = [:]
    /// The next fresh subscription number; restarts at 1 in `start()`.
    private var nextNumber = 1
    /// Six digits, matching the reservation of the chunk split (spec §5.4.2 pt 1).
    private static let maxNumber = 999_999
    /// When the latest registration's first chunk was sent, plus the
    /// re-registration interval (spec §5.4.4).
    private var reregistrationDeadline: (any Sendable)?

    /// The last key set requested via `register` — recovery re-registers it.
    private var desiredKeys: [ValueRef] = []
    private var needsRecovery = false

    // MARK: Maintenance loops (spec §5.4.4)

    private var pingLoopTask: Task<Void, Never>?
    /// Sleeps until the next re-registration; replaced whenever a
    /// registration ends, so the interval counts from the latest one.
    private var registerLoopTask: Task<Void, Never>?

    // MARK: Correlation & subscribers

    /// A request waiting for its reply. The token tells successive requests
    /// with the same msg_id apart (every ping reuses `keepAliveId`), so a
    /// late timeout or send error of one never ends the next.
    private struct Pending {
        let token: UUID
        let continuation: CheckedContinuation<WireResponse, any Error>
    }

    private var pending: [String: Pending] = [:]
    /// Sends handed to the transport and not finished yet; drained before
    /// any `clientDestroy`, so a registration never reaches the CLU after
    /// the destroy of its number.
    private var inflightSends: [UUID: Task<Void, Never>] = [:]
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
        registerFrameLimit: Int = Payloads.defaultRegisterFrameLimit
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
        // A port may lower the frame limit, never raise it (spec §5.4.2 pt 1).
        self.registerFrameLimit = min(max(registerFrameLimit, 1), Payloads.defaultRegisterFrameLimit)
        self.keepAliveId = random.messageId()
    }

    // MARK: - Lifecycle (spec §5.4.5)

    /// Idempotent. Opens the main socket, performs the initial ping and
    /// starts the ping loop. Failure is not fatal: the session ends up
    /// `degraded` and every later ping retries (including reopening the
    /// socket).
    public func start() async {
        // A stop() still tearing down owns the socket: wait for it, also
        // when it began while this start was queued behind another operation.
        if let teardown = teardownTask { await teardown.value }
        guard await beginOperation() else { return }
        while let teardown = teardownTask {
            endOperation()   // the teardown is queued behind us
            await teardown.value
            guard await beginOperation() else { return }
        }
        defer { endOperation() }
        guard state == .idle || state == .stopped else { return }
        state = .starting
        chunks = []
        subscriptions = [:]
        nextNumber = 1
        _ = await pingInternal(gateHeld: true)
        if state != .stopped { startPingLoop() }
    }

    /// Idempotent. After `stop()` the session may be started again
    /// (mobile background/foreground cycle) with no subscriptions: the
    /// caller registers again (spec §5.4.5). Concurrent calls join one
    /// teardown.
    public func stop() async {
        if let teardown = teardownTask {
            await teardown.value
            return
        }
        guard state != .stopped else { return }
        state = .stopped
        desiredKeys = []
        needsRecovery = false
        pingLoopTask?.cancel()
        pingLoopTask = nil
        registerLoopTask?.cancel()
        registerLoopTask = nil

        // At once: fail what waits and stop opens, so an in-flight
        // operation drains instead of hanging until its timeout.
        for (_, task) in activeOpens { task.cancel() }
        failAllPending(SessionError.connectionClosed)

        // The rest behind the gate, so no registration, recovery or start
        // can interleave with it; its own task, so a cancelled caller
        // cannot cut it short.
        let teardown = Task { await self.tearDown() }
        teardownTask = teardown
        await teardown.value
    }

    private var teardownTask: Task<Void, Never>?

    /// Destroys every remembered chunk, then closes the main socket (spec §5.4.5).
    private func tearDown() async {
        await beginOperationUncancellable()   // the in-flight operation drains first
        await drainSends()
        desiredKeys = []
        needsRecovery = false
        let numbers = subscriptions.keys.sorted()
        subscriptions = [:]
        chunks = []
        reregistrationDeadline = nil
        if let socket = mainSocket {
            // Destroys only behind a drained socket: queued behind a stuck
            // send they could not keep their order. The socket closes either
            // way, which also ends any stuck send.
            if await drainSends() {
                sendDestroys(numbers, over: socket)
                _ = await drainSends()
            }
            socket.close()
        }
        mainSocket = nil
        mainRouterTask?.cancel()
        mainRouterTask = nil
        mainSocketGeneration += 1   // invalidate any stale router immediately
        teardownTask = nil          // before the gate passes to a waiting start()
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
        // A reply or failure on a socket that was replaced meanwhile (number
        // rollover, failure, stop) says nothing about the current one.
        let generation = mainSocketGeneration
        do {
            _ = try await sendRequest(Payloads.checkAlive, msgId: keepAliveId, over: socket)
            guard state != .stopped, generation == mainSocketGeneration else { return false }
            if needsRecovery && !desiredKeys.isEmpty {
                await recoverSubscriptions(gateHeld: gateHeld)
                // The socket may have failed or been replaced meanwhile.
                guard state != .stopped, generation == mainSocketGeneration else { return false }
            }
            state = .ready
            return true
        } catch {
            // A racing ping owns the in-flight request — let its outcome
            // decide the state.
            if case SessionError.duplicateMessageId = error { return false }
            // stop() cancelled it — not a CLU failure, and no reason to degrade.
            if error is CancellationError { return false }
            guard generation == mainSocketGeneration else { return false }
            logger.warning("[\(clu.name)] Ping failed: \(error)")
            if state != .stopped { state = .degraded; needsRecovery = needsRecovery || !desiredKeys.isEmpty }
            return false
        }
    }

    /// Re-registers the desired key set after recovery; publishes the
    /// fresh initial values through the report pipeline so consumers
    /// resynchronise (spec §5.4.5).
    private func recoverSubscriptions(gateHeld: Bool) async {
        if !gateHeld {
            guard await beginOperation() else { return }
        }
        defer { if !gateHeld { endOperation() } }
        // Read the keys under the gate: a registration queued ahead of this
        // recovery may have replaced them meanwhile.
        guard state != .stopped, needsRecovery, !desiredKeys.isEmpty else { return }
        let keys = desiredKeys
        let generation = mainSocketGeneration
        let slots = await registerLocked(keys)
        guard state != .stopped else { return }
        scheduleReregistration()
        guard !slots.allSatisfy({ $0 == .failed }) else { return }
        // Partial failure keeps the flag — retried on the next ping.
        // A socket lost or replaced meanwhile (e.g. a stuck destroy) leaves
        // the subscriptions on the old port: recover even if every slot succeeded.
        needsRecovery = slots.contains(.failed) || generation != mainSocketGeneration
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

    /// Replaces all subscriptions with `keys`: split into chunks that fit the
    /// frame limit, each registered from the main socket under its own
    /// number. Returns slots positionally aligned with `keys`; a failed
    /// chunk contributes `.failed` at its positions. A cancelled caller
    /// performs nothing and receives all-failed slots.
    public func register(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        guard await beginOperation() else { return keys.map { _ in .failed } }
        defer { endOperation() }
        // Stopped while queued: the keys must not outlive stop() (spec §5.4.5).
        guard state != .stopped else { return keys.map { _ in .failed } }
        desiredKeys = keys
        let generation = mainSocketGeneration
        let slots = await registerLocked(keys)
        guard state != .stopped else { return slots }   // stop() forgot the keys
        // Any failed position leaves the CLU with an incomplete lease —
        // the next successful ping must re-register (spec §5.4.5). A fully
        // clean registration clears the flag.
        needsRecovery = !keys.isEmpty && (slots.contains(.failed) || generation != mainSocketGeneration)
        scheduleReregistration()
        return slots
    }

    // MARK: - One-shot read (spec §5.4.2, `fetch`)

    /// Reads the current values of `keys` once, without subscribing.
    ///
    /// Chunked and sent one chunk at a time like a registration; the slots
    /// are in key order, `failed` where a chunk got no usable reply. It
    /// leaves the subscriptions and the maintenance loops alone, sends
    /// nothing without an open main socket, and `stop()` cuts it short with
    /// `failed` for what was not read.
    public func fetch(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        guard await beginOperation() else { return keys.map { _ in .failed } }
        defer { endOperation() }
        guard state != .stopped, mainSocket != nil else { return keys.map { _ in .failed } }
        var results: [RegistrationSlot] = []
        for chunk in Payloads.fetchChunks(keys, frameLimit: registerFrameLimit) {
            results += await fetchChunk(chunk)
        }
        return results
    }

    private func fetchChunk(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        let failed = keys.map { _ in RegistrationSlot.failed }
        guard state != .stopped, let socket = mainSocket else { return failed }
        do {
            let payload = try Payloads.fetchValues(keys: keys)
            let response = try await sendRequest(payload, msgId: random.messageId(), over: socket)
            guard let values = Payloads.parseValues(response.payload), values.count == keys.count else {
                logger.error("[\(clu.name)] Malformed fetchValues response")
                return failed
            }
            return values.map(RegistrationSlot.value)
        } catch is CancellationError {
            return failed
        } catch {
            logger.warning("[\(clu.name)] fetchValues failed: \(error)")
            return failed
        }
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

    /// Re-registers `registerInterval` after the latest registration
    /// started, while there are keys to renew. Called when a registration
    /// ends, so it never runs before the previous one finished.
    private func scheduleReregistration() {
        registerLoopTask?.cancel()
        registerLoopTask = nil
        guard state != .stopped, !desiredKeys.isEmpty else { return }
        // No chunk went out (no socket): count from now.
        let deadline = reregistrationDeadline ?? clock.deadline(after: registerInterval)
        registerLoopTask = Task { [weak self, clock] in
            do { try await clock.sleep(untilDeadline: deadline) } catch { return }
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
        let generation = mainSocketGeneration
        let slots = await registerLocked(keys)
        guard state != .stopped else { return }
        // A socket lost or replaced meanwhile (e.g. a stuck destroy) leaves
        // the subscriptions on the old port: recover even if every slot succeeded.
        needsRecovery = slots.contains(.failed) || generation != mainSocketGeneration
        scheduleReregistration()
        guard !slots.allSatisfy({ $0 == .failed }) else { return }
        publishReport(ChunkReport(keys: keys, slots: slots))
    }

    /// Body of `register` — requires the operation gate to be held.
    private func registerLocked(_ keys: [ValueRef]) async -> [RegistrationSlot] {
        reregistrationDeadline = nil
        guard state != .stopped else { return keys.map { _ in .failed } }
        guard !keys.isEmpty else {
            await destroy(subscriptions.keys.sorted())
            chunks = []
            return []
        }

        // A chunk keeps its number only while its key list is identical;
        // any other list gets a fresh number, so a late notification of an
        // old list can never land on new keys (spec §5.4.2 pt 1).
        let lists = Payloads.registrationChunks(keys, frameLimit: registerFrameLimit)
        let kept = lists.indices.map { $0 < chunks.count && chunks[$0].keys == lists[$0] }
        if nextNumber - 1 + kept.filter({ !$0 }).count > Self.maxNumber {
            await restartNumbering()
        }
        let plan = lists.indices.map { index -> Chunk in
            if kept[index] && index < chunks.count { return chunks[index] }
            defer { nextNumber += 1 }
            return Chunk(number: nextNumber, keys: lists[index])
        }

        // One chunk at a time (spec §5.4.2). With all chunks in flight at
        // once, the two CLUs that need 4–5 chunks timed out on some of them
        // in every live run, while single-chunk CLUs never did; sequential
        // registration removed every timeout (live, 2026-09-30).
        var results: [RegistrationSlot] = []
        for chunk in plan {
            results += await registerChunk(chunk)
        }
        guard state != .stopped else { return results }   // stop() destroyed them

        chunks = plan
        let used = Set(plan.map(\.number))
        await destroy(subscriptions.keys.filter { !used.contains($0) }.sorted())
        return results
    }

    private func registerChunk(_ chunk: Chunk) async -> [RegistrationSlot] {
        let failed = chunk.keys.map { _ in RegistrationSlot.failed }
        guard state != .stopped, let socket = mainSocket else { return failed }
        // Remembered from the moment it is sent: the CLU may accept it even
        // when the reply is lost (spec §5.4.2 pt 2).
        subscriptions[chunk.number] = chunk.keys
        if reregistrationDeadline == nil {
            reregistrationDeadline = clock.deadline(after: registerInterval)
        }
        do {
            let payload = try Payloads.clientRegister(sessionId: chunk.number, keys: chunk.keys)
            let response = try await sendRequest(payload, msgId: random.messageId(), over: socket)
            // Correlated by msg_id; the number in the reply is not checked
            // (spec §5.3.2 pt 1).
            guard let report = Payloads.parseClientReport(response.payload),
                  report.values.count == chunk.keys.count
            else {
                logger.error("[\(clu.name)] Malformed register response (subscription \(chunk.number))")
                return failed
            }
            return report.values.map(RegistrationSlot.value)
        } catch is CancellationError {
            return failed   // stop() cancelled it — not a CLU failure
        } catch {
            logger.warning("[\(clu.name)] Registration failed (subscription \(chunk.number)): \(error)")
            return failed
        }
    }

    /// Sends `clientDestroy` for `numbers` (ascending) without waiting for
    /// replies, and forgets them (spec §5.3.2, §5.4.2 pt 6).
    private func destroy(_ numbers: [Int]) async {
        for number in numbers { subscriptions[number] = nil }
        guard let socket = mainSocket, !numbers.isEmpty else { return }
        // A send stuck past the timeout could still reach the CLU after the
        // destroy and resurrect the subscription: drop that socket instead.
        guard await drainSends() else { return abandonMainSocket() }
        sendDestroys(numbers, over: socket)
        // A registration ends once its destroys went out.
        if !(await drainSends()) { abandonMainSocket() }
    }

    /// The transport did not finish a send within the response timeout:
    /// treat it as a failed socket (spec §5.4.1 pt 4). Closing it ends the
    /// stuck sends; the ping loop opens a new one and recovery registers
    /// again, from a new port, so the old subscriptions just expire.
    private func abandonMainSocket() {
        guard let socket = mainSocket else { return }
        logger.warning("[\(clu.name)] A send did not finish in time; replacing the main socket")
        failAllPending(SessionError.connectionClosed)
        socket.close()
        mainSocket = nil
        mainRouterTask?.cancel()
        mainRouterTask = nil
        mainSocketGeneration += 1
        if state != .stopped {
            state = .degraded
            needsRecovery = !desiredKeys.isEmpty
        }
    }

    /// Waits for the sends in flight, but at most one response timeout: a
    /// transport send that never finishes must not block stop() forever. A
    /// send still stuck then ends when its socket closes.
    /// `true` when every send finished, `false` when the timeout came first.
    @discardableResult
    private func drainSends() async -> Bool {
        let sends = Array(inflightSends.values)
        guard !sends.isEmpty else { return true }
        let drained = DrainOutcome()
        let once = ResumeOnce()
        var waiters: [Task<Void, Never>] = []
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
            waiters.append(Task {
                for send in sends { await send.value }
                once.run { drained.value = true; done.resume() }
            })
            waiters.append(Task { [clock, responseTimeout] in
                try? await sleepOn(clock, for: responseTimeout)
                once.run { done.resume() }
            })
        }
        waiters.forEach { $0.cancel() }
        return drained.value
    }

    /// Sends the destroys, ascending, from one tracked task: nobody waits
    /// for replies, and `drainSends()` bounds how long anyone waits for the
    /// sends themselves.
    private func sendDestroys(_ numbers: [Int], over socket: any UdpSocket) {
        guard !numbers.isEmpty else { return }
        let frames = numbers.map {
            (number: $0, frame: WireFrame.request(
                msgId: random.messageId(), payload: Payloads.clientDestroy(sessionId: $0)))
        }
        let token = UUID()
        inflightSends[token] = Task {
            defer { self.inflightSends[token] = nil }
            for (number, frame) in frames {
                do {
                    try await socket.send(cipher.encrypt(Data(frame.utf8)))
                    logger.debug("[\(clu.name)] Sent: \(frame)")
                } catch {
                    logger.debug("[\(clu.name)] clientDestroy \(number) not sent: \(error)")
                }
            }
        }
    }

    /// Out of six-digit numbers: destroy everything and start over on a new
    /// main socket, whose new port makes every number a new subscription, so
    /// no number returns with another list on the same port (spec §5.4.2 pt 1).
    private func restartNumbering() async {
        await destroy(subscriptions.keys.sorted())
        chunks = []
        nextNumber = 1
        // Requests waiting on the old socket end now, not at their timeout.
        failAllPending(SessionError.connectionClosed)
        mainSocket?.close()
        mainSocket = nil
        mainRouterTask?.cancel()
        mainRouterTask = nil
        mainSocketGeneration += 1
        await ensureMainSocketOpen()
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

        let token = UUID()
        let timeoutTask = Task { [clock, responseTimeout] in
            try? await sleepOn(clock, for: responseTimeout)
            guard !Task.isCancelled else { return }
            self.failPending(id, token: token, error: SessionError.timeout)
        }
        defer { timeoutTask.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<WireResponse, any Error>) in
                guard state != .stopped else {
                    cont.resume(throwing: SessionError.notConnected)
                    return
                }
                pending[id] = Pending(token: token, continuation: cont)
                inflightSends[token] = Task {
                    defer { self.inflightSends[token] = nil }
                    // stop() or a timeout may have ended the request before
                    // this task ran: then nothing goes out.
                    guard self.pending[id]?.token == token, self.state != .stopped else { return }
                    do {
                        try await socket.send(datagram)
                    } catch {
                        self.failPending(id, token: token, error: error)
                    }
                }
            }
        } onCancel: {
            Task { await self.failPending(id, token: token, error: CancellationError()) }
        }
    }

    /// Ends the request `id` only while it is still the one `token` names.
    private func failPending(_ id: String, token: UUID, error: any Error) {
        guard pending[id]?.token == token, let entry = pending.removeValue(forKey: id) else { return }
        entry.continuation.resume(throwing: error)
    }

    private func failAllPending(_ error: any Error) {
        let entries = pending.values
        pending.removeAll()
        for entry in entries {
            entry.continuation.resume(throwing: error)
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

        if let entry = pending.removeValue(forKey: response.msgId) {
            entry.continuation.resume(returning: response)
            return
        }

        if response.isClientReport {
            // Routed by the subscription number (spec §5.4.3); the keys come
            // from the current table, never a capture.
            guard let report = Payloads.parseClientReport(response.payload),
                  let keys = subscriptions[report.sessionId],
                  report.values.count == keys.count
            else {
                logger.debug("[\(clu.name)] Dropping a report for an unknown subscription or with a wrong value count")
                return
            }
            publishReport(ChunkReport(keys: keys, slots: report.values.map(RegistrationSlot.value)))
        } else {
            logger.debug("[\(clu.name)][\(response.msgId)] Response with no pending request")
        }
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
