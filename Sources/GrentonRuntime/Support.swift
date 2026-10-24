import Foundation
import GrentonModel

// Session lifecycle state (spec §5.4.5).
/// The connection state of one CLU.
public enum SessionState: Sendable, Equatable {
    /// Created, not started.
    case idle
    /// Connecting and subscribing.
    case starting
    /// Connected and answering.
    case ready
    // Loops keep running but the CLU is not answering; a successful ping
    // returns the session to `ready`.
    /// Not answering. The library keeps trying and returns to ``ready`` when the CLU answers again.
    case degraded
    /// Stopped by the app.
    case stopped
}

/// Why a command or a request to a CLU failed.
@nonexhaustive
public enum SessionError: Error, Sendable, Equatable {
    /// The system is not started, or has been stopped: nothing was sent.
    case notConnected
    /// The connection was closed — by `stop()` or a replacement — while the request waited.
    case connectionClosed
    /// The CLU did not answer within the response timeout.
    case timeout
    /// A request with this message id is already awaiting a response
    /// (overlapping ping, or a — vanishingly unlikely — random collision).
    case duplicateMessageId
}

/// Why a UDP connection to a CLU could not be opened.
@nonexhaustive
public enum TransportError: Error, Sendable, Equatable {
    /// Port outside 1...65535 — validated here, not in the Model (spec §3.4).
    case invalidPort(Int)
    /// The system refused the connection, for example without local-network access.
    case connectionFailed(String)
}

/// Result slot of one key of a registration or a one-shot read (spec
/// §5.4.2): distinguishes a failed chunk from a real value — including a
/// real `nil` from the CLU.
@nonexhaustive
public enum ValueSlot: Sendable, Equatable {
    /// The CLU did not answer for this key, or answered unusably; the stored value is unchanged.
    case failed
    /// The value the CLU reported, `.null` included.
    case value(GrentonValue)
}

@available(*, deprecated, renamed: "ValueSlot")
public typealias RegistrationSlot = ValueSlot

/// What one CLU connection has seen lately (spec §5.4.5, "migawka
/// diagnostyczna"): one consistent observation of one session. Times are
/// ages at the moment of sampling. Snapshots of several CLUs taken one
/// after another are not one picture of the installation.
///
/// Use it to tell the user whether the house answers:
///
/// ```swift
/// for (cluId, health) in await system.diagnostics() where health.state != .ready {
///     print(cluId, health.state, health.sinceLastReply ?? "never answered")
/// }
/// ```
public struct SessionDiagnostics: Sendable {
    /// The connection state.
    public let state: SessionState
    /// When this snapshot was taken; the ages below count back from it.
    public let sampledAt: Date
    /// How long ago the CLU last answered a request of this connection;
    /// `nil` when it has not since the last ``CluSession/start()``. A reply
    /// counts once it matches its request, even if its content then fails
    /// the operation.
    public let sinceLastReply: Duration?
    /// How long ago the CLU last pushed a report this connection accepted;
    /// `nil` when none since the last start. The values of a registration's
    /// own reply are not a report.
    public let sinceLastReport: Duration?
    /// How long the last answered ping took, from the hand-over to the
    /// transport to its reply; `nil` when no ping was answered since the
    /// last start.
    public let lastPingRoundTrip: Duration?
    /// How many keys the last registration asked for — the full list,
    /// whether or not every chunk succeeded; 0 before the first
    /// registration and after `stop()`.
    public let requestedKeyCount: Int
    /// Whether the keys must be registered again: a chunk failed or the
    /// CLU stopped answering. Cleared by a registration with no failed
    /// chunk, by registering no keys, and by `stop()`.
    public let recoveryPending: Bool
    /// Pings in a row the CLU did not answer on the current socket; three
    /// replace the socket. Without a socket, the last socket's count; 0
    /// after `stop()`.
    public let consecutivePingTimeouts: Int

    /// Creates a snapshot, for simulations and tests.
    public init(
        state: SessionState,
        sampledAt: Date = Date(),
        sinceLastReply: Duration? = nil,
        sinceLastReport: Duration? = nil,
        lastPingRoundTrip: Duration? = nil,
        requestedKeyCount: Int = 0,
        recoveryPending: Bool = false,
        consecutivePingTimeouts: Int = 0
    ) {
        self.state = state
        self.sampledAt = sampledAt
        self.sinceLastReply = sinceLastReply
        self.sinceLastReport = sinceLastReport
        self.lastPingRoundTrip = lastPingRoundTrip
        self.requestedKeyCount = requestedKeyCount
        self.recoveryPending = recoveryPending
        self.consecutivePingTimeouts = consecutivePingTimeouts
    }

    /// A connection that was never started, sampled now.
    public static var idle: SessionDiagnostics { SessionDiagnostics(state: .idle) }
}

/// Report delivered for one subscription chunk: the chunk's keys paired
/// positionally with the reported values.
public struct ChunkReport: Sendable, Equatable {
    public let keys: [ValueRef]
    public let slots: [ValueSlot]

    public init(keys: [ValueRef], slots: [ValueSlot]) {
        self.keys = keys
        self.slots = slots
    }
}

// MARK: - Injected effects (spec §7)

/// Randomness boundary (spec §7.5) — injected so tests are deterministic.
public protocol RandomSource: Sendable {
    func bytes(_ count: Int) -> [UInt8]
    func int(in range: ClosedRange<Int>) -> Int
}

public struct SystemRandomSource: RandomSource {
    public init() {}
    public func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: .min ... .max) }
    }
    public func int(in range: ClosedRange<Int>) -> Int {
        Int.random(in: range)
    }
}

extension RandomSource {
    /// 4 random bytes as 8 lowercase hex chars (spec §5.2).
    func messageId() -> String {
        bytes(4).map { String(format: "%02x", $0) }.joined()
    }
}

// Logging facade (spec §7.6) — the library never logs directly.
/// Where the library reports what happens, such as a CLU that does not answer.
///
/// Pass one to `GrentonSystem`:
///
/// ```swift
/// let logger = GrentonLogger { level, message in
///     if level >= .warning { print(message) }
/// }
/// ```
public struct GrentonLogger: Sendable {
    /// How important a message is.
    public enum Level: Int, Sendable, Comparable {
        case debug = 0, info, warning, error
        public static func < (lhs: Level, rhs: Level) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    private let handler: @Sendable (Level, String) -> Void

    /// Creates a logger that hands every message to `handler`.
    public init(handler: @escaping @Sendable (Level, String) -> Void) {
        self.handler = handler
    }

    /// Discards every message. The default.
    public static let disabled = GrentonLogger { _, _ in }

    // Prints to stdout — for CLI tools and debugging, not production apps.
    /// Prints every message, including debug detail. Meant for tools and debugging.
    public static let standardOutput = GrentonLogger { level, message in
        print("[grenton][\(level)] \(message)")
    }

    /// Every frame sent and received, and other detail.
    public func debug(_ message: @autoclosure () -> String) { handler(.debug, message()) }
    /// Milestones: a session started, a subscription renewed.
    public func info(_ message: @autoclosure () -> String) { handler(.info, message()) }
    /// A CLU that did not answer, a connection replaced; the library carries on.
    public func warning(_ message: @autoclosure () -> String) { handler(.warning, message()) }
    /// A reply the library could not use.
    public func error(_ message: @autoclosure () -> String) { handler(.error, message()) }
}
