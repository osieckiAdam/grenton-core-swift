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
public enum TransportError: Error, Sendable, Equatable {
    /// Port outside 1...65535 — validated here, not in the Model (spec §3.4).
    case invalidPort(Int)
    /// The system refused the connection, for example without local-network access.
    case connectionFailed(String)
}

/// Result slot of a registration position (spec §5.4.2): distinguishes a
/// failed chunk from a real value — including a real `nil` from the CLU.
public enum RegistrationSlot: Sendable, Equatable {
    /// The CLU did not answer for this key, or answered unusably; the stored value is unchanged.
    case failed
    /// The value the CLU reported, `.null` included.
    case value(GrentonValue)
}

/// Report delivered for one subscription chunk: the chunk's keys paired
/// positionally with the reported values.
public struct ChunkReport: Sendable, Equatable {
    public let keys: [ValueRef]
    public let slots: [RegistrationSlot]

    public init(keys: [ValueRef], slots: [RegistrationSlot]) {
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
