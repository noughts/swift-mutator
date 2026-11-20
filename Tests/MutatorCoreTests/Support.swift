@testable import MutatorCore

// Helpers shared by the tests: analysis, labels and plain fixtures.

func analyzed(_ source: String, file: String = "a.swift", options: AnalyzeOptions = .init()) -> [Mutant] {
    analyze(file: file, source: source, options: options).mutants
}

/// `Mutator: original -> replacement`
func label(_ m: Mutant) -> String { "\(m.mutator.rawValue): \(m.original) -> \(m.replacement)" }

/// Labels of the mutants that are placed (not ignored).
func edits(_ source: String) -> [String] { analyzed(source).filter { $0.ignored == nil }.map(label) }

func emitted(_ source: String, excluding: (Mutant) -> Bool = { _ in false }) -> (Analysis, Emission) {
    let analysis = analyze(file: "a.swift", source: source)
    return (analysis, emit(Array(source.utf8), analysis, excluding: Set(analysis.mutants.filter(excluding).map(\.key))))
}

/// Byte offset of the first occurrence of `needle`.
func byteOffset(of needle: String, in text: String) -> Int {
    text.utf8.distance(from: text.startIndex, to: text.firstRange(of: needle)!.lowerBound)
}

let fixtureLocation = Location(start: Position(line: 1, column: 0), end: Position(line: 1, column: 1))

func fixtureMutant(_ key: String, file: String = "a.swift", scope: String = "f", hash: String = "h1", span: Span = Span(start: 0, end: 1), scopeSpan: Span = Span(start: 0, end: 10), original: String = "+", replacement: String = "-", location: Location = fixtureLocation, ignored: String? = nil) -> Mutant {
    Mutant(key: key, file: file, mutator: .arithmeticOperator, span: span, location: location, original: original, replacement: replacement, scope: Scope(id: scope, hash: hash, span: scopeSpan, kind: .function), ignored: ignored)
}

func fixtureSnapshot(_ results: [MutantResult], _ tests: [TestInfo], toolVersion: String = "v1", envHash: String = "e1", coverage: [String: [String]] = [:], scopes: [String: String] = [:], declarationScopes: [String] = []) -> Snapshot {
    Snapshot(toolVersion: toolVersion, envHash: envHash, results: results, tests: tests, coverage: coverage, scopes: scopes, declarationScopes: declarationScopes)
}
