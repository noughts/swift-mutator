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
    public var focus: Focus?

    public init(mutant: Mutant, status: MutantStatus, source: EntrySource, killedBy: [String] = [], coveredBy: [String] = [], focus: Focus? = nil) {
        self.mutant = mutant
        self.status = status
        self.source = source
        self.killedBy = killedBy
        self.coveredBy = coveredBy
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

public func formatSummary(_ entries: [ReportEntry], facts: RunFacts, thresholds: Thresholds) -> String {
    let shown = reported(entries, diffOnly: facts.diffOnly)
    let count = { (status: MutantStatus) in shown.filter { $0.status == status }.count }
    let percent = scorePercent(shown, diffOnly: facts.diffOnly)
    let ran = shown.filter { $0.source == .run }.count
    let reused = shown.filter { $0.source == .reuse }.count
    var lines: [String] = []
    let scope = facts.diffOnly ? " in the diff" : ""
    lines.append("swift-mutator: \(shown.count) mutants\(scope) (\(entries.count) in \(facts.files) files)")
    lines.append("  killed \(count(.killed)) · survived \(count(.survived)) · no coverage \(count(.noCoverage)) · timeout \(count(.timeout)) · compile error \(count(.compileError)) · ignored \(count(.ignored)) · pending \(count(.pending))")
    lines.append(String(format: "  score %.1f%% [%@] · ran %d, reused %d · dry run %d/%d tests · %d build round(s) · %.1fs", percent, thresholds.label(percent), ran, reused, facts.measuredTests, facts.totalTests, facts.buildRounds, Double(facts.durationMs) / 1000))
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
    return lines.joined(separator: "\n")
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
    public let files: [String: File]
}

/// 1-based line and column, the column counted in UTF-16 units like the report viewer does.
private func point(_ position: Position, lines: LineIndex, bytes: [UInt8]) -> MTEReport.Point {
    let start = lines.starts[min(position.line - 1, lines.starts.count - 1)]
    let prefix = bytes.text(Span(start: start, end: start + position.column))
    return MTEReport.Point(line: position.line, column: prefix.utf16.count + 1)
}

public func mutationTestingReport(_ entries: [ReportEntry], sources: [String: String], projectRoot: String, version: String, thresholds: Thresholds, diffOnly: Bool) -> MTEReport {
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
                location: MTEReport.Range(start: point(m.location.start, lines: lines, bytes: bytes), end: point(m.location.end, lines: lines, bytes: bytes)),
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
        files: files
    )
}

public func encodeReport(_ report: MTEReport) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
    return String(decoding: (try? encoder.encode(report)) ?? Data(), as: UTF8.self)
}

/// A standalone HTML page with the JSON inlined; the viewer component loads from unpkg.
public func htmlReport(json: String) -> String {
    let inlined = json.replacingOccurrences(of: "</", with: "<\\/")
    return """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>swift-mutator report</title>
    <script src="https://unpkg.com/mutation-testing-elements@\(mutationTestingElementsVersion)/dist/mutation-test-elements.js"></script>
    </head>
    <body>
    <mutation-test-report-app title-postfix="swift-mutator"></mutation-test-report-app>
    <script>document.querySelector('mutation-test-report-app').report = \(inlined);</script>
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
        out.append(String(format: "score %.1f%% is below the break threshold %.1f%%", percent, breakAt))
    }
    let undetected = shown.filter { $0.status.isUndetected }.count
    if failOnSurvived, undetected > 0 {
        out.append("\(undetected) undetected mutant(s) with --fail-on-survived")
    }
    return out
}
