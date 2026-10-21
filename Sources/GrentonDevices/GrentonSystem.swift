import Foundation
import GrentonModel
import GrentonRuntime

/// Routes entity commands to the owning system once it exists — entities
/// are built in the system's init, before `self` is available. The target
/// is held WEAKLY: the system owns the entities, the entities reach back
/// through this proxy, and a strong reference here would make the whole
/// graph immortal without an explicit stop().
final class ExecutorProxy: CommandExecuting, @unchecked Sendable {
    private let lock = NSLock()
    private weak var target: (any CommandExecuting & AnyObject)?

    func install(_ executor: any CommandExecuting & AnyObject) {
        lock.lock()
        target = executor
        lock.unlock()
    }

    private var current: (any CommandExecuting)? {
        lock.lock()
        defer { lock.unlock() }
        return target
    }

    func execute(_ action: ActionRef) async throws {
        guard let executor = current else { throw SessionError.notConnected }
        try await executor.execute(action)
    }
}

// Runtime facade: one CLU session per interface CLU (each runs its own 5 s
// ping and 30 s re-registration loops, spec §5.4.4), report routing into
// the shared StateStore, and command routing by CLU id. It consumes a parsed
// interface and does not care where it came from (Provisioning, file, QR).

/// A connected Grenton installation: every device of the interface, kept
/// up to date by the CLUs.
///
/// Create it from the mobile interface, call ``start()``, then read and
/// control ``entities``:
///
/// ```swift
/// let system = try GrentonSystem(interface: interface)
/// await system.start()
/// let lights = system.entities.compactMap(\.switchable)
/// ```
///
/// Devices and entities exist as soon as the system is created, before any
/// connection; their state stays `nil` until the CLUs report it.
public actor GrentonSystem: CommandExecuting {
    /// Every value reported by the CLUs. Entities read their state from it;
    /// use it directly only for raw values.
    public nonisolated let store: StateStore
    /// The devices as plain descriptions, without state or commands.
    public nonisolated let descriptors: [DeviceDescriptor]
    /// Every device of the interface, one per widget, in page order.
    public nonisolated let devices: [BoundDevice]

    private let clus: [Clu]
    private let cipher: AesCbcCipher
    private let socketFactory: any UdpSocketFactory
    private let logger: GrentonLogger
    private let pingInterval: Duration
    private let registerInterval: Duration
    private let responseTimeout: Duration

    private var sessions: [String: CluSession] = [:]
    private var reportTasks: [Task<Void, Never>] = []
    private var started = false

    // start/stop serialization: actors are reentrant across await, and an
    // interleaved stop-during-start would leave zombie loops (spec §5.4.5).
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    /// Creates the devices of an interface. Nothing connects until ``start()``.
    ///
    /// - Parameters:
    ///   - interface: The mobile interface from Object Manager.
    ///   - socketFactory: How to open UDP connections to the CLUs. Keep the
    ///     default unless a CLU answers from a different address than the one
    ///     in the interface; then pass `AnySourceUdpSocketFactory()`.
    ///   - logger: Where the library reports problems, such as a CLU that
    ///     does not answer. Silent by default.
    ///   - pingInterval: How often each CLU is checked.
    ///   - registerInterval: How often subscriptions are renewed and all values
    ///     re-read.
    ///   - responseTimeout: How long to wait for a CLU to answer a request.
    /// - Throws: An error if the interface's encryption key is invalid.
    public init(
        interface: MobileInterfaceDTO,
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        logger: GrentonLogger = .disabled,
        pingInterval: Duration = CluSession.defaultPingInterval,
        registerInterval: Duration = CluSession.defaultRegisterInterval,
        responseTimeout: Duration = .seconds(5)
    ) throws {
        self.clus = interface.clus.map(Clu.init(dto:))
        self.cipher = try AesCbcCipher(encryption: interface.encryption)
        self.socketFactory = socketFactory
        self.logger = logger
        self.pingInterval = pingInterval
        self.registerInterval = registerInterval
        self.responseTimeout = responseTimeout

        let store = StateStore()
        self.store = store
        self.descriptors = DeviceMapper.descriptors(for: interface)

        let proxy = ExecutorProxy()
        self.devices = DeviceBinder.bind(
            descriptors, context: DeviceContext(store: store, executor: proxy))
        proxy.install(self)
    }

    /// Devices grouped by what they operate on the CLU: one entry per
    /// thermostat, shutter or relay, however many widgets show it.
    ///
    /// The same thermostat often appears on a room page and on a heating
    /// page under different names. Use this list to show each piece of
    /// hardware once.
    public nonisolated var physicalObjects: [PhysicalObject] {
        DeviceMapper.physicalObjects(for: descriptors)
    }

    /// Every entity of every device, in device order.
    public nonisolated var entities: [BoundEntity] {
        devices.flatMap(\.entities)
    }

    // MARK: - Lifecycle

    private func beginOperation() async {
        if !operationInProgress {
            operationInProgress = true
            return
        }
        await withCheckedContinuation { operationWaiters.append($0) }
    }

    private func endOperation() {
        if operationWaiters.isEmpty {
            operationInProgress = false
        } else {
            operationWaiters.removeFirst().resume()
        }
    }

    // Idempotent; serialized against stop() — overlapping calls queue.

    /// Connects to every CLU and subscribes to all values.
    ///
    /// Returns once every CLU's first subscription has either been answered or
    /// timed out. The values of the CLUs that answered are then known; a CLU
    /// that did not answer leaves its values `nil` and is retried in the
    /// background. Check ``sessionStates()`` to see which answered. Calling
    /// `start()` again while running does nothing.
    public func start() async {
        await beginOperation()
        defer { endOperation() }
        guard !started else { return }
        started = true

        for clu in clus where sessions[clu.id] == nil {
            sessions[clu.id] = CluSession(
                clu: clu, cipher: cipher, socketFactory: socketFactory,
                logger: logger, responseTimeout: responseTimeout,
                pingInterval: pingInterval, registerInterval: registerInterval)
        }

        // Sessions in parallel: connect + initial ping, then subscribe to
        // their report streams, then the initial registration.
        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                group.addTask { await session.start() }
            }
        }

        for (cluId, session) in sessions {
            let stream = await session.reports()
            reportTasks.append(Task { [store] in
                for await report in stream {
                    store.updateKeys(report.keys, report.slots)
                }
            })
            _ = cluId
        }

        await registerAll()
    }

    // Serialized against start(); cancelled report tasks are AWAITED so none
    // can outlive the call. Sessions stop their own loops.

    /// Disconnects from every CLU.
    ///
    /// Entities keep their last values. Call ``start()`` again to reconnect,
    /// for example when an app returns to the foreground.
    public func stop() async {
        await beginOperation()
        defer { endOperation() }
        guard started else { return }
        started = false

        let cancelled = reportTasks
        reportTasks = []
        for task in cancelled { task.cancel() }
        for task in cancelled { _ = await task.value }

        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                group.addTask { await session.stop() }
            }
        }
    }

    // spec §5.4.4 Δ: a changed subscription set must not wait for the loop tick.

    /// Renews all subscriptions now and re-reads every value, instead of
    /// waiting for the next periodic renewal.
    public func refreshSubscriptions() async {
        guard started else { return }
        await registerAll()
    }

    /// The connection state of each CLU, keyed by CLU id.
    ///
    /// A CLU that stops answering becomes `degraded` and recovers by itself
    /// when it answers again.
    public func sessionStates() async -> [String: SessionState] {
        var states: [String: SessionState] = [:]
        for (cluId, session) in sessions {
            states[cluId] = await session.state
        }
        return states
    }

    // MARK: - Commands (CommandExecuting)

    /// Sends a raw action to its CLU. Entities call this for you; use it only
    /// for actions that no entity covers.
    ///
    /// - Throws: `PayloadError.unresolvedPlaceholder` when the action's value
    ///   is still `$value$`; give it a value with `withValue(_:)` first.
    public func execute(_ action: ActionRef) async throws {
        guard let session = sessions[action.cluId] else {
            logger.warning("No session for CLU \(action.cluId)")
            throw SessionError.notConnected
        }
        try await session.execute(action)
    }

    // MARK: - One-shot read

    /// Reads the current values of `refs` once, without subscribing, and
    /// stores them.
    ///
    /// Use it for values no entity watches, for a read-back after an action,
    /// or for a screen shown only briefly. The result is in the order of
    /// `refs`; a position is `failed` when its CLU did not answer or is not
    /// part of this system. Values that were read are stored and announced
    /// like a report — also for keys no entity watches, which stay readable
    /// through ``store`` without becoming a subscription. A read that
    /// arrives after a newer report of the same key can briefly show the
    /// older value; the next report corrects it.
    public func fetch(_ refs: [ValueRef]) async -> [RegistrationSlot] {
        var slots = [RegistrationSlot](repeating: .failed, count: refs.count)
        let positions = Dictionary(grouping: refs.indices, by: { refs[$0].cluId })
        await withTaskGroup(of: (String, [RegistrationSlot]).self) { group in
            for (cluId, indices) in positions {
                guard let session = sessions[cluId] else { continue }
                let keys = indices.map { refs[$0] }
                group.addTask { (cluId, await session.fetch(keys)) }
            }
            for await (cluId, read) in group {
                guard let indices = positions[cluId] else { continue }
                store.updateKeys(indices.map { refs[$0] }, read, includingUnknown: true)
                for (index, slot) in zip(indices, read) { slots[index] = slot }
            }
        }
        return slots
    }

    // MARK: - Registration

    /// Explicit registration; its slots update the store directly. Later
    /// periodic re-registrations arrive through the report streams.
    private func registerAll() async {
        await withTaskGroup(of: Void.self) { group in
            for (cluId, session) in sessions {
                let keys = store.subscriptionOrder(cluId: cluId)
                guard !keys.isEmpty else { continue }
                group.addTask { [store] in
                    let slots = await session.register(keys)
                    store.updateKeys(keys, slots)   // initial values
                }
            }
        }
    }
}
