import Foundation
import GrentonModel

// A single state change, emitted only when the stored value actually
// changed (spec §5.5 Δ).
/// One value that changed on a CLU.
public struct StateChange: Sendable, Equatable {
    public let key: ValueRef
    public let oldValue: GrentonValue?
    public let newValue: GrentonValue
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
    package func updateKeys(_ keys: [ValueRef], _ slots: [RegistrationSlot], includingUnknown: Bool = false) {
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
            }
        }
    }

    // A NEW stream per call — every subscriber observes independently
    // (spec §5.5 Δ). Slow subscribers drop oldest events; the current
    // state is always available synchronously via `value(for:)`.
    /// A stream of every value change. It drops the oldest changes when you fall behind; the current value is always readable with ``value(for:)``.
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
