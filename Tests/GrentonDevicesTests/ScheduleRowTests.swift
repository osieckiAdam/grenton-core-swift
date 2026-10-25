import Testing
import GrentonDevices

/// Spec §6.3.13: a row is exactly `{int, int, "text"}`; anything else makes
/// the whole text "no rules known".
@Suite struct ScheduleRowTests {
    @Test func rejectsRowsOfAnotherShape() {
        #expect(ScheduleRule.rules(in: #"{{1, 1 "0 20 * * *"}}"#) == nil)
        #expect(ScheduleRule.rules(in: #"{{1,, 1, "0 20 * * *"}}"#) == nil)
        #expect(ScheduleRule.rules(in: #"{{1, 1, "0 20 * * *", 5}}"#) == nil)
        #expect(ScheduleRule.rules(in: #"{{1, 1, "0 20 * * *"}, {2, 1}}"#) == nil)
    }

    @Test func allowsWhitespaceOutsideTheQuotes() {
        let rules = ScheduleRule.rules(in: "{ {2, 1, \"0 20 * * *\"} ,\n { 1 , 0 , \"0 23 * * 6,0\" } }")
        #expect(rules?.map(\.id) == [2, 1])
    }

    @Test func emptyDayItemsAreUnsupported() {
        for cron in ["0 20 * * 1,,2", "0 20 * * ,1", "0 20 * * 1,"] {
            let rule = ScheduleRule(id: 1, isEnabled: true, cron: cron)
            #expect(rule.days == nil && rule.hour == nil, Comment(rawValue: cron))
        }
    }
}
