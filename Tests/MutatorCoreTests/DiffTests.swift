import Testing
@testable import MutatorCore

@Suite struct DiffTests {
    // As `git diff --no-prefix` prints it.
    let diff = """
    diff --git Sources/Lib/A.swift Sources/Lib/A.swift
    index 1111111..2222222 100644
    --- Sources/Lib/A.swift
    +++ Sources/Lib/A.swift
    @@ -2 +2 @@ func a() {
    -    return 1
    +    return 2
    @@ -10,2 +9,0 @@ func b() {
    -    gone()
    -    gone()
    diff --git Old.swift New.swift
    similarity index 90%
    rename from Old.swift
    rename to New.swift
    diff --git "Sp ace.swift" "Sp ace.swift"
    new file mode 100644
    --- /dev/null
    +++ "Sp ace.swift"
    @@ -0,0 +1,2 @@
    +let x = 1
    +let y = 2

    """

    @Test func parsesModificationsRenamesAndNewFiles() {
        let files = parseUnifiedDiff(diff)
        #expect(files.map(\.newPath) == ["Sources/Lib/A.swift", "New.swift", "Sp ace.swift"])
        #expect(files[1].oldPath == "Old.swift")
        #expect(files[2].oldPath == nil)
        #expect(files[0].hunks.count == 2)
    }

    @Test func changedLinesFollowCargoMutants() {
        let files = parseUnifiedDiff(diff)
        // A '-' marks the new-side line before it: replacing line 2 marks 1 and 2;
        // the deletion after line 9 marks 9.
        #expect(changedLines(files[0]) == [1, 2, 9])
        #expect(changedLines(files[2]) == [1, 2])
    }

    @Test func lineSpansMergeAdjacentLines() {
        let source = Array("a\nbb\nccc\nd".utf8)
        #expect(lineSpans(source, lines: [2, 3]) == [Span(start: 2, end: 8)])
        #expect(lineSpans(source, lines: [1, 4, 9]) == [Span(start: 0, end: 1), Span(start: 9, end: 10)])
    }

    @Test func selectsByNodeOrByScope() {
        let source = "func f(_ a: Int) -> Int {\n    let b = a + 1\n    return b * 2\n}\n"
        let mutants = analyze(file: "A.swift", source: source).mutants
        let line2 = ["A.swift": lineSpans(Array(source.utf8), lines: [2])]
        let byNode = selectMutants(mutants, changed: line2, mode: .node).map(\.original)
        #expect(byNode.contains("a + 1"))
        #expect(!byNode.contains("b * 2"))
        #expect(selectMutants(mutants, changed: line2, mode: .scope).count == mutants.count)
    }
}
