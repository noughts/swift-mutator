import Foundation
import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/cli/test/mte-report.test.ts and gate.test.ts.
//
// Not ported: validation with the published JSON schema (no validator here), and accepted mutants,
// type-proven equivalents, uncollected test files, child processes and critical regions, which
// swift-mutator does not have.

private let source = "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\n"

private func entry(_ file: String, _ key: String, _ status: MutantStatus, killedBy: [String] = [], coveredBy: [String] = [], ignored: String? = nil, location: Location = Location(start: Position(line: 2, column: 11), end: Position(line: 2, column: 16))) -> ReportEntry {
    let mutant = fixtureMutant(key, file: file, scope: "add(_:_:)", span: Span(start: 50, end: 55), scopeSpan: Span(start: 0, end: 58), original: "a + b", replacement: "a - b", location: location, ignored: ignored)
    return ReportEntry(mutant: mutant, status: status, source: .run, killedBy: killedBy, coveredBy: coveredBy)
}

private let entries = [
    entry("Sources/M/Add.swift", "k1", .killed, killedBy: ["MTests.AddTests/testSums"], coveredBy: ["MTests.AddTests/testSums", "MTests.AddTests/testZero"]),
    entry("Sources/M/Add.swift", "k2", .survived, coveredBy: ["MTests.AddTests/testZero"]),
    entry("Sources/M/Add.swift", "k3", .ignored, ignored: "disabled by comment"),
    entry("Sources/M/Add.swift", "k4", .pending),
    entry("Sources/M/Util.swift", "k5", .noCoverage, location: Location(start: Position(line: 1, column: 17), end: Position(line: 1, column: 18))),
]

private let sources = ["Sources/M/Add.swift": source, "Sources/M/Util.swift": "public let x = 1 + 1 + 1 + 1\n"]

private func report(thresholds: Thresholds = Thresholds()) -> MTEReport {
    mutationTestingReport(entries, sources: sources, projectRoot: "/p", version: "9.9.9", thresholds: thresholds, diffOnly: false)
}

@Suite struct MutationTestingJsonTests {
    @Test func topLevelMetadata() {
        let json = report()
        #expect(json.schemaVersion == "2")
        #expect(json.thresholds == ["high": 80, "low": 60])
        #expect(json.projectRoot == "/p")
        #expect(json.framework.name == "swift-mutator")
        #expect(json.framework.version == "9.9.9")
    }

    @Test func filesKeyedByRelativePathWithLanguageAndSource() {
        let json = report()
        #expect(json.files.keys.sorted() == ["Sources/M/Add.swift", "Sources/M/Util.swift"])
        #expect(json.files["Sources/M/Add.swift"]?.language == "swift")
        #expect(json.files["Sources/M/Add.swift"]?.source == source)
    }

    @Test func mutantsUseOneBasedColumnsAndMapStatuses() throws {
        let mutants = try #require(report().files["Sources/M/Add.swift"]?.mutants)
        let killed = mutants[0]
        #expect(killed.id == "k1")
        #expect(killed.mutatorName == "ArithmeticOperator")
        #expect(killed.replacement == "a - b")
        let span: [Int] = [killed.location.start.line, killed.location.start.column, killed.location.end.line, killed.location.end.column]
        #expect(span == [2, 12, 2, 17])
        #expect(killed.status == "Killed")
        #expect(killed.killedBy == ["MTests.AddTests/testSums"])
        #expect(killed.coveredBy == ["MTests.AddTests/testSums", "MTests.AddTests/testZero"])
        #expect(killed.statusReason == nil)
        #expect(mutants[1].status == "Survived")
        #expect(mutants[2].status == "Ignored")
        #expect(mutants[2].statusReason == "disabled by comment")
        #expect(mutants[3].status == "Pending")
        let unreached = try #require(report().files["Sources/M/Util.swift"]?.mutants.first)
        #expect(unreached.status == "NoCoverage")
        #expect(unreached.location.start.column == 18)
    }

    @Test func testFilesListEveryReferencedTestOnce() {
        let tests = report().testFiles
        #expect(tests.keys.sorted() == ["MTests"])
        #expect(tests["MTests"]?.tests.map(\.id) == ["MTests.AddTests/testSums", "MTests.AddTests/testZero"])
        #expect(tests["MTests"]?.tests.map(\.name) == ["AddTests/testSums", "AddTests/testZero"])
    }

