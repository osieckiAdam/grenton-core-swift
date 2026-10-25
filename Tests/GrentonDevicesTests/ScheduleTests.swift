import Testing
import GrentonDevices

/// Spec §6.3.13: the CRON subset Core reads and writes, and the rule
/// list as the CLU serializes it.
@Suite struct ScheduleTests {
    @Test func readsTheListTheCluSends() {
        let rules = ScheduleRule.rules(in: #"{{2, 1, "0 20 * * *"},{1, 0, "0 23 * * 6,0"}}"#)
        #expect(rules?.map(\.id) == [2, 1])
        #expect(rules?[0].days == Set(Weekday.allCases))
        #expect(rules?[1].isEnabled == false)
        #expect(rules?[1].days == [.saturday, .sunday])
        #expect(rules?[1].hour == 23 && rules?[1].minute == 0)
    }

    @Test func readsRangesAndSevenAsSunday() {
        let rule = ScheduleRule(id: 1, isEnabled: true, cron: "15 8 * * 1-5,7")
        #expect(rule.days == [.monday, .tuesday, .wednesday, .thursday, .friday, .sunday])
    }

    @Test func keepsUnsupportedRulesAsText() {
        let rule = ScheduleRule(id: 1, isEnabled: true, cron: "*/5 8 15 * *")
        #expect(rule.hour == nil && rule.minute == nil && rule.days == nil)
        #expect(rule.cron == "*/5 8 15 * *")
    }

    @Test func noRulesKnownIsNil() {
        #expect(ScheduleRule.rules(in: "N/A") == nil)
        #expect(ScheduleRule.rules(in: "{}") == nil)
        #expect(ScheduleRule.rules(in: "") == nil)
        #expect(ScheduleRule.rules(in: #"{1, 1}"#) == nil)
    }

    @Test func writesDaysInWeekOrder() {
        #expect(ScheduleRule.cron(hour: 23, minute: 0, days: [.sunday, .saturday]) == "0 23 * * 6,0")
        #expect(ScheduleRule.cron(hour: 22, minute: 25, days: [.friday, .monday, .wednesday]) == "25 22 * * 1,3,5")
        #expect(ScheduleRule.cron(hour: 8, minute: 5, days: Set(Weekday.allCases)) == "5 8 * * *")
        #expect(ScheduleRule.cron(hour: 24, minute: 0, days: [.monday]) == nil)
        #expect(ScheduleRule.cron(hour: 8, minute: 60, days: [.monday]) == nil)
        #expect(ScheduleRule.cron(hour: 8, minute: 0, days: []) == nil)
    }
}
