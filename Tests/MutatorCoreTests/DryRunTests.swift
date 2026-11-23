import Testing
@testable import MutatorCore

@Suite struct DryRunTests {
    let tests = [TestInfo(id: "M.T/a", fingerprint: "a", durationMs: 1), TestInfo(id: "M.T/b", fingerprint: "b", durationMs: 1)]
    let mutant = fixtureMutant("k1", file: "A.swift", scope: "f()")

    private func previous(scopes: [String: String], declarations: [String] = []) -> Snapshot {
        fixtureSnapshot([MutantResult(mutant: mutant, status: .survived, killedBy: [], coveredBy: ["M.T/a"])], tests, coverage: ["M.T/a": ["k1"], "M.T/b": []], scopes: scopes, declarationScopes: declarations)
    }

    @Test func everythingWithoutSnapshotOrWhenForced() {
        #expect(testsToMeasure(previous: nil, tests: tests, scopes: [:], extensions: [], full: false) == ["M.T/a", "M.T/b"])
        #expect(testsToMeasure(previous: previous(scopes: ["A.swift#f()": "h1"]), tests: tests, scopes: ["A.swift#f()": "h1"], extensions: [], full: true).count == 2)
    }

    @Test func nothingWhenNothingChanged() {
        #expect(testsToMeasure(previous: previous(scopes: ["A.swift#f()": "h1"]), tests: tests, scopes: ["A.swift#f()": "h1"], extensions: [], full: false).isEmpty)
    }

    @Test func testsThatCoveredAnEditedFunction() {
        #expect(testsToMeasure(previous: previous(scopes: ["A.swift#f()": "h1"]), tests: tests, scopes: ["A.swift#f()": "h2"], extensions: [], full: false) == ["M.T/a"])
    }

    @Test func newAndChangedTests() {
        let now = [TestInfo(id: "M.T/a", fingerprint: "a", durationMs: 1), TestInfo(id: "M.T/b", fingerprint: "b2", durationMs: 1), TestInfo(id: "M.T/c", fingerprint: "c", durationMs: 1)]
        #expect(testsToMeasure(previous: previous(scopes: ["A.swift#f()": "h1"]), tests: now, scopes: ["A.swift#f()": "h1"], extensions: [], full: false) == ["M.T/b", "M.T/c"])
    }

    @Test func aChangedTypeMeasuresEverything() {
        let before = previous(scopes: ["A.swift#f()": "h1", "A.swift#Cart": "t1"], declarations: ["A.swift#Cart"])
        #expect(testsToMeasure(previous: before, tests: tests, scopes: ["A.swift#f()": "h1", "A.swift#Cart": "t2"], extensions: [], full: false).count == 2)
        // Removed.
        #expect(testsToMeasure(previous: before, tests: tests, scopes: ["A.swift#f()": "h1"], extensions: [], full: false).count == 2)
    }

    @Test func aNewTypeMeasuresNothingButANewExtensionEverything() {
        let before = previous(scopes: ["A.swift#f()": "h1"])
        let scopes = ["A.swift#f()": "h1", "B.swift#Extent": "t1"]
        #expect(testsToMeasure(previous: before, tests: tests, scopes: scopes, extensions: [], full: false).isEmpty)
        #expect(testsToMeasure(previous: before, tests: tests, scopes: scopes, extensions: ["B.swift#Extent"], full: false).count == 2)
    }
}
