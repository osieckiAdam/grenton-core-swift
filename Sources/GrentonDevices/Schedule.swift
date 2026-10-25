import Foundation
import GrentonModel

// The EventScheduler's rules (spec §6.3.13): CRON texts of the subset the
// myGrenton app writes, `minute hour * * days`, weekdays 0–6 with Sunday
// 0. The rule list arrives as a Lua table serialized into text,
// `{{2, 1, "0 20 * * *"},{1, 1, "0 23 * * 6,0"}}`, in the CLU's order.

/// A day of the week as an event scheduler counts them: Sunday is 0.
@nonexhaustive
public enum Weekday: Int, Sendable, CaseIterable, Comparable {
    case sunday = 0, monday, tuesday, wednesday, thursday, friday, saturday

    /// Monday to Sunday — the order the scheduler writes days in.
    public static let weekOrder: [Weekday] = [.monday, .tuesday, .wednesday, .thursday, .friday, .saturday, .sunday]

    /// Orders days Monday first, Sunday last.
    public static func < (lhs: Weekday, rhs: Weekday) -> Bool {
        weekOrder.firstIndex(of: lhs)! < weekOrder.firstIndex(of: rhs)!
    }
}

/// One rule of an event scheduler: when it fires, and whether it is enabled.
///
/// `hour`, `minute` and `days` are `nil` for a rule outside the subset the
/// library reads (a day of month, a step, a list of hours); ``cron`` always
/// holds the text the CLU has.
public struct ScheduleRule: Sendable, Equatable, Identifiable {
    /// The rule's number on the CLU, 1–16; what ``EventScheduleEntity/deleteRule(_:)`` takes.
    public let id: Int
    /// Whether the scheduler fires this rule.
    public let isEnabled: Bool
    /// The CRON text exactly as the CLU holds it.
    public let cron: String
    /// The hour of day, 0–23; `nil` for a rule the library cannot read.
    public let hour: Int?
    /// The minute, 0–59; `nil` for a rule the library cannot read.
    public let minute: Int?
    /// The days it fires on; `nil` for a rule the library cannot read.
    public let days: Set<Weekday>?

    /// Creates a rule, for simulations and tests.
    public init(id: Int, isEnabled: Bool, cron: String, hour: Int? = nil, minute: Int? = nil, days: Set<Weekday>? = nil) {
        self.id = id
        self.isEnabled = isEnabled
        self.cron = cron
        self.hour = hour
        self.minute = minute
        self.days = days
    }

    /// A rule with its CRON text read: `hour`, `minute` and `days` set when the text is in the subset the library reads.
    public init(id: Int, isEnabled: Bool, cron: String) {
        let parsed = ScheduleRule.parseCron(cron)
        self.init(id: id, isEnabled: isEnabled, cron: cron, hour: parsed?.hour, minute: parsed?.minute, days: parsed?.days)
    }

    // MARK: Reading (spec §6.3.13)

    /// The rules in a `ruleList` (`{{id, enabled, "cron"},…}`), `nextRule`
    /// or `currentRule` (one row) value, in the CLU's order; `nil` when the
    /// text is no such table — also `N/A` and an empty table: no rules
    /// known, not an empty list.
    public static func rules(in text: String) -> [ScheduleRule]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{"), trimmed.hasSuffix("}") else { return nil }
        let inner = Substring(trimmed.dropFirst().dropLast().trimmingCharacters(in: .whitespacesAndNewlines))
        if inner.first == "{" {
            // A list of rows: split on commas at depth 0 outside quotes.
            var rows: [Substring] = []
            var depth = 0, inText = false
            var start = inner.startIndex
            for index in inner.indices {
                switch inner[index] {
                case "\"": inText.toggle()
                case "{" where !inText: depth += 1
                case "}" where !inText: depth -= 1
                case "," where !inText && depth == 0:
                    rows.append(inner[start..<index]); start = inner.index(after: index)
                default: break
                }
            }
            guard depth == 0, !inText else { return nil }
            rows.append(inner[start...])
            let parsed = rows.compactMap { parseRow(String($0).trimmingCharacters(in: .whitespacesAndNewlines)) }
            return parsed.count == rows.count && !parsed.isEmpty ? parsed : nil
        }
        return parseRow(trimmed).map { [$0] }
    }

    /// `{id, enabled, "cron"}` → a rule: exactly two integers and one
    /// quoted text, comma-separated, whitespace allowed outside the quotes,
    /// nothing after the text (spec §6.3.13).
    private static func parseRow(_ row: String) -> ScheduleRule? {
        guard row.hasPrefix("{"), row.hasSuffix("}") else { return nil }
        let inner = row.dropFirst().dropLast()
        guard let quote = inner.firstIndex(of: "\""), let last = inner.lastIndex(of: "\""), quote < last,
              inner[inner.index(after: last)...].allSatisfy(\.isWhitespace) else { return nil }
        // Two fields, each a bare integer, each followed by its comma.
        let head = inner[..<quote].split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard head.count == 3, head[2].isEmpty, let id = Int(head[0]), let enabled = Int(head[1]) else { return nil }
        let cron = String(inner[inner.index(after: quote)..<last])
        return ScheduleRule(id: id, isEnabled: enabled == 1, cron: cron)
    }

    /// The subset of CRON the app writes: `minute hour * * days`, days `*`,
    /// a list or a range of 0–7 (7 read as Sunday).
    static func parseCron(_ cron: String) -> (hour: Int, minute: Int, days: Set<Weekday>)? {
        let fields = cron.split(separator: " ", omittingEmptySubsequences: true)
        guard fields.count == 5, fields[2] == "*", fields[3] == "*",
              let minute = Int(fields[0]), (0...59).contains(minute),
              let hour = Int(fields[1]), (0...23).contains(hour) else { return nil }
        if fields[4] == "*" { return (hour, minute, Set(Weekday.allCases)) }
        var days: Set<Weekday> = []
        // An empty item (`1,,2`, `,1`, `1,`) is outside the subset.
        for item in fields[4].split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = item.split(separator: "-", omittingEmptySubsequences: false)
            guard bounds.count <= 2, let low = Int(bounds[0]), let high = Int(bounds.last!),
                  (0...7).contains(low), (0...7).contains(high), low <= high else { return nil }
            for day in low...high { days.insert(Weekday(rawValue: day == 7 ? 0 : day)!) }
        }
        return days.isEmpty ? nil : (hour, minute, days)
    }

    // MARK: Writing (spec §6.3.13)

    /// The CRON text `addRule` sends for a time and a set of days: days in
    /// week order Monday to Sunday, all seven as `*`. `nil` when the hour,
    /// the minute or the days are out of range, or the set is empty.
    public static func cron(hour: Int, minute: Int, days: Set<Weekday>) -> String? {
        guard (0...23).contains(hour), (0...59).contains(minute), !days.isEmpty else { return nil }
        let dayField = days.count == Weekday.allCases.count
            ? "*" : days.sorted().map { String($0.rawValue) }.joined(separator: ",")
        return "\(minute) \(hour) * * \(dayField)"
    }
}
