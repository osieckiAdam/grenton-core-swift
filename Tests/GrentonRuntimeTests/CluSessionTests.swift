import Testing
import Foundation
import GrentonModel
import GrentonTestSupport
@testable import GrentonRuntime

/// CluSession against the in-memory FakeClu (spec §9.4): keep-alive,
/// chunked registration, per-socket report routing, actions, timeouts,
/// and lifecycle.
@Suite struct CluSessionTests {

    static let keyB64 = "AAECAwQFBgcICQoLDA0ODw=="
    static let ivB64 = "EBESExQVFhcYGRobHB0eHw=="

    func makeSession(
        fake: FakeClu,
        cipher: AesCbcCipher,
        timeout: Duration = .seconds(2),
        failOpens: Bool = false
    ) -> CluSession {
        CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher,
            socketFactory: InMemoryUdpSocketFactory(fake: fake, failOpens: failOpens),
            responseTimeout: timeout)
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

    @Test func registersInChunksOfThirtyOnDistinctSockets() async throws {
        let (fake, session) = try makeFixture()
        await session.start()

        let keys = attributeKeys(65)
        let slots = await session.register(keys)

        #expect(slots.count == 65)
        let registrations = await fake.registrations
        #expect(registrations.map(\.keyCount).sorted() == [5, 30, 30])
        // One dedicated socket per chunk, all distinct (spec §5.3.3 rationale).
        let sockets = registrations.map { ObjectIdentifier($0.socket) }
        #expect(Set(sockets).count == 3)
        // sid 0 — the only value live CLUs push to (spec §5.3.2).
        for registration in registrations {
            #expect(registration.sessionId == 0)
            #expect(registration.payload.hasPrefix("SYSTEM:clientRegister(0,0,1,{"))
        }
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
        // Chunks run concurrently but results must land positionally:
        // first 30 slots from one registration, last 5 from the other.
        let numbers: [Int64] = slots.compactMap {
            if case .value(.int(let n)) = $0 { return n } else { return nil }
        }
        #expect(numbers.count == 35)
        #expect(numbers[0] % 1000 == 0 && numbers[29] % 1000 == 29)
        #expect(numbers[30] % 1000 == 0 && numbers[34] % 1000 == 4)
        await session.stop()
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

    @Test func reRegistrationClosesOldSockets() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(attributeKeys(5))
        let firstSocket = try #require(await fake.registrations.first?.socket)
        #expect(!firstSocket.isClosed)

        _ = await session.register(attributeKeys(5))
        #expect(firstSocket.isClosed)
        #expect(await fake.registrations.count == 2)
        await session.stop()
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

        // Report to the SECOND registration's socket; its chunk owns the
        // 5-key tail (registration order can differ, so look it up).
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

    @Test func reportSidIsIgnoredForRegistrationAndRouting() async throws {
        // Live CLUs answer and push `clientReport:1:` although every chunk
        // registered sid 0 — routing must rely on the socket alone.
        let (fake, session) = try makeFixture()
        await fake.setReplySessionId(1)
        await session.start()
        let keys = attributeKeys(35)
        let slots = await session.register(keys)
        #expect(slots.allSatisfy { $0 != .failed })

        let stream = await session.reports()
        var iterator = stream.makeAsyncIterator()
        let registrations = await fake.registrations
        let bigIndex = try #require(registrations.firstIndex { $0.keyCount == 30 })
        let smallIndex = try #require(registrations.firstIndex { $0.keyCount == 5 })

        await fake.sendReport(registrationIndex: smallIndex, values: ["1", "2", "3", "4", "5"], sessionId: 1)
        let small = try #require(await iterator.next())
        #expect(small.keys == Array(keys[30..<35]))

        await fake.sendReport(
            registrationIndex: bigIndex, values: (0..<30).map(String.init), sessionId: 1)
        let big = try #require(await iterator.next())
        #expect(big.keys == Array(keys[0..<30]))
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
