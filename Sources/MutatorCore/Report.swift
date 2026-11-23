import Foundation

// Reports: the text summary, and mutation-testing-elements JSON (schema v2, the format StrykerJS
// writes, so its HTML viewer and dashboard read it).

public enum EntrySource: Sendable {
    /// Executed in this run.
    case run
    /// Taken from the snapshot.
    case reuse
    /// Not run: ignored, no coverage, compile error, or outside `--since` (Pending).
    case decided
}

public struct ReportEntry: Sendable {
    public let mutant: Mutant
    public let status: MutantStatus
    public let source: EntrySource
    public let killedBy: [String]
    public let coveredBy: [String]
    /// Some covering tests never ran (a crash stopped them): `killedBy` is partial.
    public let incomplete: Bool
    public var focus: Focus?

    public init(mutant: Mutant, status: MutantStatus, source: EntrySource, killedBy: [String] = [], coveredBy: [String] = [], incomplete: Bool = false, focus: Focus? = nil) {
        self.mutant = mutant
        self.status = status
        self.source = source
        self.killedBy = killedBy
        self.coveredBy = coveredBy
        self.incomplete = incomplete
        self.focus = focus
    }
}

/// Detected over detected and undetected; 1 when there is neither.
public func score(_ entries: [ReportEntry]) -> Double {
    let detected = entries.filter { $0.status.isDetected }.count
    let undetected = entries.filter { $0.status.isUndetected }.count
    return detected + undetected == 0 ? 1 : Double(detected) / Double(detected + undetected)
}

/// The score in percent of the reported entries; with `--since` only the diff counts (not rechecks).
private func scorePercent(_ shown: [ReportEntry], diffOnly: Bool) -> Double {
    score(diffOnly ? shown.filter { $0.focus == .diff } : shown) * 100
}

public struct Thresholds: Sendable {
    public let high: Double
    public let low: Double
    /// Below this score (percent) the quality gate fails.
    public let breakAt: Double?

    public init(high: Double = 80, low: Double = 60, breakAt: Double? = nil) {
        self.high = high
        self.low = low
        self.breakAt = breakAt
    }

    public func label(_ percent: Double) -> String { percent >= high ? "high" : percent >= low ? "low" : "danger" }
}

public struct RunFacts: Sendable {
    public let durationMs: Int
    public let files: Int
    public let measuredTests: Int
    public let totalTests: Int
    public let buildRounds: Int
    /// With `--since`: only mutants in the diff (and rechecks) are reported.
    public let diffOnly: Bool

    public init(durationMs: Int, files: Int, measuredTests: Int, totalTests: Int, buildRounds: Int, diffOnly: Bool) {
        self.durationMs = durationMs
        self.files = files
        self.measuredTests = measuredTests
        self.totalTests = totalTests
        self.buildRounds = buildRounds
        self.diffOnly = diffOnly
    }
}

private func oneLine(_ text: String, limit: Int = 60) -> String {
    let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
    return flat.count > limit ? String(flat.prefix(limit - 1)) + "…" : flat
}

/// `file:line:col  Mutator  original → replacement  [key]` on one line.
public func formatMutant(_ m: Mutant) -> String {
    let replacement = m.replacement.isEmpty ? "(removed)" : oneLine(m.replacement)
    return "\(m.file):\(m.location.start.line):\(m.location.start.column + 1)  \(m.mutator.rawValue)  \(oneLine(m.original)) → \(replacement)  [\(m.key)]"
}

private func describe(_ entry: ReportEntry) -> String { "  " + formatMutant(entry.mutant) }

/// The reported entries: all, or with `--since` the ones in focus.
public func reported(_ entries: [ReportEntry], diffOnly: Bool) -> [ReportEntry] {
    diffOnly ? entries.filter { $0.focus != nil } : entries
}

/// Every collected test, where it is, and the sources of the test files.
public struct TestCatalog: Sendable {
    public let ids: [String]
    public let locations: [String: TestLocation]
    /// Test file path -> its text.
    public let sources: [String: String]

    public init(ids: [String] = [], locations: [String: TestLocation] = [:], sources: [String: String] = [:]) {
        self.ids = ids
        self.locations = locations
        self.sources = sources
    }
}

