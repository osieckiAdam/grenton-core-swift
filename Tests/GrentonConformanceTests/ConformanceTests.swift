import Testing

/// Runs the grenton-core-spec conformance suite against this port.
/// Declared profiles and skips live in `port.json`.
@Suite struct ConformanceTests {
    @Test func suiteIsPresentIntactAndDeclared() throws {
        let suite = try ConformanceSuite.shared.get()
        #expect(!suite.cases.isEmpty)
        for skip in suite.port.skips {
            #expect(!skip.reason.isEmpty, "skip \(skip.id) needs a reason")
        }
        // Profiles this port does not claim are reported, not passed.
        let unclaimed = suite.unclaimedCaseIds
        if !unclaimed.isEmpty {
            print("conformance: \(unclaimed.count) case(s) outside the declared profiles \(suite.port.profiles) are not run")
        }
        #expect(!ConformanceSuite.caseIds.isEmpty, "the declared profiles contain no cases")
    }

    @Test(arguments: ConformanceSuite.caseIds)
    func conformance(_ id: String) async throws {
        let suite = try ConformanceSuite.shared.get()
        let testCase = try #require(suite.cases[id])
        let observed = try await Operations.run(testCase)
        let expected = Operations.normalizeExpected(testCase.expect)
        let difference = expected.firstDifference(from: observed)

        if suite.skippedIds.contains(id) {
            // A skip that passes is stale — fail so it gets removed.
            #expect(difference != nil, "\(id) is skipped in port.json but passes — remove the skip")
            return
        }
        #expect(difference == nil, """
            \(id) differs at \(difference ?? "")
              expected: \(expected)
              observed: \(observed)
            """)
    }
}
