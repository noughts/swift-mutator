import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/plan.test.ts.
//
// Not ported: static mutants, weak mutation (infection), the experimental call graph (`related`),
// `affected` tests and scopes, the kill matrix and RuntimeError, which swift-mutator does not
// have; and the paths for runs without coverage (`coverage: undefined`), since the dry run here
// always measures it. Cases that left coverage out only for brevity give it explicitly.

// ---- fixtures ---------------------------------------------------------------

private func mutant(_ key: String, file: String = "a.swift", scope: String = "f", hash: String = "h1", ignored: String? = nil) -> Mutant {
    fixtureMutant(key, file: file, scope: scope, hash: hash, ignored: ignored)
}

private func test(_ id: String, _ durationMs: Int = 10, _ fingerprint: String = "fp") -> TestInfo {
    TestInfo(id: id, fingerprint: fingerprint, durationMs: durationMs)
}

private func result(_ m: Mutant, _ status: MutantStatus, _ coveredBy: [String] = [], _ killedBy: [String] = []) -> MutantResult {
    MutantResult(mutant: m, status: status, killedBy: killedBy, coveredBy: coveredBy)
}

private func snapshot(_ results: [MutantResult], _ tests: [TestInfo], toolVersion: String = "v1", envHash: String = "e1") -> Snapshot {
    fixtureSnapshot(results, tests, toolVersion: toolVersion, envHash: envHash)
}

/// Plans like the CLI does: the snapshot counts only for the current tool version and environment.
private func planned(_ mutants: [Mutant], _ tests: [TestInfo], coverage: [String: [String]] = [:], previous: Snapshot? = nil, timeoutFactor: Double = 1.5, timeoutMs: Int = 5000) -> [PlanEntry] {
    plan(PlanInput(mutants: mutants, tests: tests, coverage: coverage, previous: previous?.valid(toolVersion: "v1", envHash: "e1"), timeoutFactor: timeoutFactor, timeoutMs: timeoutMs))
}

private func only(_ entries: [PlanEntry]) throws -> PlanEntry {
    #expect(entries.count == 1)
    return try #require(entries.first)
}

private func kind(_ entry: PlanEntry) -> String {
    switch entry {
    case .ignored: "ignored"
    case .reuse: "reuse"
    case .noCoverage: "noCoverage"
    case .run: "run"
    }
}

private func runTests(_ entry: PlanEntry) -> [String]? {
    if case let .run(_, tests, _) = entry { tests } else { nil }
}

private func timeout(_ entry: PlanEntry) -> Int? {
    if case let .run(_, _, timeoutMs) = entry { timeoutMs } else { nil }
}

// ---- toResult -----------------------------------------------------------------

@Suite struct ToResultTests {
    @Test func copiesIdentityFromTheMutant() {
        let m = mutant("k", file: "x.ts", scope: "s", hash: "hh")
        let r = MutantResult(mutant: m, status: .killed, killedBy: ["t1"], coveredBy: ["t1", "t2"], durationMs: 12)
        #expect([r.key, r.file, r.scopeId, r.scopeHash] == ["k", "x.ts", "s", "hh"])
        #expect(r.status == .killed)
        #expect(r.killedBy == ["t1"])
        #expect(r.coveredBy == ["t1", "t2"])
        #expect(r.durationMs == 12)
    }

    @Test func omitsDurationWhenNotGiven() {
        #expect(MutantResult(mutant: mutant("k"), status: .survived, killedBy: [], coveredBy: []).durationMs == nil)
    }
}

// ---- plan: basics -------------------------------------------------------------

@Suite struct PlanBasicsTests {
    @Test func returnsOneEntryPerMutantInOrder() {
        let out = planned([mutant("a"), mutant("b", ignored: "disabled"), mutant("c")], [test("t")])
        #expect(out.map(\.mutant.key) == ["a", "b", "c"])
    }

    @Test func marksIgnoredMutants() throws {
        let e = try only(planned([mutant("a", ignored: "disabled comment")], [test("t")]))
        #expect(kind(e) == "ignored")
        #expect(e.mutant.ignored == "disabled comment")
    }

    @Test func usesCurrentCoverage() throws {
        #expect(runTests(try only(planned([mutant("a")], [test("t1"), test("t2")], coverage: ["a": ["t2"]]))) == ["t2"])
    }

    @Test func isNoCoverageWhenCoverageHasNoTestsForTheKey() throws {
        #expect(kind(try only(planned([mutant("a")], [test("t1")], coverage: [:]))) == "noCoverage")
    }

