import GrentonModel

// Frame formats of the CLU protocol (spec §5.2). Pure string work — no I/O.

/// A parsed `resp:` frame. Notifications share the format and are marked by
/// the all-zero message id (spec §5.2).
public struct WireResponse: Equatable, Sendable {
    public let cluIp: String
    /// Normalized to lowercase — the CLU may answer with uppercase hex.
    public let msgId: String
    public let payload: String
    public let raw: String

    /// Unsolicited frame (msg_id == "00000000").
    public var isNotification: Bool { msgId == WireFrame.notificationMsgId }

    /// A `clientReport` notification (spec §5.3.3).
    public var isClientReport: Bool {
        isNotification && payload.hasPrefix("clientReport:")
    }
}

public enum WireFrame {
    public static let notificationMsgId = "00000000"

    /// `req::{msg_id}:{payload}` — note the empty field after `req`.
    /// The id is normalized to lowercase on the way out (spec §5.2), so
    /// pending-request bookkeeping and the wire always agree.
    public static func request(msgId: String, payload: String) -> String {
        "req::\(msgId.lowercased()):\(payload)"
    }

    /// Parses `resp:{clu_ip}:{msg_id}:{payload}`; the payload keeps any
    /// further colons. Returns `nil` for anything else (dropped with a
    /// debug log by the session, spec §5.2).
    public static func parseResponse(_ message: String) -> WireResponse? {
        guard message.hasPrefix("resp:") else { return nil }
        let parts = message.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        return WireResponse(
            cluIp: String(parts[1]),
            msgId: parts[2].lowercased(),
            payload: String(parts[3]),
            raw: message
        )
    }
}
