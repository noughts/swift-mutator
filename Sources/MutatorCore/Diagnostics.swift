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

/// The mutants to leave out so that `errors` (paths relative, as the keys of `files`) go away:
/// the mutant whose code holds the error, else every mutant of the innermost switch around it,
/// else of the innermost function around it, else of the file.
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
        let offset = index.offset(line: error.line, column: error.column - 1)
        let emission = file.emission
        if let hit = emission.mutantSpans.filter({ $0.value.contains(offset: offset) }).min(by: { $0.value.end - $0.value.start < $1.value.end - $1.value.start }) {
            keys.insert(hit.key)
            continue
        }
        if let placement = emission.placementSpans.filter({ $0.span.contains(offset: offset) }).min(by: { $0.span.end - $0.span.start < $1.span.end - $1.span.start }) {
            keys.formUnion(placement.keys)
            continue
        }
        let placed = Set(emission.keys)
        let source = emission.sourceOffset(offset)
        let function = file.analysis.scopes.filter { $0.isFunction && $0.span.start <= source && source <= $0.span.end }
            .min { $0.span.end - $0.span.start < $1.span.end - $1.span.start }
        let inFunction = function.map { scope in file.analysis.mutants.filter { placed.contains($0.key) && scope.span.contains($0.span) }.map(\.key) } ?? []
        keys.formUnion(inFunction.isEmpty ? emission.keys : inFunction)
    }
    return Blame(keys: keys, unattributed: unattributed)
}