    @Test func isNoCoverageWhenThereAreNoTestsAtAll() throws {
        #expect(kind(try only(planned([mutant("a")], []))) == "noCoverage")
    }
}

// ---- plan: timeout ------------------------------------------------------------

@Suite struct PlanTimeoutTests {
    @Test func defaultsToSumTimesOneAndAHalfPlusFiveSeconds() throws {
        let e = try only(planned([mutant("a")], [test("t1", 100), test("t2", 33)], coverage: ["a": ["t1", "t2"]]))
        #expect(timeout(e) == Int((133 * 1.5).rounded()) + 5000)
    }

    @Test func honoursOptions() throws {
        let e = try only(planned([mutant("a")], [test("t1", 100)], coverage: ["a": ["t1"]], timeoutFactor: 2, timeoutMs: 10))
        #expect(timeout(e) == 210)
    }

    @Test func onlyCountsTheSelectedTests() throws {
        let e = try only(planned([mutant("a")], [test("t1", 100), test("t2", 1000)], coverage: ["a": ["t1"]], timeoutFactor: 1, timeoutMs: 0))
        #expect(timeout(e) == 100)
    }
}

// ---- plan: ordering -----------------------------------------------------------

@Suite struct PlanOrderingTests {
    @Test func sortsByDurationAscendingTiesById() throws {
        let tests = [test("c", 5), test("b", 5), test("a", 1), test("z", 50)]
        let e = try only(planned([mutant("a")], tests, coverage: ["a": tests.map(\.id)]))
        #expect(runTests(e) == ["a", "b", "c", "z"])
    }

    @Test func putsTestsWithUnknownDurationLast() throws {
        #expect(runTests(try only(planned([mutant("a")], [test("t1", 50)], coverage: ["a": ["ghost", "t1"]]))) == ["t1", "ghost"])
    }

    @Test func previousKillersFirstThenSiblingKillersByCountThenTheRest() {
        let a = mutant("a")
        let s1 = mutant("s1")
        let s2 = mutant("s2")
        let other = mutant("o", scope: "g")
        let tests = ["fast", "killer", "sib1", "sib2", "far"].map { test($0, $0 == "fast" ? 1 : 100) }
        let previous = snapshot(
            [
                // A fingerprint change on 'killer' forces a re-run of `a`.
                result(a, .killed, ["killer"], ["killer"]),
                result(s1, .killed, ["sib1", "sib2"], ["sib1", "sib2"]),
                result(s2, .killed, ["sib2"], ["sib2"]),
                result(other, .killed, ["far"], ["far"]),
            ],
            tests.map { $0.id == "killer" ? test($0.id, $0.durationMs, "old") : $0 }
        )
        let e = planned([a, s1, s2, other], tests, coverage: ["a": ["far", "sib1", "fast", "sib2", "killer"]], previous: previous)[0]
        #expect(runTests(e) == ["killer", "sib2", "sib1", "fast", "far"])
    }
}

// ---- plan: cache validity -----------------------------------------------------

@Suite struct PlanCacheValidityTests {
    let a = mutant("a")
    let tests = [test("t1")]
    let coverage = ["a": ["t1"]]

    private func previous(toolVersion: String = "v1", envHash: String = "e1") -> Snapshot {
        snapshot([result(a, .survived, ["t1"])], tests, toolVersion: toolVersion, envHash: envHash)
    }

    @Test func reusesWithMatchingToolAndEnvironment() throws {
        #expect(kind(try only(planned([a], tests, coverage: coverage, previous: previous()))) == "reuse")
    }

    @Test func ignoresPreviousOnToolVersionChange() throws {
        #expect(kind(try only(planned([a], tests, coverage: coverage, previous: previous(toolVersion: "v0")))) == "run")
    }

    @Test func ignoresPreviousOnEnvironmentChange() throws {
        #expect(kind(try only(planned([a], tests, coverage: coverage, previous: previous(envHash: "e0")))) == "run")
    }

    @Test func doesNotReuseWhenTheScopeHashChanged() throws {
        #expect(kind(try only(planned([mutant("a", hash: "h2")], tests, coverage: coverage, previous: previous()))) == "run")
    }

    @Test func doesNotReuseWhenTheFileDiffers() throws {
        #expect(kind(try only(planned([mutant("a", file: "b.swift")], tests, coverage: coverage, previous: previous()))) == "run")
    }

