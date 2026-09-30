import Testing
import Foundation
@testable import GrentonModel

/// Tolerant widget parsing (spec §3.6): a failing element is skipped and
/// must not consume or corrupt its neighbours.
@Suite struct LossyParsingTests {

    func decodePage(_ widgetsJSON: String) throws -> PageDTO {
        let json = """
        { "name": "P", "icon": "i", "isFullscreenWidget": false, "widgets": \(widgetsJSON) }
        """
        return try JSONDecoder().decode(PageDTO.self, from: Data(json.utf8))
    }

    let validScene = """
    { "type": "SCENE", "id": "s1", "components": [
        { "type": "BUTTON_MONOSTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
          "actions": [ { "event": "CLICK", "cluId": "c", "objectName": "scr", "value": "", "callType": "SCRIPT" } ] } ] }
    """

    @Test func skipsUnknownTypeInTheMiddle() throws {
        let page = try decodePage("""
        [ { "type": "NOT_A_WIDGET", "id": "x", "payload": { "deep": [1, {"a": null}] } },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func skipsMalformedKnownType() throws {
        // ON_OFF without components + unknown enum value in unit.
        let page = try decodePage("""
        [ { "type": "ON_OFF", "id": "broken1" },
          \(validScene),
          { "type": "SCENE", "id": "broken2", "components": [
              { "type": "BUTTON_MONOSTABLE", "label": "L", "rowId": 0, "unit": "PARSECS",
                "actions": [] } ] } ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func skipsNonObjectElements() throws {
        let page = try decodePage("""
        [ 42, "text", null, [1,2], \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func actionWithoutIndexRejectsItsWidget() throws {
        let page = try decodePage("""
        [ { "type": "ON_OFF", "id": "broken", "components": [
              { "type": "BUTTON_BISTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
                "state": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
                "actions": [ { "event": "ON", "cluId": "c", "objectName": "o", "value": "1", "callType": "ATTRIBUTE" } ],
                "onIndication": "ON", "offIndication": "OFF" } ] },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func scriptActionWithoutIndexIsValid() throws {
        let dto = try JSONDecoder().decode(ActionRefDTO.self, from: Data("""
        { "event": "CLICK", "cluId": "c", "objectName": "scr", "value": "", "callType": "SCRIPT" }
        """.utf8))
        #expect(dto.index == nil)
    }

    @Test func absentComponentTypeLiteralIsAccepted() throws {
        // pydantic Literal-with-default: absent `type` applies the default.
        let page = try decodePage("""
        [ { "type": "SCENE", "id": "s-no-literal", "components": [
              { "label": "L", "rowId": 0, "unit": "UNKNOWN",
                "actions": [ { "event": "CLICK", "cluId": "c", "objectName": "scr", "value": "", "callType": "SCRIPT" } ] } ] } ]
        """)
        #expect(page.widgets.map(\.id) == ["s-no-literal"])
    }

    @Test func nullComponentTypeLiteralRejectsWidget() throws {
        // ...but an explicit null does NOT apply the default — it rejects.
        let page = try decodePage("""
        [ { "type": "SCENE", "id": "s-null-literal", "components": [
              { "type": null, "label": "L", "rowId": 0, "unit": "UNKNOWN",
                "actions": [] } ] },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test(arguments: [
        #""callType": "TELEPATHY""#,   // unknown
        #""callType": null"#,          // explicit null
        #""wrongKey": "VARIABLE""#,    // missing
    ])
    func invalidValueRefCallTypeRejectsWidget(callTypeFragment: String) throws {
        let page = try decodePage("""
        [ { "type": "VALUE_V2", "id": "broken", "label": "T", "icon": "i",
            "unit": "DEGREE", "valueType": "FLOAT", "precision": 1,
            "object": { "value": { "cluId": "c", "objectName": "o", "index": "0", \(callTypeFragment) } } },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func unknownLedComponentDiscriminatorRejectsWidget() throws {
        let page = try decodePage("""
        [ { "type": "LED", "id": "broken", "components": [
              { "type": "SLIDER_TEMPERATURE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
                "range": { "min": 0, "max": 100 },
                "state": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
                "actions": [] } ] },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func missingRequiredFieldRejectsRollerShutterV3() throws {
        // Everything present except the required setRollerBlockedAction.
        let page = try decodePage("""
        [ { "type": "ROLLER_SHUTTER_V3", "id": "broken", "icon": "i", "label": "L",
            "object": {
              "state": { "cluId": "c", "objectName": "R", "index": "0", "callType": "ATTRIBUTE" },
              "position": { "cluId": "c", "objectName": "R", "index": "1", "callType": "ATTRIBUTE" },
              "lamelPosition": { "cluId": "c", "objectName": "R", "index": "2", "callType": "ATTRIBUTE" },
              "setPositionAction": { "event": "CLICK", "cluId": "c", "objectName": "R", "index": "4", "value": "0", "callType": "METHOD" },
              "setLamelPositionAction": { "event": "CLICK", "cluId": "c", "objectName": "R", "index": "5", "value": "0", "callType": "METHOD" },
              "moveUpAction": { "event": "CLICK", "cluId": "c", "objectName": "R", "index": "6", "value": "", "callType": "METHOD" },
              "moveDownAction": { "event": "CLICK", "cluId": "c", "objectName": "R", "index": "7", "value": "", "callType": "METHOD" },
              "startAction": { "event": "CLICK", "cluId": "c", "objectName": "R", "index": "8", "value": "", "callType": "METHOD" }
            } },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }

    @Test func explicitNullOptionalDecodesAsNil() throws {
        // Optional fields supplied as explicit null behave like absent ones
        // (pydantic Optional[...] = None semantics).
        let page = try decodePage("""
        [ { "type": "CONTACT_SENSOR", "id": "cs", "label": "D", "icon": "i",
            "onIndication": "ON", "offIndication": "OFF", "reverseState": false,
            "object": {
              "value": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
              "clickAction": null } } ]
        """)
        guard case .contactSensor(let widget) = page.widgets.first else {
            Issue.record("Expected CONTACT_SENSOR")
            return
        }
        #expect(widget.object.clickAction == nil)
    }

    @Test func recordsSkipDiagnostics() throws {
        let page = try decodePage("""
        [ { "type": "NOT_A_WIDGET", "id": "x" },
          42,
          { "type": "ON_OFF", "id": "no-components" },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
        #expect(page.skippedWidgets.count == 3)
        #expect(page.skippedWidgets[0].type == "NOT_A_WIDGET")
        #expect(page.skippedWidgets[1].type == nil)
        #expect(page.skippedWidgets[2].type == "ON_OFF")
        #expect(!page.skippedWidgets[2].reason.isEmpty)
    }

    @Test func componentTypeLiteralMismatchRejectsWidget() throws {
        // A BUTTON_MONOSTABLE-typed component inside ON_OFF must reject the widget
        // (pydantic Literal semantics).
        let page = try decodePage("""
        [ { "type": "ON_OFF", "id": "broken", "components": [
              { "type": "BUTTON_MONOSTABLE", "label": "L", "rowId": 0, "unit": "UNKNOWN",
                "state": { "cluId": "c", "objectName": "o", "index": "0", "callType": "ATTRIBUTE" },
                "actions": [], "onIndication": "ON", "offIndication": "OFF" } ] },
          \(validScene) ]
        """)
        #expect(page.widgets.map(\.id) == ["s1"])
    }
}
