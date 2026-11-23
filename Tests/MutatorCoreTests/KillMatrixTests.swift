import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/cli/test/kill-matrix.test.ts (the cases its definitions
// share with swift-mutator), plus the preference for a subsuming test of the same file.

private func entry(_ key: String, _ status: MutantStatus, covered: [String], killed: [String] = [], incomplete: Bool = false) -> ReportEntry {
    ReportEntry(mutant: fixtureMutant(key), status: status, source: .run, killedBy: killed, coveredBy: covered, incomplete: incomplete)
}

@Suite struct KillMatrixTests {
    @Test func testsThatReachMutantsButKillNone() {
        let k = killMatrix([
            entry("m1", .killed, covered: ["a", "b"], killed: ["a"]),
            entry("m2", .survived, covered: ["b"]),
        ], tests: ["a", "b", "c"])
        #expect(k.noKills == ["b"])
        #expect(k.observations.map(\.status) == [.detected, .noKills, .notReached])
        #expect(k.mutants == KillMatrix.Mutants(full: 2, timeout: 0, incomplete: 0))
        #expect(k.tests == 3)
    }

    @Test func subsumedTestsPreferASupersetFromTheSameFile() {
        let k = killMatrix([
            entry("m1", .killed, covered: ["a", "b", "c"], killed: ["a", "b", "c"]),
            entry("m2", .killed, covered: ["b", "c"], killed: ["b", "c"]),
            entry("m3", .killed, covered: ["c"], killed: ["c"]),
        ], tests: ["a", "b", "c"], fileOf: ["a": "A.swift", "b": "A.swift", "c": "C.swift"])
        #expect(k.subsumed == [
            KillMatrix.Subsumed(test: "a", kills: 1, by: ["b", "c"]),
            KillMatrix.Subsumed(test: "b", kills: 2, by: ["c"]),
        ])
        #expect(k.duplicates.isEmpty)
    }

    @Test func testsWithTheSameKillSetAreGrouped() {
        let k = killMatrix([
            entry("m1", .killed, covered: ["a", "b", "c"], killed: ["a", "b", "c"]),
            entry("m2", .killed, covered: ["a", "b"], killed: ["a", "b"]),
        ], tests: ["a", "b", "c"])
        #expect(k.duplicates == [KillMatrix.Duplicate(tests: ["a", "b"], kills: 2)])
        #expect(k.subsumed == [KillMatrix.Subsumed(test: "c", kills: 1, by: ["a", "b"])])
    }

    @Test func crashesAndTimeoutsLeaveTheMatrix() {
        // A crash stops the tests after it: `b` may have killed m1 too.
        let k = killMatrix([
            entry("m1", .killed, covered: ["a", "b"], killed: ["a"], incomplete: true),
            entry("m2", .timeout, covered: ["a"]),
            entry("m3", .compileError, covered: []),
        ], tests: ["a", "b"])
        #expect(k.mutants == KillMatrix.Mutants(full: 0, timeout: 1, incomplete: 1))
        #expect(k.noKills.isEmpty)
        #expect(k.observations.map(\.status) == [.detected, .incomplete])
        #expect(k.subsumed.isEmpty)
    }
}