    @Test func neverReusesAPreviousIgnoredResult() throws {
        let previous = snapshot([result(a, .ignored, ["t1"])], tests)
        #expect(kind(try only(planned([a], tests, coverage: coverage, previous: previous))) == "run")
    }

    @Test func reuseReturnsThePreviousResult() throws {
        let r = result(a, .survived, ["t1"])
        guard case let .reuse(m, reused) = try only(planned([a], tests, coverage: coverage, previous: snapshot([r], tests))) else {
            Issue.record("expected reuse")
            return
        }
        #expect(m == a)
        #expect(reused == r)
    }
}

// ---- plan: reuse rules --------------------------------------------------------

@Suite struct PlanReuseKilledTests {
    let a = mutant("a")

    @Test func reusesWhenAKillerStillExistsUnchanged() throws {
        let previous = snapshot([result(a, .killed, ["k1", "k2"], ["k1", "k2"])], [test("k1"), test("k2")])
        let e = try only(planned([a], [test("k1"), test("k2", 10, "new")], coverage: ["a": ["k1", "k2"]], previous: previous))
        #expect(kind(e) == "reuse")
    }

    @Test func runsKillerFirstWhenTheOnlyKillerChanged() throws {
        let previous = snapshot([result(a, .killed, ["fast", "k1"], ["k1"])], [test("fast", 1), test("k1", 100)])
        let e = try only(planned([a], [test("fast", 1), test("k1", 100, "new")], coverage: ["a": ["fast", "k1"]], previous: previous))
        #expect(runTests(e) == ["k1", "fast"])
    }

    @Test func runsWhenTheKillerWasRemoved() throws {
        let previous = snapshot([result(a, .killed, ["k1", "t2"], ["k1"])], [test("k1"), test("t2")])
        #expect(runTests(try only(planned([a], [test("t2")], coverage: ["a": ["t2"]], previous: previous))) == ["t2"])
    }

    @Test func runsWhenTheKillerIsAffectedByAChangedScopeItCovers() {
        let b = mutant("b", scope: "g", hash: "g1")
        let previous = snapshot([result(a, .killed, ["k1"], ["k1"]), result(b, .survived, ["k1"])], [test("k1")])
        let entries = planned([a, mutant("b", scope: "g", hash: "g2")], [test("k1")], coverage: ["a": ["k1"], "b": ["k1"]], previous: previous)
        #expect(kind(entries[0]) == "run")
    }

    @Test func runsWhenTheKillerCoveredAScopeThatNoLongerExists() throws {
        let gone = mutant("gone", scope: "deleted")
        let previous = snapshot([result(a, .killed, ["k1"], ["k1"]), result(gone, .survived, ["k1"])], [test("k1")])
        #expect(kind(try only(planned([a], [test("k1")], coverage: ["a": ["k1"]], previous: previous))) == "run")
    }
}

@Suite struct PlanReuseSurvivedTests {
    let a = mutant("a")
    let tests = [test("t1"), test("t2")]

    @Test func reusesWhenCoveringTestsAreUnaffected() throws {
        let previous = snapshot([result(a, .survived, ["t1"])], tests)
        #expect(kind(try only(planned([a], tests, coverage: ["a": ["t1"]], previous: previous))) == "reuse")
    }

    @Test func runsWhenACoveringTestChanged() throws {
        let previous = snapshot([result(a, .survived, ["t1"])], [test("t1", 10, "old"), test("t2")])
        #expect(kind(try only(planned([a], tests, coverage: ["a": ["t1"]], previous: previous))) == "run")
    }

    @Test func runsWhenACoveringTestWasRemoved() throws {
        let previous = snapshot([result(a, .survived, ["t1", "t2"])], tests)
        #expect(runTests(try only(planned([a], [test("t2")], coverage: ["a": ["t2"]], previous: previous))) == ["t2"])
    }

    @Test func runsWhenANewTestNowCoversIt() throws {
        let previous = snapshot([result(a, .survived, ["t1"])], tests)
        #expect(runTests(try only(planned([a], tests, coverage: ["a": ["t1", "t2"]], previous: previous))) == ["t1", "t2"])
    }

    @Test func runsWhenACoveringTestDependsOnAChangedScope() {
        let b = mutant("b", scope: "g", hash: "g1")
        let previous = snapshot([result(a, .survived, ["t1"]), result(b, .survived, ["t1"])], tests)
        let entries = planned([a, mutant("b", scope: "g", hash: "g2")], tests, coverage: ["a": ["t1"], "b": ["t1"]], previous: previous)
        #expect(kind(entries[0]) == "run")
    }

