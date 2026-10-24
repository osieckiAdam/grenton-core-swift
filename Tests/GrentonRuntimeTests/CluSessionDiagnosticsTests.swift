import Testing
import Foundation
import GrentonModel
import GrentonTestSupport
@testable import GrentonRuntime

/// The diagnostic snapshot of spec §5.4.5: what each field counts, and
/// when the fields reset.
@Suite struct CluSessionDiagnosticsTests {
    static let keyB64 = "AAECAwQFBgcICQoLDA0ODw=="
    static let ivB64 = "EBESExQVFhcYGRobHB0eHw=="

    func makeFixture(timeout: Duration = .milliseconds(200)) throws -> (FakeClu, CluSession) {
        let cipher = try AesCbcCipher(keyBase64: Self.keyB64, ivBase64: Self.ivB64)
        let fake = FakeClu(cipher: cipher)
        let session = CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1",
                     port: 1234, connectionType: .localOnly),
            cipher: cipher,
            socketFactory: InMemoryUdpSocketFactory(fake: fake),
            responseTimeout: timeout)
        return (fake, session)
    }

    func keys(_ count: Int) -> [ValueRef] {
        (0..<count).map { .attribute(cluId: "CLU_1", objectName: "OBJ", index: String($0)) }
    }

    @Test func idleBeforeStart() async throws {
        let (_, session) = try makeFixture()
        let d = await session.diagnostics
        #expect(d.state == .idle)
        #expect(d.sinceLastReply == nil && d.sinceLastReport == nil && d.lastPingRoundTrip == nil)
        #expect(d.requestedKeyCount == 0 && !d.recoveryPending && d.consecutivePingTimeouts == 0)
    }

    @Test func anEmptyListClearsRecoveryAndStreakSurvivesTheSocket() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        await fake.setSilenced { $0.hasPrefix("SYSTEM:clientRegister(") }
        _ = await session.register(keys(1))
        #expect(await session.diagnostics.recoveryPending)
        await fake.setSilenced { _ in false }
        _ = await session.register([])
        var d = await session.diagnostics
        #expect(!d.recoveryPending)
        #expect(d.requestedKeyCount == 0)

        // Three unanswered pings retire the socket; the count stays
        // visible until a new socket is installed by the next ping.
        await fake.setSilenced { $0 == "checkAlive()" }
        for _ in 0..<3 { _ = await session.ping() }
        d = await session.diagnostics
        #expect(d.consecutivePingTimeouts == 3)
        await fake.setSilenced { _ in false }
        #expect(await session.ping())
        d = await session.diagnostics
        #expect(d.consecutivePingTimeouts == 0)
        #expect(d.lastPingRoundTrip != nil)
        await session.stop()
    }

    @Test func startRecordsTheFirstPing() async throws {
        let (_, session) = try makeFixture()
        await session.start()
        let d = await session.diagnostics
        #expect(d.state == .ready)
        #expect(d.sinceLastReply != nil)
        #expect(d.lastPingRoundTrip != nil)
        #expect(d.sinceLastReport == nil)
        #expect(d.requestedKeyCount == 0)
        #expect(!d.recoveryPending)
        #expect(d.consecutivePingTimeouts == 0)
        await session.stop()
    }

    @Test func aRegistrationReplyIsNotAReport() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(keys(2))
        var d = await session.diagnostics
        #expect(d.requestedKeyCount == 2)
        #expect(!d.recoveryPending)
        #expect(d.sinceLastReport == nil)

        await fake.sendReport(registrationIndex: 0, values: ["1", "2"])
        try await Task.sleep(for: .milliseconds(50))
        d = await session.diagnostics
        #expect(d.sinceLastReport != nil)
        await session.stop()
    }

    @Test func unansweredPingsCountAndStopResets() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        _ = await session.register(keys(1))
        await fake.setSilenced { $0 == "checkAlive()" }
        #expect(await session.ping() == false)
        var d = await session.diagnostics
        #expect(d.state == .degraded)
        #expect(d.consecutivePingTimeouts == 1)
        #expect(d.recoveryPending)
        #expect(d.requestedKeyCount == 1)

        await session.stop()
        d = await session.diagnostics
        #expect(d.state == .stopped)
        #expect(d.consecutivePingTimeouts == 0)
        #expect(!d.recoveryPending)
        #expect(d.requestedKeyCount == 0)
        #expect(d.sinceLastReply == nil)
        #expect(d.lastPingRoundTrip == nil)
    }

    @Test func aFailedChunkLeavesRecoveryPendingWhileReady() async throws {
        let (fake, session) = try makeFixture()
        await session.start()
        await fake.setSilenced { $0.hasPrefix("SYSTEM:clientRegister(") }
        _ = await session.register(keys(1))
        let d = await session.diagnostics
        #expect(d.state == .ready)
        #expect(d.recoveryPending)
        // The failed chunk's request was matched by no reply; the ping's was.
        #expect(d.sinceLastReply != nil)
        await session.stop()
    }
}
