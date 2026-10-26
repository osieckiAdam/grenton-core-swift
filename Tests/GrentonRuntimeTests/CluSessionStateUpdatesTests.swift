import Testing
import Foundation
import GrentonModel
import GrentonTestSupport
@testable import GrentonRuntime

@Suite struct CluSessionStateUpdatesTests {
    @Test func signalsEveryStateChange() async throws {
        let cipher = try AesCbcCipher(keyBase64: "AAECAwQFBgcICQoLDA0ODw==", ivBase64: "EBESExQVFhcYGRobHB0eHw==")
        let fake = FakeClu(cipher: cipher)
        let session = CluSession(
            clu: Clu(id: "CLU_1", serialNumber: "1", name: "Test", ip: "10.0.0.1", port: 1234, connectionType: .localOnly),
            cipher: cipher, socketFactory: InMemoryUdpSocketFactory(fake: fake), responseTimeout: .milliseconds(200))
        let updates = await session.stateUpdates()
        var iterator = updates.makeAsyncIterator()

        await session.start()                       // idle → starting → ready
        _ = await iterator.next()
        #expect(await session.state == .ready)

        await fake.setSilenced { $0 == "checkAlive()" }
        _ = await session.ping()                    // ready → degraded
        _ = await iterator.next()
        #expect(await session.state == .degraded)

        await session.stop()                        // → stopped
        _ = await iterator.next()
        #expect(await session.state == .stopped)
    }
}
