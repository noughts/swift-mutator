// Mutants that do not compile: all mutants are compiled at once, so a compiler error in an
// instrumented file is traced back to the mutants that caused it, which are then left out.

public struct CompilerError: Hashable, Sendable {
    /// Path as printed by the compiler (the caller maps it to a relative path).
    public let path: String
    public let line: Int
    /// 1-based UTF-8 column.
    public let column: Int
    public let message: String

    public init(path: String, line: Int, column: Int, message: String) {
        self.path = path
        self.line = line
        self.column = column
        self.message = message
    }
}

/// Terminal escapes (colors, hyperlinks) removed.
public func stripEscapes(_ text: String) -> String {
    text.replacing(/\u{1B}\][^\u{1B}\u{07}]*(?:\u{1B}\\|\u{07})/, with: "").replacing(/\u{1B}\[[0-9;]*[A-Za-z]/, with: "")
}

/// `path:line:col: error: message` lines of compiler output.
public func parseCompilerErrors(_ output: String) -> [CompilerError] {
    var seen = Set<CompilerError>()
    var out: [CompilerError] = []
    let pattern = /\s*(\/.+?\.swift):(\d+):(\d+): error: (.*)/
    for line in stripEscapes(output).split(separator: "\n") {
        guard let match = line.wholeMatch(of: pattern), let row = Int(match.2), let column = Int(match.3) else { continue }
        let error = CompilerError(path: String(match.1), line: row, column: column, message: String(match.4))
        if seen.insert(error).inserted { out.append(error) }
    }
    return out
}

public struct InstrumentedFile: Sendable {
    public let analysis: Analysis
    public let emission: Emission

    public init(analysis: Analysis, emission: Emission) {
        self.analysis = analysis
        self.emission = emission
    }
}

public struct Blame: Sendable {
    public let keys: Set<String>
    /// Errors no placed mutant can explain.
    public let unattributed: [CompilerError]
}

/// The mutants to leave out so that `errors` (paths relative, as the keys of `files`) go away.
public func blame(_ errors: [CompilerError], files: [String: InstrumentedFile]) -> Blame {
    var keys = Set<String>()
    var unattributed: [CompilerError] = []
    var indexes: [String: LineIndex] = [:]
    for error in errors {
        guard let file = files[error.path], !file.emission.keys.isEmpty else {
            unattributed.append(error)
            continue
        }
        let index = indexes[error.path] ?? LineIndex(Array(file.emission.code.utf8))
        indexes[error.path] = index
        keys.formUnion(suspects(at: index.offset(line: error.line, column: error.column - 1), in: file))
    }
    return Blame(keys: keys, unattributed: unattributed)
}

/// The placed mutants an error at `offset` (of the instrumented code) is blamed on: the mutant
/// whose code holds it, else those of the smallest statement around it that has any, else every
/// placed mutant of the file. A type error shows anywhere in the expression a mutant broke, often
/// outside the mutant itself. Blamed mutants are left out of the next build, so an error that
/// stays is blamed on the next statement out, a build round later.
private func suspects(at offset: Int, in file: InstrumentedFile) -> [String] {
    let emission = file.emission
    let size = { (span: Span) in span.end - span.start }
    if let hit = emission.mutantSpans.filter({ $0.value.contains(offset: offset) }).min(by: { size($0.value) < size($1.value) }) {
        return [hit.key]
    }
    let placed = Set(emission.keys)
    let mutants = file.analysis.mutants.filter { placed.contains($0.key) }
    let source = emission.sourceOffset(offset)
    for statement in file.analysis.statements.filter({ $0.start <= source && source <= $0.end }).sorted(by: { size($0) < size($1) }) {
        let inside = mutants.filter { statement.contains($0.span) }.map(\.key)
        if !inside.isEmpty { return inside }
    }
    return emission.keys
}
