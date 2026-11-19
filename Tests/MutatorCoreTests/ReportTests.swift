import Foundation
import Testing
@testable import MutatorCore

@Suite struct ReportTests {
    let source = "let s = \"日本\" + name\nfunc f(_ a: Int) -> Bool { a > 1 }\n"

    private func entries(_ statuses: [MutantStatus]) -> [ReportEntry] {
        let mutants = analyze(file: "A.swift", source: source).mutants.filter { $0.ignored == nil }
        return zip(mutants, statuses).map { ReportEntry(mutant: $0, status: $1, source: .run) }
    }

    @Test func scoreCountsDetectedOverDetectedAndUndetected() {
        #expect(score(entries([.killed, .survived, .timeout, .noCoverage])) == 0.5)
        #expect(score(entries([.compileError, .ignored, .pending])) == 1)
    }

    @Test func summaryGroupsTheGaps() {
        let text = formatSummary(entries([.killed, .survived, .noCoverage]), facts: RunFacts(durationMs: 1200, files: 1, measuredTests: 2, totalTests: 3, buildRounds: 1, diffOnly: false), thresholds: Thresholds())
        #expect(text.contains("killed 1 · survived 1 · no coverage 1"))
        #expect(text.contains("not detected"))
        #expect(text.contains("not reached"))
    }

    @Test func mutationTestingColumnsAreOneBasedUtf16() throws {
        let all = entries([.killed, .survived, .survived, .survived, .survived])
        let report = mutationTestingReport(all, sources: ["A.swift": source], projectRoot: "/p", version: "0", thresholds: Thresholds(), diffOnly: false)
        let json = encodeReport(report)
        let decoded = try JSONDecoder().decode(MTEReport.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == "2")
        let literal = try #require(decoded.files["A.swift"]?.mutants.first { $0.mutatorName == "StringLiteral" })
        // `"日本"` starts after `let s = ` (8 characters).
        #expect(literal.location.start.line == 1 && literal.location.start.column == 9)
        #expect(literal.location.end.column == 13)
    }

    @Test func outsideTheDiffVerdictsAreReportedPending() {
        var all = entries([.killed, .survived])
        all[0].focus = .diff
        let report = mutationTestingReport(all, sources: ["A.swift": source], projectRoot: "/p", version: "0", thresholds: Thresholds(), diffOnly: true)
        #expect(Set(report.files["A.swift"]!.mutants.map(\.status)) == ["Killed", "Pending"])
    }
}
