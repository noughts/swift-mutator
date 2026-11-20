import Testing
@testable import MutatorCore

// Not in the original: how plan entries become report entries and jobs, and compile errors.

@Suite struct TriageTests {
    @Test func outsideTheFocusARunIsPendingAndJobsAreCheapestFirst() {
        let mutants = analyzed("func h(_ a: Int, _ b: Int) -> Bool { a + b > a - b }")
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

    @Test func compileErrorsAreKnownWhileTheirFunctionIsUnchanged() throws {
        let m = try #require(analyzed("func f(_ a: Int) -> Bool { a > 1 }").first)
        let previous = fixtureSnapshot([MutantResult(mutant: m, status: .compileError, killedBy: [], coveredBy: [])], [])
        #expect(knownCompileErrors(previous: previous, mutants: [m]) == [m.key])
        let edited = try #require(analyzed("func f(_ a: Int) -> Swift.Bool { a > 1 }").first { $0.key == m.key })
        #expect(knownCompileErrors(previous: previous, mutants: [edited]).isEmpty)
    }

    @Test func compileErrorsRecordedByAnUnfinishedRunAreKnownToo() throws {
        let m = try #require(analyzed("func f(_ a: Int) -> Bool { a > 1 }").first)
        #expect(knownCompileErrors(previous: nil, recorded: [m.key: m.scope.hash], mutants: [m]) == [m.key])
        #expect(knownCompileErrors(previous: nil, recorded: [m.key: "an older hash"], mutants: [m]).isEmpty)
    }
}