public func formatSummary(_ entries: [ReportEntry], facts: RunFacts, thresholds: Thresholds, killMatrix: KillMatrix? = nil, tests: TestCatalog = TestCatalog()) -> String {
    let shown = reported(entries, diffOnly: facts.diffOnly)
    let count = { (status: MutantStatus) in shown.filter { $0.status == status }.count }
    let percent = scorePercent(shown, diffOnly: facts.diffOnly)
    let ran = shown.filter { $0.source == .run }.count
    let reused = shown.filter { $0.source == .reuse }.count
    var lines: [String] = []
    let scope = facts.diffOnly ? " in the diff" : ""
    lines.append("swift-mutator: \(shown.count) mutants\(scope) (\(entries.count) in \(facts.files) files)")
    lines.append("  killed \(count(.killed)) · survived \(count(.survived)) · no coverage \(count(.noCoverage)) · timeout \(count(.timeout)) · compile error \(count(.compileError)) · ignored \(count(.ignored)) · pending \(count(.pending))")
    let seconds = String(format: "%.1f", Double(facts.durationMs) / 1000)
    lines.append("  score: \(String(format: "%.1f", percent))% [\(thresholds.label(percent))] · ran \(ran), reused \(reused) · dry run \(facts.measuredTests)/\(facts.totalTests) tests · \(facts.buildRounds) build round(s) · \(seconds)s")
    let survived = shown.filter { $0.status == .survived }
    if !survived.isEmpty {
        lines.append("")
        lines.append("not detected (tests run the mutant, but none fails: strengthen an assertion, or it is equivalent):")
        lines += survived.map(describe)
    }
    let unreached = shown.filter { $0.status == .noCoverage }
    if !unreached.isEmpty {
        lines.append("")
        lines.append("not reached (no test runs the mutant: add a test):")
        lines += unreached.map(describe)
    }
    let rechecked = shown.filter { $0.focus == .recheck && $0.status.isUndetected }
    if !rechecked.isEmpty {
        lines.append("")
        lines.append("killed before, undetected now (the tests that killed it are gone):")
        lines += rechecked.map(describe)
    }
    if let killMatrix { lines += killMatrixSection(killMatrix, locations: tests.locations) }
    return lines.joined(separator: "\n")
}

private let maxListed = 20

private func plural(_ n: Int, _ word: String) -> String { "\(n) \(word)\(n == 1 ? "" : "s")" }

private func killMatrixSection(_ k: KillMatrix, locations: [String: TestLocation]) -> [String] {
    let at = { (test: String) in locations[test].map { "\(test)  (\($0.file):\($0.location.start.line))" } ?? test }
    var excluded: [String] = []
    if k.mutants.timeout > 0 { excluded.append("\(k.mutants.timeout) timed out") }
    if k.mutants.incomplete > 0 { excluded.append("\(k.mutants.incomplete) without one (not run, or a crash stopped the tests)") }
    var lines = ["", "kill matrix: \(plural(k.mutants.full, "mutant")) with a full matrix, \(plural(k.tests, "collected test"))" + (excluded.isEmpty ? "" : "; excluded: " + excluded.joined(separator: ", "))]
    lines.append("  candidates for review, not for deletion: a test can pin behaviour no mutant represents (synthesized Codable, raw values and constants, resources, code compiled in from outside the package, the nil path of `guard let`)")
    let section = { (heading: String, items: [String]) in
        guard !items.isEmpty else { return }
        lines += ["", heading] + items.prefix(maxListed).map { "  " + $0 }
        if items.count > maxListed { lines.append("  … \(items.count - maxListed) more (see --reporter json)") }
    }
    section("detects nothing - covers mutants, but kills none of them:", k.noKills.map(at))
    section("no viable mutant reached - detection power is not measured:", k.observations.filter { $0.status == .notReached }.map { at($0.test) })
    section("measurement incomplete - no conclusion about detection power:", k.observations.filter { $0.status == .incomplete }.map { at($0.test) })
    section("subsumed - another test kills every mutant it kills, and more:", k.subsumed.map { s in
        "\(at(s.test))  subsumed by \(s.by[0])\(s.by.count > 1 ? " (+\(s.by.count - 1) more)" : "")  (\(plural(s.kills, "kill")))"
    })
    section("duplicates - the same kill set:", k.duplicates.map { "\($0.tests.joined(separator: " = "))  (\(plural($0.kills, "kill")))" })
    return lines
}

// ---- mutation-testing-elements ------------------------------------------------

public let mutationTestingElementsVersion = "3.9.0"

public struct MTEReport: Codable, Sendable {
    public struct Point: Codable, Sendable {
        public let line: Int
        public let column: Int
    }

    public struct Range: Codable, Sendable {
        public let start: Point
        public let end: Point
    }

    public struct MutantRecord: Codable, Sendable {
        public let id: String
        public let mutatorName: String
        public let replacement: String
        public let location: Range
        public let status: String
        public let killedBy: [String]
        public let coveredBy: [String]
        public let statusReason: String?
    }

    public struct File: Codable, Sendable {
        public let language: String
        public let source: String
        public let mutants: [MutantRecord]
    }

    public struct Framework: Codable, Sendable {
        public let name: String
        public let version: String
    }

    public let schemaVersion: String
    public let thresholds: [String: Double]
    public let projectRoot: String
    public let framework: Framework
    public struct TestFile: Codable, Sendable {
        public struct Test: Codable, Sendable {
            public let id: String
            public let name: String
            public let location: Range?
        }

        public let source: String?
        public let tests: [Test]
    }

    public let files: [String: File]
    /// Every collected test, grouped by its source file; a test whose function was not found is
    /// grouped by its module (Swift test ids are `Module.Type/test`).
    public let testFiles: [String: TestFile]
    /// swift-mutator extension (the schema allows extra fields), with --kill-matrix.
    public let killMatrix: KillMatrix?
}

