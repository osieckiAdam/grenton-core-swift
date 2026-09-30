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

/// The runtime facade (spec §5.4.4, Swift plan §4.6): one CLU session per
/// interface CLU, the 5 s ping and 45 s re-registration loops, report
/// routing into the shared StateStore, and command routing by CLU id.
///
/// Consumes a parsed `MobileInterfaceDTO` — it neither knows nor cares
/// where the interface came from (Provisioning, file, QR).
public actor GrentonSystem: CommandExecuting {
    public nonisolated let store: StateStore
    public nonisolated let descriptors: [DeviceDescriptor]
    public nonisolated let devices: [BoundDevice]

    private let clus: [Clu]
    private let cipher: AesCbcCipher
    private let socketFactory: any UdpSocketFactory
    private let logger: GrentonLogger
    private let pingInterval: Duration
    private let registerInterval: Duration
    private let responseTimeout: Duration

    private var sessions: [String: CluSession] = [:]
    private var loopTasks: [Task<Void, Never>] = []
    private var reportTasks: [Task<Void, Never>] = []
    private var started = false

    // start/stop serialization: actors are reentrant across await, and an
    // interleaved stop-during-start would leave zombie loops (spec §5.4.5).
    private var operationInProgress = false
    private var operationWaiters: [CheckedContinuation<Void, Never>] = []

    public init(
        interface: MobileInterfaceDTO,
        socketFactory: any UdpSocketFactory = NetworkUdpSocketFactory(),
        logger: GrentonLogger = .disabled,
        pingInterval: Duration = .seconds(5),
        registerInterval: Duration = .seconds(45),
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

    /// Devices grouped by the CLU object they operate (spec §6.6) — one
    /// entry per physical thermostat, shutter, relay… however many widgets
    /// show it.
    public nonisolated var physicalObjects: [PhysicalObject] {
        DeviceMapper.physicalObjects(for: descriptors)
    }

    /// Convenience lookup across all devices.
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

    /// Idempotent: sessions start, initial registration runs, loops spin up.
    /// Serialized against stop() — overlapping calls queue.
    public func start() async {
        await beginOperation()
        defer { endOperation() }
        guard !started else { return }
        started = true

        for clu in clus where sessions[clu.id] == nil {
            sessions[clu.id] = CluSession(
                clu: clu, cipher: cipher, socketFactory: socketFactory,
                logger: logger, responseTimeout: responseTimeout)
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

        loopTasks.append(Task { [weak self] in
            await self?.pingLoop()
        })
        loopTasks.append(Task { [weak self] in
            await self?.registerLoop()
        })
    }

    /// Idempotent; `start()` may be called again afterwards (mobile
    /// background/foreground cycle) — sessions retain their subscriptions.
    /// Serialized against start(); cancelled tasks are AWAITED so no zombie
    /// loop can outlive the call.
    public func stop() async {
        await beginOperation()
        defer { endOperation() }
        guard started else { return }
        started = false

        let cancelled = loopTasks + reportTasks
        loopTasks = []
        reportTasks = []
        for task in cancelled { task.cancel() }
        for task in cancelled { _ = await task.value }

        await withTaskGroup(of: Void.self) { group in
            for session in sessions.values {
                group.addTask { await session.stop() }
            }
        }
    }

    /// Re-registers the CURRENT subscription order immediately — call after
    /// registering new keys in the store at runtime (spec §5.4.4 Δ: a
    /// changed subscription set must not wait for the 45 s loop tick).
    public func refreshSubscriptions() async {
        guard started else { return }
        await registerAll()
    }

    /// Session states by CLU id — surface for diagnostics/UI.
    public func sessionStates() async -> [String: SessionState] {
        var states: [String: SessionState] = [:]
        for (cluId, session) in sessions {
            states[cluId] = await session.state
        }
        return states
    }

    // MARK: - Commands (CommandExecuting)

    public func execute(_ action: ActionRef) async throws {
        guard let session = sessions[action.cluId] else {
            logger.warning("No session for CLU \(action.cluId)")
            throw SessionError.notConnected
        }
        try await session.execute(action)
    }

    // MARK: - Loops (spec §5.4.4)

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

    private func pingLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: pingInterval)
            } catch { break }
            guard started else { break }
            await withTaskGroup(of: Void.self) { group in
                for session in sessions.values {
                    group.addTask { await session.ping() }
                }
            }
        }
    }

    /// Renews subscription leases and fully resynchronises values
    /// (self-healing after lost reports) — spec §5.4.4.
    private func registerLoop() async {
        while !Task.isCancelled {
            do {
                try await Task.sleep(for: registerInterval)
            } catch { break }
            guard started else { break }
            await registerAll()
        }
    }
}
