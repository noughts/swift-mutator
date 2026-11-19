import Testing
@testable import MutatorCore

private let source = """
func f(_ a: Int) -> Bool { a > 1 }
func g(_ a: Int) -> Int { a + 1 }
"""

private func mutantsOf(_ text: String = source) -> [Mutant] {
    analyze(file: "A.swift", source: text, options: AnalyzeOptions(excludedMutators: [.fnValue, .conditionalExpression])).mutants
}

private func snapshot(_ results: [MutantResult], tests: [TestInfo]) -> Snapshot {
    Snapshot(toolVersion: "t", envHash: "e", results: results, tests: tests, coverage: [:], scopes: [:], declarationScopes: [])
}

/// The ordered tests of a run entry; nil for other entries.
private func runTests(_ entry: PlanEntry) -> [String]? {
    if case let .run(_, tests, _) = entry { tests } else { nil }
}

private func kind(_ entry: PlanEntry) -> String {
    switch entry {
    case .ignored: "ignored"
    case .reuse: "reuse"
    case .noCoverage: "noCoverage"
    case .run: "run"
    }
}

@Suite struct PlanTests {
    let t1 = TestInfo(id: "M.T/t1", fingerprint: "1", durationMs: 30)
    let t2 = TestInfo(id: "M.T/t2", fingerprint: "2", durationMs: 10)

    @Test func withoutSnapshotCoveredMutantsRunAndOthersHaveNoCoverage() {
        let mutants = mutantsOf()
        let covered = mutants.first { $0.original == "a > 1" }!
        let entries = plan(PlanInput(mutants: mutants, tests: [t1, t2], coverage: [covered.key: [t1.id, t2.id]], previous: nil))
        let byKey = Dictionary(uniqueKeysWithValues: entries.map { ($0.mutant.key, $0) })
        #expect(kind(byKey[covered.key]!) == "run")
        #expect(kind(byKey[mutants.first { $0.original == "a + 1" }!.key]!) == "noCoverage")
        // Cheapest test first without history; timeout = 1.5 x (30 + 10) + 5000.
        #expect(runTests(byKey[covered.key]!) == [t2.id, t1.id])
        if case let .run(_, _, timeout) = byKey[covered.key]! { #expect(timeout == 5060) }
    }

    @Test func killedIsReusedWhileItsKillerIsUnchanged() {
        let mutants = mutantsOf()
        let m = mutants.first { $0.original == "a > 1" }!
        let previous = snapshot([MutantResult(mutant: m, status: .killed, killedBy: [t1.id], coveredBy: [t1.id, t2.id])], tests: [t1, t2])
        let coverage = [m.key: [t1.id, t2.id]]
        let reused = plan(PlanInput(mutants: [m], tests: [t1, t2], coverage: coverage, previous: previous))
        #expect(kind(reused[0]) == "reuse")
        // The killer changed: run again, the previous killer first.
        let edited = TestInfo(id: t1.id, fingerprint: "1b", durationMs: 30)
        let rerun = plan(PlanInput(mutants: [m], tests: [edited, t2], coverage: coverage, previous: previous))
        #expect(runTests(rerun[0]) == [t1.id, t2.id])
    }

    @Test func survivedIsReusedOnlyWithTheSameCoveringTests() {
        let m = mutantsOf().first { $0.original == "a > 1" }!
        let previous = snapshot([MutantResult(mutant: m, status: .survived, killedBy: [], coveredBy: [t1.id])], tests: [t1, t2])
        #expect(kind(plan(PlanInput(mutants: [m], tests: [t1, t2], coverage: [m.key: [t1.id]], previous: previous))[0]) == "reuse")
        // A new covering test may kill it.
        #expect(kind(plan(PlanInput(mutants: [m], tests: [t1, t2], coverage: [m.key: [t1.id, t2.id]], previous: previous))[0]) == "run")
    }

    @Test func anEditedFunctionInvalidatesItsResults() {
        let before = mutantsOf().first { $0.original == "a + 1" }!
        let previous = snapshot([MutantResult(mutant: before, status: .survived, killedBy: [], coveredBy: [t1.id])], tests: [t1])
        // Same path, mutator and replacement: same key; the function's hash changed.
        let after = mutantsOf(source.replacingOccurrences(of: "-> Int {", with: "-> Int64 {")).first { $0.original == "a + 1" }!
        #expect(after.key == before.key)
        #expect(after.scope.hash != before.scope.hash)
        #expect(kind(plan(PlanInput(mutants: [after], tests: [t1], coverage: [after.key: [t1.id]], previous: previous))[0]) == "run")
    }

    @Test func siblingKillersComeBeforeOtherTests() {
        let mutants = mutantsOf()
        let gt = mutants.filter { $0.scope.id == "f(_:)" }
        let previous = snapshot([MutantResult(mutant: gt[0], status: .killed, killedBy: [t1.id], coveredBy: [t1.id, t2.id])], tests: [t1, t2])
        let entries = plan(PlanInput(mutants: [gt[1]], tests: [t1, t2], coverage: [gt[1].key: [t1.id, t2.id]], previous: previous))
        #expect(runTests(entries[0]) == [t1.id, t2.id])
    }
}

@Suite struct TriageTests {
    @Test func outsideTheFocusARunIsPendingAndJobsAreCheapestFirst() {
        let mutants = analyze(file: "A.swift", source: "func h(_ a: Int, _ b: Int) -> Bool { a + b > a - b }").mutants
        #expect(mutants.count >= 5)
        let entries: [PlanEntry] = [
            .run(mutants[0], tests: ["M.T/a"], timeoutMs: 9000),
            .run(mutants[1], tests: ["M.T/a"], timeoutMs: 6000),
            .run(mutants[2], tests: ["M.T/a"], timeoutMs: 7000),
            .noCoverage(mutants[3]),
        ]
        let focus: [String: Focus] = [mutants[0].key: .diff, mutants[1].key: .diff]
        let (decided, jobs) = triage(entries, compileErrors: [mutants[4]], coverage: [:], focus: focus)
        #expect(jobs.map(\.mutant.key) == [mutants[1].key, mutants[0].key])
        #expect(Dictionary(uniqueKeysWithValues: decided.map { ($0.mutant.key, $0.status) }) == [mutants[2].key: .pending, mutants[3].key: .noCoverage, mutants[4].key: .compileError])
    }

    @Test func compileErrorsAreKnownWhileTheirFunctionIsUnchanged() {
        let m = mutantsOf()[0]
        let previous = snapshot([MutantResult(mutant: m, status: .compileError, killedBy: [], coveredBy: [])], tests: [])
        #expect(knownCompileErrors(previous: previous, mutants: [m]) == [m.key])
        let edited = mutantsOf(source.replacingOccurrences(of: "-> Bool {", with: "-> Swift.Bool {")).first { $0.key == m.key }!
        #expect(knownCompileErrors(previous: previous, mutants: [edited]).isEmpty)
    }
}
