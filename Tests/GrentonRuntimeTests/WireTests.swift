import Testing
import Foundation
import GrentonModel
@testable import GrentonRuntime

/// Frame and payload string conformance (spec §5.2–§5.3, §9.5 pt 4) —
/// every expected string is taken verbatim from the spec examples or the
/// reference implementation's format strings.
@Suite struct WireTests {

    // MARK: - Request framing

    @Test func formatsRequestFrame() {
        #expect(WireFrame.request(msgId: "aabbccdd", payload: Payloads.checkAlive)
            == "req::aabbccdd:checkAlive()")
    }

    @Test func outboundMsgIdIsLowercased() {
        #expect(WireFrame.request(msgId: "AABBCCDD", payload: Payloads.checkAlive)
            == "req::aabbccdd:checkAlive()")
    }

    @Test func registerRequestFrame() throws {
        // (ip, port, session, keys) with 0,0 = the registering socket
        // (spec §5.3.2). AES golden vector #2 (spec §9.1) still carries the
        // old argument form; it is only a cipher fixture.
        let keys: [ValueRef] = [
            .variable(cluId: "c", name: "AnalogIn1"),
            .attribute(cluId: "c", objectName: "DOU8272", index: "0"),
        ]
        let frame = WireFrame.request(
            msgId: "0f3e9a11",
            payload: try Payloads.clientRegister(sessionId: 12345, keys: keys))
        #expect(frame == "req::0f3e9a11:SYSTEM:clientRegister(0,0,12345,{\"AnalogIn1\",{DOU8272,0}})")
    }

    @Test func emptyRegistrationIsRejected() {
        #expect(throws: PayloadError.emptyRegistration) {
            _ = try Payloads.clientRegister(sessionId: 1, keys: [])
        }
    }

    // MARK: - Action payloads (spec §5.3.4)

    @Test func formatsAllActionVariants() throws {
        let variable = ActionRef(
            cluId: "c", objectName: "x_var", event: .on,
            call: .variable(index: "x_var"), value: "1")
        #expect(try Payloads.action(variable) == "setVar(\"x_var\",\"1\")")

        let attribute = ActionRef(
            cluId: "c", objectName: "DOU8272", event: .on,
            call: .attribute(index: "0"), value: "1")
        #expect(try Payloads.action(attribute) == "DOU8272:set(0,\"1\")")

        let method = ActionRef(
            cluId: "c", objectName: "DIM3333", event: .click,
            call: .method(index: "0"), value: "50.0")
        #expect(try Payloads.action(method) == "DIM3333:execute(0,\"50.0\")")

        let script = ActionRef(
            cluId: "c", objectName: "scena_wieczor", event: .click,
            call: .script, value: "\"123\"")
        #expect(try Payloads.action(script) == "scena_wieczor(\"123\")")

        let scriptNoArgs = script.withValue("")
        #expect(try Payloads.action(scriptNoArgs) == "scena_wieczor()")
    }

    // MARK: - Response parsing (spec §5.2)

    @Test func unresolvedPlaceholderIsNotSent() {
        let setPoint = ActionRef(
            cluId: "c", objectName: "THE1001", event: .click,
            call: .attribute(index: "3"), value: ActionRef.valuePlaceholder)
        #expect(throws: PayloadError.unresolvedPlaceholder) { try Payloads.action(setPoint) }
        // Overridden with a real value, it is an ordinary action.
        #expect((try? Payloads.action(setPoint.withValue("21.0"))) == "THE1001:set(3,\"21.0\")")
        // Only the exact placeholder is special.
        #expect((try? Payloads.action(setPoint.withValue("x$value$"))) != nil)
    }

    @Test func parsesResponseAndLowercasesMsgId() throws {
        let response = try #require(WireFrame.parseResponse(
            "resp:192.168.1.10:AABBCCDD:checkAlive()"))
        #expect(response.cluIp == "192.168.1.10")
        #expect(response.msgId == "aabbccdd")
        #expect(response.payload == "checkAlive()")
        #expect(!response.isNotification)
    }

    @Test func payloadKeepsFurtherColons() throws {
        let response = try #require(WireFrame.parseResponse(
            "resp:192.168.1.10:00000000:clientReport:0:{21.5,\"ON\"}"))
        #expect(response.payload == "clientReport:0:{21.5,\"ON\"}")
        #expect(response.isNotification)
        #expect(response.isClientReport)
    }

    @Test(arguments: [
        "req::aabbccdd:checkAlive()",   // request, not response
        "resp:192.168.1.10:aabbccdd",   // only 3 parts
        "resp:",
        "response:a:b:c",
        "",
    ])
    func rejectsMalformedFrames(message: String) {
        #expect(WireFrame.parseResponse(message) == nil)
    }

    @Test func acceptsEmptyFields() throws {
        // Reference splits into exactly 4 parts without content validation.
        let response = try #require(WireFrame.parseResponse("resp:::"))
        #expect(response.cluIp == "")
        #expect(response.msgId == "")
        #expect(response.payload == "")
    }

    @Test func notificationRequiresClientReportPrefix() throws {
        let response = try #require(WireFrame.parseResponse(
            "resp:192.168.1.10:00000000:somethingElse:1"))
        #expect(response.isNotification)
        #expect(!response.isClientReport)

        let nonZero = try #require(WireFrame.parseResponse(
            "resp:192.168.1.10:11223344:clientReport:0:{}"))
        #expect(!nonZero.isClientReport)
    }

    // MARK: - Client report parsing (spec §5.3.2)

    @Test func parsesClientReportValues() throws {
        let report = try #require(Payloads.parseClientReport(
            "clientReport:12345:{21.5,\"ON\",nil,true,false,42}"))
        #expect(report.sessionId == 12345)
        #expect(report.values == [
            .double(21.5), .string("ON"), .null, .bool(true), .bool(false), .int(42),
        ])
    }

    @Test func elementsAreDoubleStrippedLikeTheReference() throws {
        // Reference applies strip+quote-strip in the report parser AND in
        // the cast: `" ON "` → string "ON", ` 1 ` → int 1.
        let report = try #require(Payloads.parseClientReport(
            "clientReport:1:{ \" ON \" ,  1 }"))
        #expect(report.values == [.string("ON"), .int(1)])
    }

    @Test func reportValueMayContainColons() throws {
        let report = try #require(Payloads.parseClientReport("clientReport:1:{a:b}"))
        #expect(report.values == [.string("a:b")])
    }

    // Spec §5.3.2 pt 2: commas inside quotes and nested braces do not split.
    @Test func commasInsideQuotesAndBracesDoNotSplit() throws {
        let report = try #require(Payloads.parseClientReport(
            "clientReport:1:{\"Salon, parter\",0,{1,2,3},{{4},6},\"\"}"))
        #expect(report.values == [.string("Salon, parter"), .int(0), .string("{1,2,3}"), .string("{{4},6}"), .string("")])
    }

    @Test(arguments: [
        "clientReport:1:{\"open,1}",     // unclosed string
        "clientReport:1:{0,{1,2}",       // unclosed nested brace
        "clientReport:1:{0,}{,1}",       // closing brace at depth 0
    ])
    func unbalancedContentIsRejected(_ payload: String) {
        #expect(Payloads.parseClientReport(payload) == nil)
    }

    // MARK: - fetchValues (spec §5.3.2)

    @Test func fetchValuesPayloadAndReply() throws {
        let keys: [ValueRef] = [.variable(cluId: "C", name: "x_a"), .attribute(cluId: "C", objectName: "DOU1001", index: "0")]
        #expect(try Payloads.fetchValues(keys: keys) == "SYSTEM:fetchValues({\"x_a\",{DOU1001,0}})")
        #expect(throws: PayloadError.emptyRegistration) { try Payloads.fetchValues(keys: []) }
        #expect(Payloads.parseValues("values:{1,nil,\"ON\",{2,3}}") == [.int(1), .null, .string("ON"), .string("{2,3}")])
        #expect(Payloads.parseValues("values:{}") == [])
        #expect(Payloads.parseValues("values:}") == nil)          // the CLU's reply to an empty list
        #expect(Payloads.parseValues("clientReport:1:{1}") == nil)
        #expect(Payloads.parseValues("values:{\"a}") == nil)
    }

    @Test func fetchChunksCountTheFetchFrame() {
        let keys: [ValueRef] = [.variable(cluId: "C", name: "x_a"), .attribute(cluId: "C", objectName: "DOU1001", index: "0")]
        // "req::00000000:SYSTEM:fetchValues({"x_a",{DOU1001,0}})" is 53 bytes; alone 41 and 47.
        #expect(Payloads.fetchChunks(keys, frameLimit: 53).count == 1)
        #expect(Payloads.fetchChunks(keys, frameLimit: 52).count == 2)
        #expect(Payloads.registrationChunks(keys, frameLimit: 53).count == 2)   // the register frame is longer
    }

    @Test(arguments: [
        ("clientReport:7:{}", 7, [GrentonValue]()),
        ("clientReport:7:{   }", 7, []),
        ("clientReport:7:", 7, []),                   // empty body, valid header
        ("clientReport:7:no-braces", 7, []),          // malformed body → empty list
        ("clientReport:7:{21.5", 7, []),              // unterminated brace
    ])
    func malformedBodyYieldsEmptyValues(payload: String, sessionId: Int, values: [GrentonValue]) throws {
        let report = try #require(Payloads.parseClientReport(payload))
        #expect(report.sessionId == sessionId)
        #expect(report.values == values)
    }

    @Test(arguments: [
        "clientReport:abc:{1}",     // non-numeric session id
        "clientReport:",            // missing parts
        "somethingElse:1:{1}",
    ])
    func malformedHeaderIsRejected(payload: String) {
        #expect(Payloads.parseClientReport(payload) == nil)
    }

    @Test func emptyElementsCastToEmptyStrings() throws {
        let report = try #require(Payloads.parseClientReport("clientReport:1:{a,,b}"))
        #expect(report.values == [.string("a"), .string(""), .string("b")])
    }

    // MARK: - End-to-end: frame → cipher → frame

    @Test func pingRoundTripThroughCipher() throws {
        let cipher = try AesCbcCipher(
            keyBase64: "AAECAwQFBgcICQoLDA0ODw==",
            ivBase64: "EBESExQVFhcYGRobHB0eHw==")
        let frame = WireFrame.request(msgId: "aabbccdd", payload: Payloads.checkAlive)
        let encrypted = try cipher.encrypt(Data(frame.utf8))
        let decrypted = try #require(cipher.decrypt(encrypted))
        #expect(String(data: decrypted, encoding: .utf8) == frame)
    }
}