    @Test func isNotAffectedByAnUnrelatedTestChange() throws {
        let previous = snapshot([result(a, .survived, ["t1"])], [test("t1"), test("t2", 10, "old")])
        #expect(kind(try only(planned([a], tests, coverage: ["a": ["t1"]], previous: previous))) == "reuse")
    }
}

@Suite struct PlanReuseNoCoverageTests {
    let a = mutant("a")
    let tests = [test("t1")]

    @Test func reusesWhenCoverageIsStillEmpty() throws {
        let previous = snapshot([result(a, .noCoverage)], tests)
        #expect(kind(try only(planned([a], tests, coverage: [:], previous: previous))) == "reuse")
    }

    @Test func runsWhenCoverageNowHasTests() throws {
        let previous = snapshot([result(a, .noCoverage)], tests)
        #expect(runTests(try only(planned([a], tests, coverage: ["a": ["t1"]], previous: previous))) == ["t1"])
    }
}

@Suite struct PlanReuseTimeoutTests {
    let a = mutant("a")

    @Test func reusesWhenCoveringTestsAreUnaffected() throws {
        let previous = snapshot([result(a, .timeout, ["t1"])], [test("t1")])
        #expect(kind(try only(planned([a], [test("t1")], coverage: ["a": ["t1"]], previous: previous))) == "reuse")
    }

    @Test func runsWhenACoveringTestChanged() throws {
        let previous = snapshot([result(a, .timeout, ["t1"])], [test("t1", 10, "old")])
        #expect(kind(try only(planned([a], [test("t1")], coverage: ["a": ["t1"]], previous: previous))) == "run")
    }
}

// ---- mergeCoverage ------------------------------------------------------------
// The original merges per mutant; here coverage is kept per test, and a test that covered a
// changed scope is always measured again (`testsToMeasure`), so its stale coverage is replaced.

@Suite struct MergeCoverageTests {
    let a = mutant("a")

    private func previous(_ coverage: [String: [String]]) -> Snapshot {
        fixtureSnapshot([result(a, .survived, coverage.keys.sorted())], [], coverage: coverage, scopes: ["a.swift#f": "h1"])
    }

    @Test func keepsPreviousCoverageForTestsNotRecollectedAndAddsRecollected() {
        let merged = mergeCoverage(previous: previous(["t1": ["a"], "t2": ["a"]]), measured: ["t2": ["a"], "t3": ["a"]], tests: ["t1", "t2", "t3"], keys: ["a"])
        #expect(coverageByMutant(merged)["a"] == ["t1", "t2", "t3"])
    }

    @Test func dropsPreviousCoverageOfARecollectedTestThatNoLongerHits() {
        let merged = mergeCoverage(previous: previous(["t1": ["a"], "t2": ["a"]]), measured: ["t2": []], tests: ["t1", "t2"], keys: ["a"])
        #expect(coverageByMutant(merged)["a"] == ["t1"])
    }

    @Test func ignoresPreviousCoverageWhenTheScopeHashChanged() {
        let before = previous(["t1": ["a"]])
        let tests = [test("t1"), test("t2")]
        let measure = testsToMeasure(previous: before, tests: tests, scopes: ["a.swift#f": "h2"], extensions: [], full: false)
        #expect(measure == ["t1", "t2"])
        let merged = mergeCoverage(previous: before, measured: ["t1": [], "t2": ["a"]], tests: ["t1", "t2"], keys: ["a"])
        #expect(coverageByMutant(merged)["a"] == ["t2"])
    }

    @Test func worksWithoutPreviousAndSkipsIgnoredMutants() {
        let merged = mergeCoverage(previous: nil, measured: ["t1": ["a", "i"]], tests: ["t1"], keys: ["a"])
        #expect(coverageByMutant(merged) == ["a": ["t1"]])
    }

    @Test func aMutantCoveredByNobodyHasNoCoverage() throws {
        let coverage = coverageByMutant(mergeCoverage(previous: nil, measured: [:], tests: [], keys: ["a"]))
        #expect(coverage["a"] == nil)
        #expect(kind(try only(planned([a], [], coverage: coverage))) == "noCoverage")
    }
}

@Suite struct PendingResultTests {
    @Test func isNeverReusedButItsCoverageStillSelectsTests() throws {
        let m = mutant("k1")
        let previous = snapshot([result(m, .pending, ["t1"])], [test("t1")])
        #expect(runTests(try only(planned([m], [test("t1")], coverage: ["k1": ["t1"]], previous: previous))) == ["t1"])
    }
}
