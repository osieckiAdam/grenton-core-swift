import Foundation
import GrentonModel

// A single state change, emitted only when the stored value actually
// changed (spec §5.5 Δ).
/// One value that changed on a CLU.
public struct StateChange: Sendable, Equatable {
    /// The value that changed.
    public let key: ValueRef
    /// The value before; `nil` when it was not known yet (a CLU reporting nothing gives `GrentonValue.null`, not `nil`).
    public let oldValue: GrentonValue?
    /// The value now.
    public let newValue: GrentonValue

    /// Creates a change, for adapters and tests that build their own streams.
    public init(key: ValueRef, oldValue: GrentonValue?, newValue: GrentonValue) {
        self.key = key
        self.oldValue = oldValue
        self.newValue = newValue
    }
}

// Per-installation state store (spec §5.5).
//
// A lock-based class rather than an actor so device entities can read
// state synchronously (Swift plan §4.5): spec §5.6 only requires safe
// concurrent reads with serialized writes, which a short critical section
// satisfies. Writes arrive from sessions; per-CLU event ordering holds as
// long as one session updates one CLU's keys (which the design guarantees).
/// Every value reported by the CLUs.
///
/// Entities read their state from here, already normalized; read the store directly only for raw values.
package final class StateStore: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [ValueRef: GrentonValue] = [:]
    private var known: Set<ValueRef> = []
    private var order: [String: [ValueRef]] = [:]
    private var subscribers: [UUID: AsyncStream<StateChange>.Continuation] = [:]
    // Key-filtered "something changed" flags (spec §6.5): filtered here,
    // under the lock, so a flood of other keys can never displace them.
    private var watchers: [UUID: (keys: Set<ValueRef>, sink: AsyncStream<Void>.Continuation)] = [:]

    package init() {}

    /// Idempotent; preserves first-registration order per CLU — the order
    /// is part of the protocol (positional value matching).
    package func registerKey(_ ref: ValueRef) {
        lock.lock()
        defer { lock.unlock() }
        if known.insert(ref).inserted {
            order[ref.cluId, default: []].append(ref)
        }
    }

    package func subscriptionOrder(cluId: String) -> [ValueRef] {
        lock.lock()
        defer { lock.unlock() }
        return order[cluId] ?? []
    }

    package var cluIdsWithKeys: [String] {
        lock.lock()
        defer { lock.unlock() }
        return order.filter { !$0.value.isEmpty }.map(\.key)
    }

    // `nil` = value not yet known; `.null` = the CLU reported `nil`.
    /// The raw value; `nil` until the CLU has reported it. A CLU reporting nothing gives `GrentonValue.null`.
    package func value(for ref: ValueRef) -> GrentonValue? {
        lock.lock()
        defer { lock.unlock() }
        return values[ref]
    }

    /// Positional update. `.failed` slots are skipped; `.value` slots
    /// overwrite — including `.value(.null)` (spec §5.5 Δ). Keys that were
    /// never registered are ignored, mirroring the reference, unless
    /// `includingUnknown` is set: a one-shot read (`fetch`, spec §5.4.2)
    /// stores and announces them without making them a subscription.
    package func updateKeys(_ keys: [ValueRef], _ slots: [ValueSlot], includingUnknown: Bool = false) {
        lock.lock()
        defer { lock.unlock() }
        // Yielding stays INSIDE the critical section: commit order and
        // emission order must agree across concurrent writers (spec §5.6).
        // AsyncStream.yield with a buffering policy never blocks and never
        // runs subscriber code synchronously, so this is deadlock-free.
        for (key, slot) in zip(keys, slots) {
            guard case .value(let newValue) = slot else { continue }
            guard includingUnknown || known.contains(key) else { continue }
            let oldValue = values[key]
            if oldValue != newValue {
                values[key] = newValue
                let change = StateChange(key: key, oldValue: oldValue, newValue: newValue)
                for sink in subscribers.values {
                    sink.yield(change)
                }
                for watcher in watchers.values where watcher.keys.contains(key) {
                    watcher.sink.yield(())
                }
            }
        }
    }

    // A NEW stream per call — every subscriber observes independently
    // (spec §5.5 Δ). Slow subscribers drop oldest events; the current
    // state is always available synchronously via `value(for:)`.
    /// Forgets a value: `value(for:)` returns `nil` again, as before the
    /// CLU reported it. Entities watching the key are signalled; the raw
    /// change stream is not (a change has a new value, "unknown" is none).
    /// For simulations, which must be able to show "not reported yet".
    package func clearValue(for ref: ValueRef) {
        lock.lock()
        defer { lock.unlock() }
        guard values.removeValue(forKey: ref) != nil else { return }
        for watcher in watchers.values where watcher.keys.contains(ref) {
            watcher.sink.yield(())
        }
    }

    /// A flag stream for a set of keys: one `()` after every change of any
    /// of them (spec §6.5). Changes coalesce while the consumer is busy — a
    /// buffer of one — but a change can never be lost, however many other
    /// keys change meanwhile, because the filter runs under the store lock
    /// before any buffer (spec §5.5 Δ c). The new value is in the store
    /// before the flag is observable.
    package func updates(for keys: Set<ValueRef>) -> AsyncStream<Void> {
        AsyncStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let id = UUID()
            lock.lock()
            watchers[id] = (keys, continuation)
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.watchers[id] = nil
                self.lock.unlock()
            }
        }
    }

    // Raw history, best effort (spec §5.5 Δ b): entities never observe
    // through this — see `updates(for:)`.
    /// A stream of value changes, best effort: it keeps the newest 64 when you fall behind and promises no complete history; the current value is always readable with ``value(for:)``.
    package func changes() -> AsyncStream<StateChange> {
        AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            let id = UUID()
            lock.lock()
            subscribers[id] = continuation
            lock.unlock()
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                self.lock.lock()
                self.subscribers[id] = nil
                self.lock.unlock()
            }
        }
    }
}
