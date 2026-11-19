// --since: which mutants the diff touches, and which outside it must be rechecked.

public enum Focus: Sendable {
    /// Inside the diff.
    case diff
    /// Outside the diff, killed before by tests that are all gone now.
    case recheck
}

/// The mutants a --since run reports: those in the diff, and those outside it that were killed
/// before by tests that are all gone now (removed or renamed), so a deleted test cannot hide.
public func sinceFocus(touched: Set<String>, previous: [MutantResult], tests: [TestInfo]) -> [String: Focus] {
    var focus = Dictionary(touched.map { ($0, Focus.diff) }, uniquingKeysWith: { first, _ in first })
    let present = Set(tests.map(\.id))
    for r in previous where focus[r.key] == nil && r.status == .killed && !r.killedBy.isEmpty {
        if r.killedBy.allSatisfy({ !present.contains($0) }) { focus[r.key] = .recheck }
    }
    return focus
}

/// Changed spans per file: the diff's changed lines, and new (untracked) files as a whole.
public func changedSpans(lines: [String: [Int]], newFiles: Set<String>, sources: [String: [UInt8]]) -> [String: [Span]] {
    var out: [String: [Span]] = [:]
    for (file, bytes) in sources {
        if newFiles.contains(file) {
            out[file] = [Span(start: 0, end: bytes.count)]
        } else if let numbers = lines[file] {
            out[file] = lineSpans(bytes, lines: numbers)
        }
    }
    return out
}
