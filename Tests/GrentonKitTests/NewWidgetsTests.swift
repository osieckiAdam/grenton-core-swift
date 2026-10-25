import Foundation
import Testing
import GrentonKit
import GrentonSimulation

/// The scheduler and the TV remote, as an app sees them, over the simulation.
@Suite struct NewWidgetsTests {
    static let interface = """
    {"id":"i1","version":1,"name":"T","icon":"home","theme":"GRENTON",
     "encryption":{"key":"AAECAwQFBgcICQoLDA0ODw==","iv":"EBESExQVFhcYGRobHB0eHw=="},
     "clus":[{"id":"CLU_1","serialNumber":"1","name":"C","ip":"10.0.0.1","port":1234,"connectionType":"LOCAL_ONLY"}],
     "pushNotifications":[],
     "pages":[{"name":"P","icon":"star","isFullscreenWidget":false,"widgets":[
       {"id":"sch","type":"EVENT_SCHEDULER","label":"Nocne","icon":"scheduler","object":{
         "state":{"cluId":"CLU_1","objectName":"EVE1","index":"5","callType":"ATTRIBUTE"},
         "ruleList":{"cluId":"CLU_1","objectName":"EVE1","index":"0","callType":"ATTRIBUTE"},
         "nextRule":{"cluId":"CLU_1","objectName":"EVE1","index":"2","callType":"ATTRIBUTE"},
         "currentRule":{"cluId":"CLU_1","objectName":"EVE1","index":"1","callType":"ATTRIBUTE"},
         "addRuleAction":{"cluId":"CLU_1","objectName":"EVE1","index":"2","event":"CLICK","value":"$value$","callType":"METHOD"},
         "deleteRuleAction":{"cluId":"CLU_1","objectName":"EVE1","index":"3","event":"CLICK","value":"$value$","callType":"METHOD"},
         "startAction":{"cluId":"CLU_1","objectName":"EVE1","index":"0","event":"CLICK","value":"","callType":"METHOD"},
         "stopAction":{"cluId":"CLU_1","objectName":"EVE1","index":"1","event":"CLICK","value":"","callType":"METHOD"}}},
       {"id":"tv","type":"TV_REMOTE_CONTROL","label":"TV","icon":"tv","vodLabel":"VOD","object":{
         "on":{"cluId":"CLU_1","objectName":"TVR1","index":"0","event":"CLICK","value":"1","callType":"METHOD"},
         "play":{"cluId":"CLU_1","objectName":"TVR1","index":"7","value":"1","callType":"METHOD"},
         "colour":{"cluId":"CLU_1","objectName":"TVR1","index":"9","event":"CLICK","value":"1","callType":"METHOD"}}},
       {"id":"tv2","type":"TV_REMOTE_CONTROL","label":"Pusty","icon":"tv","vodLabel":"VOD","object":{}}
     ]}]}
    """

    private func load() throws -> SimulatedGrentonSystem {
        SimulatedGrentonSystem(interface: try MobileInterfaceDTO.decode(from: Data(Self.interface.utf8)))
    }

    @Test func schedulerReadsRulesAndSendsCronQuotedByTheWire() async throws {
        let simulation = try load()
        guard case .eventSchedule(let schedule)? = simulation.entities.first(where: { $0.id == "sch_0" }) else {
            Issue.record("expected a schedule"); return
        }
        #expect(schedule.rules == nil && schedule.isActive == nil)
        simulation.set(schedule.descriptor.state, to: .int(1))
        simulation.set(schedule.descriptor.ruleList, to: .string(#"{{2, 1, "0 20 * * *"},{1, 1, "0 23 * * 6,0"}}"#))
        simulation.set(schedule.descriptor.currentRule!, to: .string("N/A"))
        simulation.set(schedule.descriptor.nextRule!, to: .string(#"{2, 1, "0 20 * * *"}"#))
        #expect(schedule.isActive == true)
        #expect(schedule.rules?.map(\.id) == [2, 1])
        #expect(schedule.currentRule == nil)
        #expect(schedule.nextRule?.id == 2)

        let added = try await schedule.addRule(hour: 22, minute: 25, days: [.monday, .tuesday, .wednesday])
        #expect(added)
        #expect(simulation.executedActions.last?.value == "25 22 * * 1,2,3")
        #expect(try await schedule.addRule(hour: 25, minute: 0, days: [.monday]) == false)
        try await schedule.deleteRule(4)
        #expect(simulation.executedActions.last?.value == "4")
        try await schedule.setActive(false)
        #expect(simulation.executedActions.last == schedule.descriptor.stopAction)
        #expect(!schedule.supportsEnablingRules && schedule.supportsStarting)
        try await schedule.enableRule(1)   // no-op without the action
        #expect(simulation.executedActions.count == 3)
    }

    @Test func remoteHasOnlyParsedButtonsAndMayBeEmpty() async throws {
        let simulation = try load()
        guard case .tvRemote(let remote)? = simulation.entities.first(where: { $0.id == "tv_0" }),
              case .tvRemote(let empty)? = simulation.entities.first(where: { $0.id == "tv2_0" }) else {
            Issue.record("expected remotes"); return
        }
        #expect(remote.buttons == [.on])   // "play" has no event, "colour" is no button
        #expect(remote.vodLabel == "VOD")
        #expect(empty.buttons.isEmpty)
        try await remote.press(.on)
        try await remote.press(.mute)       // not present: nothing sent
        #expect(simulation.executedActions.count == 1)
        #expect(remote.name == "TV" && empty.name == "Pusty")
        #expect(simulation.physicalObjects.allSatisfy { $0.key.name != "TVR1" })
    }
}