/// 1-based line and column, the column counted in UTF-16 units like the report viewer does.
private func point(_ position: Position, lines: LineIndex, bytes: [UInt8]) -> MTEReport.Point {
    let start = lines.starts[min(position.line - 1, lines.starts.count - 1)]
    let prefix = bytes.text(Span(start: start, end: start + position.column))
    return MTEReport.Point(line: position.line, column: prefix.utf16.count + 1)
}

private func range(_ location: Location, lines: LineIndex, bytes: [UInt8]) -> MTEReport.Range {
    MTEReport.Range(start: point(location.start, lines: lines, bytes: bytes), end: point(location.end, lines: lines, bytes: bytes))
}

public func mutationTestingReport(_ entries: [ReportEntry], sources: [String: String], projectRoot: String, version: String, thresholds: Thresholds, diffOnly: Bool, tests: TestCatalog = TestCatalog(), killMatrix: KillMatrix? = nil) -> MTEReport {
    var files: [String: MTEReport.File] = [:]
    for (file, group) in Dictionary(grouping: entries, by: \.mutant.file) {
        let source = sources[file] ?? ""
        let bytes = Array(source.utf8)
        let lines = LineIndex(bytes)
        let records = group.sorted { $0.mutant.span.start < $1.mutant.span.start }.map { entry in
            let m = entry.mutant
            // Outside --since the verdict is context only: Pending keeps it out of the score.
            let status = diffOnly && entry.focus == nil && entry.status != .ignored && entry.status != .compileError ? MutantStatus.pending : entry.status
            return MTEReport.MutantRecord(
                id: m.key,
                mutatorName: m.mutator.rawValue,
                replacement: m.replacement,
                location: range(m.location, lines: lines, bytes: bytes),
                status: status.rawValue,
                killedBy: entry.killedBy,
                coveredBy: entry.coveredBy,
                statusReason: m.ignored ?? (entry.focus == .recheck ? "killed before by tests that are gone" : nil)
            )
        }
        files[file] = MTEReport.File(language: "swift", source: source, mutants: records)
    }
    return MTEReport(
        schemaVersion: "2",
        thresholds: ["high": thresholds.high, "low": thresholds.low],
        projectRoot: projectRoot,
        framework: MTEReport.Framework(name: "swift-mutator", version: version),
        files: files,
        testFiles: testFiles(entries, tests: tests),
        killMatrix: killMatrix
    )
}

private func testFiles(_ entries: [ReportEntry], tests: TestCatalog) -> [String: MTEReport.TestFile] {
    var ids = Set(tests.ids)
    for entry in entries {
        ids.formUnion(entry.killedBy)
        ids.formUnion(entry.coveredBy)
    }
    return Dictionary(grouping: ids.sorted(), by: { tests.locations[$0]?.file ?? testModule($0) }).reduce(into: [:]) { out, group in
        // Grouped by module: no test of the group was found in a source.
        guard let source = tests.sources[group.key] else {
            out[group.key] = MTEReport.TestFile(source: nil, tests: group.value.map { MTEReport.TestFile.Test(id: $0, name: testName($0), location: nil) })
            return
        }
        let bytes = Array(source.utf8)
        let lines = LineIndex(bytes)
        let records = group.value.map { id in
            MTEReport.TestFile.Test(id: id, name: testName(id), location: tests.locations[id].map { range($0.location, lines: lines, bytes: bytes) })
        }
        out[group.key] = MTEReport.TestFile(source: source, tests: records)
    }
}

public func encodeReport(_ report: MTEReport, pretty: Bool = true) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
}

/// A standalone HTML page with the report inlined; the viewer component loads from a pinned CDN url.
public func htmlReport(_ report: MTEReport) -> String {
    // `<` keeps `</script>` inside sources from terminating the inline script.
    let data = encodeReport(report, pretty: false).replacingOccurrences(of: "<", with: "\\u003c")
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>swift-mutator report</title>
    <script src="https://www.unpkg.com/mutation-testing-elements@\(mutationTestingElementsVersion)/dist/mutation-test-elements.js"></script>
    </head>
    <body>
    <mutation-test-report-app title-postfix="swift-mutator">
      Your browser doesn't support custom elements. Please use a modern browser.
    </mutation-test-report-app>
    <script>
      const app = document.querySelector('mutation-test-report-app');
      app.report = \(data);
      function updateTheme() { document.body.style.backgroundColor = app.themeBackgroundColor; }
      app.addEventListener('theme-changed', updateTheme);
      updateTheme();
    </script>
    </body>
    </html>

    """
}

/// Why the quality gate fails (empty when it passes).
public func gateFailures(_ entries: [ReportEntry], diffOnly: Bool, thresholds: Thresholds, failOnSurvived: Bool) -> [String] {
    let shown = reported(entries, diffOnly: diffOnly)
    var out: [String] = []
    let percent = scorePercent(shown, diffOnly: diffOnly)
    if let breakAt = thresholds.breakAt, percent < breakAt {
        out.append(String(format: "mutation score %.1f%% is below the break threshold %g%%", percent, breakAt))
    }
    let survived = shown.filter { $0.status == .survived }.count
    if failOnSurvived, survived > 0 {
        out.append("\(survived) mutant(s) survived (--fail-on-survived)")
    }
    return out
}
