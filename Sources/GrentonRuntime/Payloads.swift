import Foundation
import GrentonModel

// Payload construction and parsing for the CLU message catalog (spec §5.3).
// String formats are byte-for-byte contracts verified against the reference
// implementation by the conformance suite (spec §9.5 pt 4).

/// Parsed *client report* payload — the shape shared by the registration
/// response and the unsolicited notification (spec §5.3.2–5.3.3).
public struct ClientReport: Equatable, Sendable {
    /// The subscription number (spec §5.3.2): echoed in the registration
    /// reply and in every notification, which the session routes by it
    /// (spec §5.4.3).
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

    /// `SYSTEM:clientRegister(0,0,{session},{K1,...,Kn})` (spec §5.3.2): the
    /// arguments are `(ip, port, session, keys)`, and `0,0` sends the
    /// notifications to the registering socket. Key rendering is owned by
    /// `ValueRef.wireSubscriptionKey`.
    public static func clientRegister(sessionId: Int, keys: [ValueRef]) throws -> String {
        guard !keys.isEmpty else { throw PayloadError.emptyRegistration }
        let rendered = keys.map(\.wireSubscriptionKey).joined(separator: ",")
        return "SYSTEM:clientRegister(0,0,\(sessionId),{\(rendered)})"
    }

    /// `SYSTEM:clientDestroy(0,0,{session})` (spec §5.3.2): ends the
    /// subscription with that number.
    public static func clientDestroy(sessionId: Int) -> String {
        "SYSTEM:clientDestroy(0,0,\(sessionId))"
    }

    /// The default limit of a registration frame in UTF-8 bytes (spec
    /// §5.3.2): the datagram is then at most 1472 B, one IP packet at MTU 1500.
    public static let defaultRegisterFrameLimit = 1471

    /// Splits `keys`, in order, into chunks: each is the longest run whose
    /// registration frame, with the number counted as six digits, fits
    /// `limit` bytes; a key larger than the limit alone is a chunk of its
    /// own (spec §5.4.2 pt 1).
    public static func registrationChunks(_ keys: [ValueRef], frameLimit limit: Int) -> [[ValueRef]] {
        // "req::" + 8-char msg_id + ":" + "SYSTEM:clientRegister(0,0,999999,{" … "})"
        let overhead = "req::00000000:SYSTEM:clientRegister(0,0,999999,{})".utf8.count
        var chunks: [[ValueRef]] = []
        var current: [ValueRef] = []
        var size = overhead
        for key in keys {
            let keySize = key.wireSubscriptionKey.utf8.count
            let grown = size + keySize + (current.isEmpty ? 0 : 1)   // "," between keys
            if !current.isEmpty && grown > limit {
                chunks.append(current)
                current = [key]
                size = overhead + keySize
            } else {
                current.append(key)
                size = grown
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
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
