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
/// whose code holds it, else the first of these that has any: the operands of the infix operator
/// it points at (`c == ""` with `c` a `Character` is reported at `==`), the smallest statement
/// around it (a type error shows anywhere in the expression a mutant broke), the innermost function
/// around it, the outermost one, the file. Blamed mutants are left out of the next build, so an error
/// that stays is blamed on the next of these, a build round later.
private func suspects(at offset: Int, in file: InstrumentedFile) -> [String] {
    let emission = file.emission
    let size = { (span: Span) in span.end - span.start }
    if let hit = emission.mutantSpans.filter({ $0.value.contains(offset: offset) }).min(by: { size($0.value) < size($1.value) }) {
        return [hit.key]
    }
    let placed = Set(emission.keys)
    let mutants = file.analysis.mutants.filter { placed.contains($0.key) }
    let source = emission.sourceOffset(offset)
    let around = { (spans: [Span]) in spans.filter { $0.start <= source && source <= $0.end }.sorted { size($0) < size($1) } }
    if let infix = file.analysis.operators.first(where: { $0.operator.contains(offset: source) }) {
        let operands = mutants.filter { infix.expression.contains($0.span) && !$0.span.contains(infix.operator) }.map(\.key)
        if !operands.isEmpty { return operands }
    }
    let functions = around(file.analysis.scopes.filter(\.isFunction).map(\.span))
    for span in [around(file.analysis.statements).first, functions.first, functions.last].compactMap({ $0 }) {
        let inside = mutants.filter { span.contains($0.span) }.map(\.key)
        if !inside.isEmpty { return inside }
    }
    return emission.keys
}
