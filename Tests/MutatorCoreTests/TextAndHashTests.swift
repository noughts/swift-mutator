import Testing
@testable import MutatorCore

@Suite struct HashTests {
    // Vectors from mizchi/mutator's `hash` (cyrb53) in Node.
    @Test(arguments: [
        ("", "wvjl67o803"),
        ("a", "262p94epp1d"),
        ("hello world", "w38l36pd04"),
        ("日本語", "1ropxw1fld"),
        ("src/a.ts\u{0}f\u{0}body\u{0}EqualityOperator\u{0}a <= b", "1nw5acfn00u"),
    ])
    func matchesTheTypeScriptImplementation(input: String, expected: String) {
        #expect(stableHash(input) == expected)
    }
}

@Suite struct TextTests {
    @Test func intersectionOfSpansAndPoints() {
        #expect(intersects(Span(start: 0, end: 5), Span(start: 4, end: 8)))
        #expect(!intersects(Span(start: 0, end: 5), Span(start: 5, end: 8)))
        // An empty span is a point touching either edge.
        #expect(intersects(Span(start: 5, end: 5), Span(start: 0, end: 5)))
        #expect(intersects(Span(start: 2, end: 4), Span(start: 4, end: 4)))
        #expect(!intersects(Span(start: 6, end: 6), Span(start: 0, end: 5)))
    }

    @Test func positionsAreOneBasedLinesAndZeroBasedByteColumns() {
        let index = LineIndex(Array("ab\nあx\n".utf8))
        #expect(index.position(0) == Position(line: 1, column: 0))
        #expect(index.position(3) == Position(line: 2, column: 0))
        #expect(index.position(6) == Position(line: 2, column: 3))
        #expect(index.offset(line: 2, column: 3) == 6)
        #expect(index.offset(line: 99, column: 0) == 8)
    }
}

@Suite struct GlobTests {
    @Test(arguments: [
        ("Sources/**/*.swift", "Sources/Lib/A.swift", true),
        ("Sources/**/*.swift", "Sources/A.swift", true),
        ("Sources/*.swift", "Sources/Lib/A.swift", false),
        ("Sources/Lib/?.swift", "Sources/Lib/A.swift", true),
        ("Sources/Lib/Generated/**", "Sources/Lib/Generated/x/y.swift", true),
        ("Sources/Lib.swift", "Sources/LibXswift", false),
    ])
    func matches(pattern: String, path: String, expected: Bool) {
        #expect(globMatches(pattern, path) == expected)
    }
}