    @Test func testFilesAreKeyedByPathWithLocationsAndListEveryCollectedTest() throws {
        let testSource = "import XCTest\nfinal class AddTests: XCTestCase {\n    func testSums() {}\n    func testZero() {}\n    func testUnused() {}\n}\n"
        let path = "Tests/MTests/AddTests.swift"
        let ids = ["MTests.AddTests/testSums", "MTests.AddTests/testUnused", "MTests.AddTests/testZero", "MTests.Gone/testX"]
        let catalog = TestCatalog(ids: ids, locations: testLocations(ids: ids, modules: ["MTests": [TestSource(path: path, text: testSource)]]), sources: [path: testSource])
        let tests = mutationTestingReport(entries, sources: sources, projectRoot: "/p", version: "0", thresholds: Thresholds(), diffOnly: false, tests: catalog).testFiles
        #expect(tests.keys.sorted() == ["MTests", path])
        let file = try #require(tests[path])
        #expect(file.source == testSource)
        #expect(file.tests.map(\.id) == ["MTests.AddTests/testSums", "MTests.AddTests/testUnused", "MTests.AddTests/testZero"])
        let location = try #require(file.tests[0].location)
        let span: [Int] = [location.start.line, location.start.column, location.end.line, location.end.column]
        #expect(span == [3, 5, 3, 23])
        // Not found in the sources: grouped by module, without a location.
        #expect(tests["MTests"]?.tests.map(\.id) == ["MTests.Gone/testX"])
        #expect(tests["MTests"]?.tests.first?.location == nil)
    }

    @Test func carriesTheConfiguredThresholds() {
        #expect(report(thresholds: Thresholds(high: 90, low: 70, breakAt: 50)).thresholds == ["high": 90, "low": 70])
    }
}

@Suite struct HtmlReportTests {
    @Test func embedsTheReportAndLoadsTheViewerFromAPinnedCdnUrl() {
        let html = htmlReport(report())
        #expect(html.contains("https://www.unpkg.com/mutation-testing-elements@\(mutationTestingElementsVersion)/dist/mutation-test-elements.js"))
        #expect(html.contains("<mutation-test-report-app"))
        #expect(html.contains(#""schemaVersion":"2""#))
    }

    @Test func escapesLessThanSoSourcesCannotCloseTheScriptTag() {
        let hostile = mutationTestingReport(entries, sources: ["Sources/M/Add.swift": "</script><script>alert(1)</script>"], projectRoot: "/p", version: "0", thresholds: Thresholds(), diffOnly: false)
        let html = htmlReport(hostile)
        #expect(!html.contains("</script><script>alert(1)"))
        #expect(html.contains(#"</script>"#))
    }
}

// ---- gate.test.ts ----------------------------------------------------------------

/// Entries with the given statuses (the score is computed from them).
private func gateEntries(_ statuses: [MutantStatus]) -> [ReportEntry] {
    statuses.enumerated().map { entry("Sources/M/Add.swift", "k\($0.offset)", $0.element) }
}

@Suite struct ScoreLevelTests {
    @Test(arguments: [(80.0, "high"), (95.0, "high"), (79.9, "low"), (60.0, "low"), (59.9, "danger")])
    func levels(percent: Double, level: String) {
        #expect(Thresholds().label(percent) == level)
    }
}

@Suite struct QualityGateTests {
    @Test func passesByDefault() {
        #expect(gateFailures(gateEntries([.survived]), diffOnly: false, thresholds: Thresholds(), failOnSurvived: false).isEmpty)
    }

    @Test func failsBelowTheBreakThreshold() {
        let half = gateEntries([.killed, .survived])
        #expect(gateFailures(half, diffOnly: false, thresholds: Thresholds(breakAt: 60), failOnSurvived: false) == ["mutation score 50.0% is below the break threshold 60%"])
        let sixty = gateEntries([.killed, .killed, .killed, .survived, .survived])
        #expect(gateFailures(sixty, diffOnly: false, thresholds: Thresholds(breakAt: 60), failOnSurvived: false).isEmpty)
    }

    @Test func failsOnSurvivedMutantsWhenAsked() {
        #expect(gateFailures(gateEntries([.survived, .killed]), diffOnly: false, thresholds: Thresholds(), failOnSurvived: true) == ["1 mutant(s) survived (--fail-on-survived)"])
    }

    @Test func withSinceOnlySurvivorsInTheDiffOrRecheckedCount() {
        var all = gateEntries([.survived, .survived, .survived, .killed])
        all[0].focus = .diff
        all[1].focus = .recheck
        #expect(gateFailures(all, diffOnly: true, thresholds: Thresholds(), failOnSurvived: true) == ["2 mutant(s) survived (--fail-on-survived)"])
    }
}

@Suite struct ThresholdsInReportsTests {
    private func summary(_ statuses: [MutantStatus], _ thresholds: Thresholds = Thresholds()) -> String {
        formatSummary(gateEntries(statuses), facts: RunFacts(durationMs: 1, files: 1, measuredTests: 0, totalTests: 0, buildRounds: 1, diffOnly: false), thresholds: thresholds)
    }

    @Test func textSummaryLabelsTheScore() {
        #expect(summary(Array(repeating: .killed, count: 9) + [.survived]).contains("score: 90.0% [high]"))
        #expect(summary(Array(repeating: .killed, count: 7) + Array(repeating: .survived, count: 3)).contains("score: 70.0% [low]"))
        #expect(summary(Array(repeating: .killed, count: 3) + Array(repeating: .survived, count: 7), Thresholds(high: 40, low: 35)).contains("score: 30.0% [danger]"))
    }
}
