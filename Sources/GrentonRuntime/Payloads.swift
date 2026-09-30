import Foundation
import GrentonModel

// Payload construction and parsing for the CLU message catalog (spec §5.3).
// String formats are byte-for-byte contracts verified against the reference
// implementation by the conformance suite (spec §9.5 pt 4).

/// Parsed *client report* payload — the shape shared by the registration
/// response and the unsolicited notification (spec §5.3.2–5.3.3).
public struct ClientReport: Equatable, Sendable {
    /// Session id as sent by the CLU. Reliable in registration responses;
    /// NOT reliable in notifications (spec §5.3.3) — routing uses the socket.
    public let sessionId: Int
    public let values: [GrentonValue]
}

public enum PayloadError: Error, Sendable, Equatable {
    /// A registration request must carry at least one key (reference
    /// behaviour; the session never sends an empty registration).
    case emptyRegistration
    /// The action's value is still Object Manager's `$value$` placeholder:
    /// sending it would hand the CLU the literal text (spec §3.3).
    case unresolvedPlaceholder
}

public enum Payloads {
    /// Keep-alive ping (spec §5.3.1).
    public static let checkAlive = "checkAlive()"

    /// `SYSTEM:clientRegister(0,{sessionId},1,{K1,...,Kn})` (spec §5.3.2).
    /// The leading `0` and the `1` are fixed protocol constants. Key
    /// rendering is owned by `ValueRef.wireSubscriptionKey`.
    public static func clientRegister(sessionId: Int, keys: [ValueRef]) throws -> String {
        guard !keys.isEmpty else { throw PayloadError.emptyRegistration }
        let rendered = keys.map(\.wireSubscriptionKey).joined(separator: ",")
        return "SYSTEM:clientRegister(0,\(sessionId),1,{\(rendered)})"
    }

    /// Action payloads (spec §5.3.4). Values are interpolated verbatim —
    /// the injection caveat of spec §5.3.4 applies to caller-supplied input.
    public static func action(_ action: ActionRef) throws -> String {
        guard action.value != ActionRef.valuePlaceholder else { throw PayloadError.unresolvedPlaceholder }
        switch action.call {
        case .variable(let index):
            return "setVar(\"\(index)\",\"\(action.value)\")"
        case .attribute(let index):
            return "\(action.objectName):set(\(index),\"\(action.value)\")"
        case .method(let index):
            return "\(action.objectName):execute(\(index),\"\(action.value)\")"
        case .script:
            return "\(action.objectName)(\(action.value))"
        }
    }

    /// Parses `clientReport:{sessionId}:{v1,...,vn}`.
    ///
    /// `nil` when the prefix or session id is malformed. A well-formed
    /// header with malformed/missing braces yields an EMPTY value list
    /// (spec §5.3.2 pt 3): the registration path then fails the chunk via
    /// count mismatch, the notification path ignores the report.
    public static func parseClientReport(_ payload: String) -> ClientReport? {
        guard payload.hasPrefix("clientReport:") else { return nil }
        let parts = payload.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count == 3, let sessionId = Int(parts[1]) else { return nil }

        let body = parts[2]
        guard body.hasPrefix("{"), body.hasSuffix("}"), body.count >= 2 else {
            return ClientReport(sessionId: sessionId, values: [])
        }

        let content = body.dropFirst().dropLast()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else {
            return ClientReport(sessionId: sessionId, values: [])
        }

        // Positional, no escaping — a value containing a comma breaks the
        // report; documented protocol limitation (spec §10 pt 2).
        //
        // Each element is trimmed and quote-stripped HERE and again inside
        // GrentonValue(wireString:) — the reference applies both passes
        // (client_register.py + cast), so `" ON "` becomes string "ON".
        let values = content
            .split(separator: ",", omittingEmptySubsequences: false)
            .map { GrentonValue(wireString: trimAndStripQuotes($0)) }
        return ClientReport(sessionId: sessionId, values: values)
    }

    /// Python `value.strip().strip('"')` — whitespace first, then every
    /// leading/trailing double quote.
    private static func trimAndStripQuotes(_ element: Substring) -> String {
        var s = Substring(element.trimmingCharacters(in: .whitespacesAndNewlines))
        while s.first == "\"" { s = s.dropFirst() }
        while s.last == "\"" { s = s.dropLast() }
        return String(s)
    }
}
