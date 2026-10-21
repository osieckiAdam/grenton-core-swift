import Testing
import Foundation
import GrentonModel
import GrentonTestSupport
@testable import GrentonRuntime

/// CluSession against the in-memory FakeClu (spec §9.4): keep-alive,
/// chunked registration under subscription numbers on the main socket,
/// report routing by number, actions, timeouts, and lifecycle.
@Suite struct CluSessionTests {

    static let keyB64 = "AAECAwQFBgcICQoLDA0ODw=="
    static let ivB64 = "EBESExQVFhcYGRobHB0eHw=="

    func makeSession(
        fake: FakeClu,
        cipher: AesCbcCipher,
        timeout: Duration = .seconds(2),
        failOpens: Bool = false,
        // 309 B fits exactly 30 of the `{OBJ,n}` keys below, as in the
        // conformance scenarios.
        registerFrameLimit: Int = 309
    ) -> CluSession {
        CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher,
            socketFactory: InMemoryUdpSocketFactory(fake: fake, failOpens: failOpens),
            responseTimeout: timeout,
            registerFrameLimit: registerFrameLimit)
    }

    func makeFixture(timeout: Duration = .seconds(2)) throws -> (FakeClu, CluSession) {
        let cipher = try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64)
        let fake = FakeClu(cipher: cipher)
        return (fake, makeSession(fake: fake, cipher: cipher, timeout: timeout))
    }

    func attributeKeys(_ count: Int) -> [ValueRef] {
        (0..<count).map { .attribute(cluId: "CLU_1", objectName: "OBJ", index: String($0)) }
    }

    // MARK: - Lifecycle & ping

    @Test func pingAndRegisterBeforeStartSendNothing() async throws {
        let (fake, session) = try makeFixture()
        #expect(await session.ping() == false)
        #expect(await session.register(attributeKeys(2)) == [.failed, .failed])
        #expect(await fake.receivedPayloads.isEmpty)
        #expect(await fake.openedSockets.isEmpty)
        #expect(await session.state == .idle)
    }

    @Test func droppingASessionWithoutStopClosesItsSocket() async throws {
        let (fake, _) = try makeFixture()
        weak var dropped: CluSession?
        do {
            let session = makeSession(fake: fake, cipher: try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64))
            await session.start()
            _ = await session.register(attributeKeys(2))
            #expect(await session.state == .ready)
            dropped = session
        }
        // The routers hold the session weakly, so letting go of it runs
        // deinit, which closes the socket and ends the router loop.
        for _ in 0..<50 where dropped != nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(dropped == nil)
        #expect(await fake.openedSockets.last?.isClosed == true)
        // No clientDestroy: only stop() sends it; the CLU's lease expires.
        #expect(await fake.destroyedNumbers.isEmpty)
    }

    @Test func startPingsAndBecomesReady() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        #expect(await session.state == .ready)

        let payloads = await fake.receivedPayloads
        #expect(payloads == ["checkAlive()"])

        // Ping reuses the constant keepAliveId (spec §5.3.1).
        await session.ping()
        let ids = await fake.receivedMsgIds
        #expect(ids.count == 2)
        #expect(ids[0] == ids[1])
        #expect(ids[0].count == 8)
        #expect(ids[0] == ids[0].lowercased())
        await session.stop()
    }

    @Test func pingTimeoutDegradesSession() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(80))
        await fake.setSilenced { $0 == "checkAlive()" }
        await session.start()
        #expect(await session.state == .degraded)
        let ok = await session.ping()
        #expect(!ok)
        await session.stop()
    }

    @Test func startIsIdempotentAndRestartable() async throws {
        let (_, session) = try makeFixture()
        await session.start()
        await session.start()
        #expect(await session.state == .ready)
        await session.stop()
        #expect(await session.state == .stopped)
        await session.stop()
        await session.start()
        #expect(await session.state == .ready)
        await session.stop()
    }

    // MARK: - Registration & chunking (spec §5.4.2)

    @Test func registersChunksAsNumberedSubscriptionsOnTheMainSocket() async throws {
        let (fake, session) = try makeFixture()
        await session.start()

        let keys = attributeKeys(65)
        let slots = await session.register(keys)

        #expect(slots.count == 65)
        let registrations = await fake.registrations
        // 309 B takes 30 keys while indexes have one or two digits, then
        // only 28 of the two-digit ones: the split counts bytes.
        #expect(registrations.map(\.keyCount) == [30, 28, 7])
        // Every chunk from the one socket, under its own number (spec §5.4.2).
        let sockets = registrations.map { ObjectIdentifier($0.socket) }
        #expect(Set(sockets).count == 1)
        #expect(await fake.openedSockets.count == 1)
        #expect(registrations.map(\.sessionId) == [1, 2, 3])
        #expect(registrations.map { $0.payload.hasPrefix("SYSTEM:clientRegister(0,0,\($0.sessionId),{") } == [true, true, true])
        await session.stop()
    }

    @Test func initialValuesComeBackPositionally() async throws {
        let (fake, session) = try makeFixture()
        // Distinguish chunks: values encode registration index and position.
        await fake.setRegistrationValues { registrationIndex, keyCount in
            (0..<keyCount).map { "\(registrationIndex * 1000 + $0)" }
        }
        await session.start()

        let slots = await session.register(attributeKeys(35))
        #expect(slots.count == 35)
        // Chunks are registered one after another (spec §5.4.2), so the
        // 30-key chunk is registration 0 and the 5-key chunk registration 1,
        // and results land positionally.
        let numbers: [Int64] = slots.compactMap {
            if case .value(.int(let n)) = $0 { return n } else { return nil }
        }
        #expect(numbers.count == 35)
        #expect(numbers[0] == 0 && numbers[29] == 29)
        #expect(numbers[30] == 1000 && numbers[34] == 1004)
        await session.stop()
    }

    @Test func nextChunkWaitsForThePreviousOne() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(400))
        // The first chunk never answers; the second must not be sent until
        // the first has timed out.
        await fake.setSilenced {
            $0.hasPrefix("SYSTEM:clientRegister(")
                && FakeClu.parseRegistration($0).keyCount == 30
        }
        await session.start()
        let registering = Task { await session.register(attributeKeys(35)) }
        try await Task.sleep(for: .milliseconds(150))
        let sentSoFar = await fake.receivedPayloads.filter { $0.hasPrefix("SYSTEM:clientRegister(") }
        #expect(sentSoFar.count == 1)
        _ = await registering.value
        let sentInTotal = await fake.receivedPayloads.filter { $0.hasPrefix("SYSTEM:clientRegister(") }
        #expect(sentInTotal.count == 2)
        await session.stop()
    }

    // The limit may be lowered, never raised past 1471 B (spec §5.4.2 pt 1):
    // 0 and -5 clamp to 1 B, so every key is a chunk of its own; 5000 clamps
    // to 1471 B, which takes all 35 short keys at once.
    @Test(arguments: [(0, 1), (-5, 1), (5000, 35), (309, 30)])
    func frameLimitIsClampedToTheDefault(requested: Int, firstChunk: Int) async throws {
        let cipher = try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64)
        let fake = FakeClu(cipher: cipher)
        let session = makeSession(fake: fake, cipher: cipher, registerFrameLimit: requested)
        await session.start()
        _ = await session.register(attributeKeys(35))
        let sizes = await fake.registrations.map(\.keyCount)
        #expect(sizes.reduce(0, +) == 35)
        #expect(sizes.first == firstChunk)
        await session.stop()
    }

    @Test func chunksAreSplitByFrameBytesNotKeyCount() {
        // 30 long variable names exceed the default 1471 B; 30 short keys do not.
        let long = (0..<30).map { ValueRef.variable(cluId: "CLU_1", name: "VERY_LONG_VARIABLE_NAME_\($0)_" + String(repeating: "X", count: 30)) }
        #expect(Payloads.registrationChunks(long, frameLimit: Payloads.defaultRegisterFrameLimit).count == 2)
        #expect(Payloads.registrationChunks(attributeKeys(30), frameLimit: Payloads.defaultRegisterFrameLimit).count == 1)
        // A key larger than the limit is a chunk of its own.
        let huge = ValueRef.variable(cluId: "CLU_1", name: String(repeating: "Y", count: 2000))
        #expect(Payloads.registrationChunks([huge] + attributeKeys(2), frameLimit: 1471).map(\.count) == [1, 2])
    }

    @Test func failedChunkYieldsFailedSlotsPositionally() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(80))
        // Silence the 30-key registration; the 5-key one succeeds.
        await fake.setSilenced {
            $0.hasPrefix("SYSTEM:clientRegister(")
                && FakeClu.parseRegistration($0).keyCount == 30
        }
        await session.start()

        let slots = await session.register(attributeKeys(35))
        #expect(slots.count == 35)
        #expect(slots[0..<30].allSatisfy { $0 == .failed })
        #expect(slots[30..<35].allSatisfy { $0 != .failed })
        await session.stop()
    }

    @Test func reRegistrationReusesTheSocketAndNumber() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(5))
        _ = await session.register(attributeKeys(5))
        let registrations = await fake.registrations
        #expect(registrations.count == 2)
        #expect(registrations.map(\.sessionId) == [1, 1])
        #expect(registrations[0].socket === registrations[1].socket)
        #expect(!registrations[0].socket.isClosed)
        #expect(await fake.destroyedNumbers.isEmpty)
        await session.stop()
    }

    @Test func aChangedListGetsANewNumberAndTheOldOneIsDestroyed() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(5))
        _ = await session.register(attributeKeys(4))
        #expect(await fake.registrations.map(\.sessionId) == [1, 2])
        #expect(await fake.destroyedNumbers == [1])
        await session.stop()
    }

    @Test func stopDestroysEverySubscription() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(35))
        await session.stop()
        #expect(await fake.destroyedNumbers == [1, 2])
    }

    @Test func emptyRegistrationSendsNothing() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        let slots = await session.register([])
        #expect(slots.isEmpty)
        #expect(await fake.registrations.isEmpty)
        await session.stop()
    }

    // MARK: - Report routing (spec §5.4.3)

    @Test func routesReportsToTheRegisteringChunk() async throws {
        let (fake, session) = try makeFixture()
        await session.start()

        let keys = attributeKeys(35)
        _ = await session.register(keys)

        let stream = await session.reports()
        var iterator = stream.makeAsyncIterator()

        // Report with the SECOND registration's number; its chunk owns the
        // 5-key tail.
        let registrations = await fake.registrations
        let smallIndex = try #require(registrations.firstIndex { $0.keyCount == 5 })
        await fake.sendReport(
            registrationIndex: smallIndex,
            values: ["1", "\"ON\"", "nil", "true", "21.5"])

        let report = try #require(await iterator.next())
        #expect(report.keys.count == 5)
        #expect(report.keys == Array(keys[30..<35]))
        #expect(report.slots == [
            .value(.int(1)), .value(.string("ON")), .value(.null),
            .value(.bool(true)), .value(.double(21.5)),
        ])
        await session.stop()
    }

    @Test func theNumberInARegistrationReplyIsNotChecked() async throws {
        // Correlated by msg_id (spec §5.3.2 pt 1).
        let (fake, session) = try makeFixture()
        await fake.setReplySessionId(99)
        await session.start()
        let slots = await session.register(attributeKeys(35))
        #expect(slots.allSatisfy { $0 != .failed })
        await session.stop()
    }

    @Test func reportsAreRoutedByNumberAndUnknownOnesDropped() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        let keys = attributeKeys(35)
        _ = await session.register(keys)

        let stream = await session.reports()
        var iterator = stream.makeAsyncIterator()
        // An unknown number, then a known number with the wrong count: both dropped.
        await fake.sendReport(registrationIndex: 0, values: ["1"], sessionId: 7)
        await fake.sendReport(registrationIndex: 0, values: ["1", "2"], sessionId: 2)
        // Number 1 owns the first 30 keys whatever socket the report used.
        await fake.sendReport(registrationIndex: 1, values: (0..<30).map(String.init), sessionId: 1)
        let report = try #require(await iterator.next())
        #expect(report.keys == Array(keys[0..<30]))
        await session.stop()
    }

    @Test func garbageDatagramsAreDroppedSilently() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        await fake.sendGarbageToLastSocket()
        // Session still healthy afterwards.
        #expect(await session.ping())
        await session.stop()
    }

    // MARK: - Actions

    @Test func executesActionOverMainSocket() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        let action = ActionRef(
            cluId: "CLU_1", objectName: "DOU8272", event: .on,
            call: .attribute(index: "0"), value: "1")
        try await session.execute(action)
        let payloads = await fake.receivedPayloads
        #expect(payloads.contains("DOU8272:set(0,\"1\")"))
        await session.stop()
    }

    @Test func unresolvedPlaceholderActionIsNotSent() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        let setPoint = ActionRef(
            cluId: "CLU_1", objectName: "THE1001", event: .click,
            call: .attribute(index: "3"), value: ActionRef.valuePlaceholder)
        await #expect(throws: PayloadError.unresolvedPlaceholder) { try await session.execute(setPoint) }
        let payloads = await fake.receivedPayloads
        #expect(!payloads.contains { $0.contains("$value$") })
        await session.stop()
    }

    @Test func actionTimeoutThrows() async throws {
        let (fake, session) = try makeFixture(timeout: .milliseconds(80))
        await session.start()
        await fake.setSilenced { $0.hasPrefix("DOU") }
        let action = ActionRef(
            cluId: "CLU_1", objectName: "DOU8272", event: .off,
            call: .attribute(index: "0"), value: "0")
        await #expect(throws: SessionError.timeout) {
            try await session.execute(action)
        }
        await session.stop()
    }

    @Test func executeAfterStopThrowsNotConnected() async throws {
        let (_, session) = try makeFixture()
        await session.start()
        await session.stop()
        let action = ActionRef(
            cluId: "CLU_1", objectName: "DOU8272", event: .on,
            call: .attribute(index: "0"), value: "1")
        await #expect(throws: SessionError.notConnected) {
            try await session.execute(action)
        }
    }

    // MARK: - Failure handling

    @Test func socketOpenFailureDegradesAndRegisterFails() async throws {
        let cipher = try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64)
        let fake = FakeClu(cipher: cipher)
        let session = makeSession(fake: fake, cipher: cipher, failOpens: true)
        await session.start()
        #expect(await session.state == .degraded)
        let slots = await session.register(attributeKeys(3))
        #expect(slots == [.failed, .failed, .failed])
        await session.stop()
    }

    @Test func stopFailsInFlightRequests() async throws {
        let (fake, session) = try makeFixture(timeout: .seconds(5))
        await session.start()
        await fake.setSilenced { $0.hasPrefix("SYSTEM:clientRegister(") }

        // Registration hangs on a silenced fake; stop() must fail it fast
        // (well under the 5 s timeout), not deadlock on the gate.
        async let slots = session.register(attributeKeys(3))
        try await Task.sleep(for: .milliseconds(50))
        await session.stop()
        let result = await slots
        #expect(result == [.failed, .failed, .failed])
        #expect(await session.state == .stopped)
    }
}
