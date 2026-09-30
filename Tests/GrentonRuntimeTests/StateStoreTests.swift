import Testing
import GrentonModel
@testable import GrentonRuntime

@Suite struct StateStoreTests {

    let keyA = ValueRef.attribute(cluId: "CLU_1", objectName: "A", index: "0")
    let keyB = ValueRef.variable(cluId: "CLU_1", name: "x_b")
    let keyOther = ValueRef.attribute(cluId: "CLU_2", objectName: "C", index: "0")

    @Test func registrationIsIdempotentAndOrdered() {
        let store = StateStore()
        store.registerKey(keyA)
        store.registerKey(keyB)
        store.registerKey(keyA)
        store.registerKey(keyOther)
        #expect(store.subscriptionOrder(cluId: "CLU_1") == [keyA, keyB])
        #expect(store.subscriptionOrder(cluId: "CLU_2") == [keyOther])
        #expect(Set(store.cluIdsWithKeys) == ["CLU_1", "CLU_2"])
    }

    @Test func unknownVersusNullDistinction() {
        let store = StateStore()
        store.registerKey(keyA)
        #expect(store.value(for: keyA) == nil)                     // unknown
        store.updateKeys([keyA], [.value(.null)])
        #expect(store.value(for: keyA) == .null)                   // known nil (spec §5.5 Δ)
    }

    @Test func failedSlotsAreSkipped() {
        let store = StateStore()
        store.registerKey(keyA)
        store.registerKey(keyB)
        store.updateKeys([keyA, keyB], [.value(.int(1)), .value(.int(2))])
        store.updateKeys([keyA, keyB], [.failed, .value(.int(3))])
        #expect(store.value(for: keyA) == .int(1))
        #expect(store.value(for: keyB) == .int(3))
    }

    @Test func unregisteredKeysAreIgnored() {
        let store = StateStore()
        store.updateKeys([keyA], [.value(.int(1))])
        #expect(store.value(for: keyA) == nil)
    }

    @Test func emitsOnlyRealChanges() async {
        let store = StateStore()
        store.registerKey(keyA)
        let stream = store.changes()
        var iterator = stream.makeAsyncIterator()

        store.updateKeys([keyA], [.value(.int(1))])
        store.updateKeys([keyA], [.value(.int(1))])   // no change → no event
        store.updateKeys([keyA], [.value(.int(2))])

        let first = await iterator.next()
        #expect(first == StateChange(key: keyA, oldValue: nil, newValue: .int(1)))
        let second = await iterator.next()
        #expect(second == StateChange(key: keyA, oldValue: .int(1), newValue: .int(2)))
    }

    @Test func multipleSubscribersEachReceive() async {
        let store = StateStore()
        store.registerKey(keyA)
        var first = store.changes().makeAsyncIterator()
        var second = store.changes().makeAsyncIterator()

        store.updateKeys([keyA], [.value(.bool(true))])

        #expect(await first.next()?.newValue == .bool(true))
        #expect(await second.next()?.newValue == .bool(true))
    }

    @Test func countMismatchZipsSafely() {
        let store = StateStore()
        store.registerKey(keyA)
        store.registerKey(keyB)
        // Fewer slots than keys: extra keys untouched (reference zip semantics).
        store.updateKeys([keyA, keyB], [.value(.int(9))])
        #expect(store.value(for: keyA) == .int(9))
        #expect(store.value(for: keyB) == nil)
    }
}
