import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/diff.test.ts.

private func d(_ lines: String...) -> String { lines.joined(separator: "\n") + "\n" }

private func single(_ text: String) throws -> FileDiff {
    let files = parseUnifiedDiff(text)
    #expect(files.count == 1)
    return try #require(files.first)
}

private func hunkFile(_ header: String, _ body: String...) throws -> FileDiff {
    try single((["--- a/f.ts", "+++ b/f.ts", header] + body).joined(separator: "\n") + "\n")
}

@Suite struct ParseUnifiedDiffTests {
    @Test func parsesAGitDiffWithPrefixesAndHunkLines() throws {
        let f = try single(d(
            "diff --git a/src/x.ts b/src/x.ts",
            "index 83db48f..bf269f4 100644",
            "--- a/src/x.ts",
            "+++ b/src/x.ts",
            "@@ -1,3 +1,3 @@ function foo() {",
            " a",
            "-b",
            "+B",
            " c"
        ))
        #expect(f == FileDiff(oldPath: "src/x.ts", newPath: "src/x.ts", hunks: [DiffHunk(oldStart: 1, oldLines: 3, newStart: 1, newLines: 3, lines: [" a", "-b", "+B", " c"])], binary: false))
    }

    @Test func defaultsOmittedHunkCountsToOne() throws {
        let hunk = try #require(try hunkFile("@@ -5 +5 @@", "-x", "+y").hunks.first)
        #expect([hunk.oldStart, hunk.oldLines, hunk.newStart, hunk.newLines] == [5, 1, 5, 1])
    }

    @Test func keepsHunkLinesThatLookLikeFileHeaders() throws {
        #expect(try hunkFile("@@ -1 +1 @@", "--- old", "+++ new").hunks.first?.lines == ["--- old", "+++ new"])
    }

    @Test func dropsNoNewlineMarkers() throws {
        let f = try hunkFile("@@ -1 +1 @@", "-a", "\\ No newline at end of file", "+b", "\\ No newline at end of file")
        #expect(f.hunks.first?.lines == ["-a", "+b"])
    }

    @Test func treatsABareEmptyLineInsideAHunkAsAnEmptyContextLine() throws {
        #expect(try hunkFile("@@ -1,3 +1,3 @@", " a", "", "-b", "+c").hunks.first?.lines == [" a", " ", "-b", "+c"])
    }

    @Test func parsesMultipleHunksAndMultipleFiles() {
        let files = parseUnifiedDiff(d(
            "diff --git a/a.ts b/a.ts",
            "--- a/a.ts",
            "+++ b/a.ts",
            "@@ -1 +1 @@",
            "-1",
            "+2",
            "@@ -10 +10,2 @@",
            " x",
            "+y",
            "diff --git a/b.ts b/b.ts",
            "--- a/b.ts",
            "+++ b/b.ts",
            "@@ -3 +3 @@",
            "-p",
            "+q"
        ))
        #expect(files.map(\.newPath) == ["a.ts", "b.ts"])
        #expect(files.map(\.hunks.count) == [2, 1])
    }

    @Test func handlesNewFiles() throws {
        let f = try single(d(
            "diff --git a/n.ts b/n.ts",
            "new file mode 100644",
            "index 0000000..e69de29",
            "--- /dev/null",
            "+++ b/n.ts",
            "@@ -0,0 +1,2 @@",
            "+a",
            "+b"
        ))
        #expect(f.oldPath == nil)
        #expect(f.newPath == "n.ts")
    }

    @Test func handlesEmptyNewFilesWithNoHunks() throws {
        let f = try single(d("diff --git a/empty.ts b/empty.ts", "new file mode 100644", "index 0000000..e69de29"))
        #expect(f == FileDiff(oldPath: nil, newPath: "empty.ts", hunks: [], binary: false))
    }

    @Test func handlesDeletedFiles() throws {
        let f = try single(d("diff --git a/gone.ts b/gone.ts", "deleted file mode 100644", "--- a/gone.ts", "+++ /dev/null", "@@ -1 +0,0 @@", "-x"))
        #expect(f.oldPath == "gone.ts")
        #expect(f.newPath == nil)
    }

    @Test func handlesPureRenamesWithoutHunks() throws {
        let f = try single(d("diff --git a/old/x.ts b/new/x.ts", "similarity index 100%", "rename from old/x.ts", "rename to new/x.ts"))
        #expect(f == FileDiff(oldPath: "old/x.ts", newPath: "new/x.ts", hunks: [], binary: false))
    }

    @Test func handlesRenamesWithModifications() throws {
        let f = try single(d(
            "diff --git a/o.ts b/n.ts",
            "similarity index 90%",
            "rename from o.ts",
            "rename to n.ts",
            "index 1..2 100644",
            "--- a/o.ts",
            "+++ b/n.ts",
            "@@ -1 +1 @@",
            "-a",
            "+b"
        ))
        #expect(f.oldPath == "o.ts")
        #expect(f.newPath == "n.ts")
        #expect(f.hunks.count == 1)
    }

    @Test func marksBinaryFiles() throws {
        let f = try single(d("diff --git a/img.png b/img.png", "index 1..2 100644", "Binary files a/img.png and b/img.png differ"))
        #expect(f == FileDiff(oldPath: "img.png", newPath: "img.png", hunks: [], binary: true))
    }

    @Test func marksAddedBinaryFiles() throws {
        let f = try single(d("diff --git a/img.png b/img.png", "new file mode 100644", "Binary files /dev/null and b/img.png differ"))
        #expect(f.oldPath == nil)
        #expect(f.newPath == "img.png")
        #expect(f.binary)
    }

    @Test func supportsNoPrefixOutputWithoutStrippingRealDirectories() throws {
        let f = try single(d("diff --git src/a.ts src/a.ts", "--- src/a.ts", "+++ src/a.ts", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.oldPath == "src/a.ts")
        #expect(f.newPath == "src/a.ts")
    }

    @Test func stripsWhenBothSidesCarryAMnemonicLookingSegment() throws {
        let f = try single(d("diff --git a/x.ts a/x.ts", "--- a/x.ts", "+++ a/x.ts", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.newPath == "x.ts")
    }

    @Test func keepsPathsWhoseLeadingSegmentIsNotAMnemonicPrefixOnBothSides() throws {
        let f = try single(d("diff --git src/a.ts b/src/a.ts", "--- src/a.ts", "+++ b/src/a.ts", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.oldPath == "src/a.ts")
        #expect(f.newPath == "b/src/a.ts")
    }

    @Test func stripsMnemonicPrefixesIWCO() throws {
        let f = try single(d("diff --git i/x.ts w/x.ts", "--- i/x.ts", "+++ w/x.ts", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.oldPath == "x.ts")
        #expect(f.newPath == "x.ts")
    }

    @Test func parsesPlainUnifiedDiffsWithTimestamps() throws {
        let f = try single(d("--- a/x.ts\t2024-01-01 00:00:00", "+++ b/x.ts\t2024-01-02 00:00:00", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.oldPath == "x.ts")
        #expect(f.newPath == "x.ts")
    }

    @Test func acceptsCRLFInput() throws {
        let text = ["diff --git a/x.ts b/x.ts", "--- a/x.ts", "+++ b/x.ts", "@@ -1,2 +1,2 @@", " a", "-b", "+c", ""].joined(separator: "\r\n")
        let f = try single(text)
        #expect(f.newPath == "x.ts")
        #expect(f.hunks.first?.lines == [" a", "-b", "+c"])
    }

    @Test func handlesPathsWithSpaces() throws {
        let f = try single(d("diff --git a/my dir/x y.ts b/my dir/x y.ts", "--- a/my dir/x y.ts\t", "+++ b/my dir/x y.ts\t", "@@ -1 +1 @@", "-a", "+b"))
        #expect(f.oldPath == "my dir/x y.ts")
        #expect(f.newPath == "my dir/x y.ts")
    }

    @Test func handlesPathsWithSpacesInAHeaderOnlyDiff() throws {
        let f = try single(d("diff --git a/my dir/e f.ts b/my dir/e f.ts", "new file mode 100644", "index 0000000..e69de29"))
        #expect(f.newPath == "my dir/e f.ts")
    }

    @Test func unquotesCStyleQuotedPaths() throws {
        let f = try single(d(
            #"diff --git "a/t\tab.ts" "b/\346\227\245.ts""#,
            #"--- "a/t\tab.ts""#,
            #"+++ "b/\346\227\245.ts""#,
            "@@ -1 +1 @@",
            "-a",
            "+b"
        ))
        #expect(f.oldPath == "t\tab.ts")
        #expect(f.newPath == "日.ts")
    }

    @Test func doesNotReadTheTrailingNewlineAsAContextLineOfATruncatedHunk() throws {
        #expect(try hunkFile("@@ -1,3 +1,3 @@", " a", "-b", "+c").hunks.first?.lines == [" a", "-b", "+c"])
    }

    @Test func returnsNothingForEmptyInput() {
        #expect(parseUnifiedDiff("").isEmpty)
    }
}

@Suite struct ChangedLinesTests {
    @Test func singleLineInsert() throws {
        #expect(changedLines(try hunkFile("@@ -1,2 +1,3 @@", " a", "+X", " b")) == [2])
    }

    @Test func singleLineDeleteMarksTheLinesAroundIt() throws {
        #expect(changedLines(try hunkFile("@@ -1,3 +1,2 @@", " a", "-X", " b")) == [1, 2])
    }

    @Test func deleteAtFileStartDropsLineZero() throws {
        #expect(changedLines(try hunkFile("@@ -1,2 +1,1 @@", "-X", " a")) == [1])
    }

    @Test func deleteAtFileEndMarksOnlyTheLastLine() throws {
        #expect(changedLines(try hunkFile("@@ -1,2 +1,1 @@", " a", "-X")) == [1])
    }

    @Test func replaceMarksTheLineBeforeAndTheNextContextLine() throws {
        #expect(changedLines(try hunkFile("@@ -1,3 +1,3 @@", " a", "-b", "+B", " c")) == [1, 2, 3])
    }

    @Test func multiLineReplace() throws {
        #expect(changedLines(try hunkFile("@@ -1,4 +1,4 @@", " a", "-b", "-c", "+B", "+C", " d")) == [1, 2, 3, 4])
    }

    @Test func insertFollowedByContextDoesNotMarkTheContextLine() throws {
        #expect(changedLines(try hunkFile("@@ -1,3 +1,4 @@", " a", "+X", " b", " c")) == [2])
    }

    @Test func pureDeleteHunkWithZeroNewLinesUsesNewStartAsTheLineBefore() throws {
        // "+2,0" means the deletion sits after new-side line 2
        #expect(changedLines(try hunkFile("@@ -3,1 +2,0 @@", "-X")) == [2])
    }

    @Test func wholeFileDeleteYieldsNothing() throws {
        #expect(changedLines(try hunkFile("@@ -1,2 +0,0 @@", "-a", "-b")).isEmpty)
    }

    @Test func newFileMarksEveryLine() throws {
        #expect(changedLines(try hunkFile("@@ -0,0 +1,3 @@", "+a", "+b", "+c")) == [1, 2, 3])
    }

    @Test func mergesMultipleHunksIntoASortedUniqueList() throws {
        let f = try single(d("--- a/f", "+++ b/f", "@@ -10,2 +10,2 @@", "-x", "+y", " z", "@@ -1,2 +1,2 @@", " a", "-b", "+c"))
        #expect(changedLines(f) == [1, 2, 9, 10, 11])
    }

    @Test func isEmptyForRenamesAndBinaries() {
        #expect(changedLines(FileDiff(oldPath: "a", newPath: "b", hunks: [], binary: false)).isEmpty)
    }
}

@Suite struct LineSpansTests {
    let src = Array("ab\ncde\n\nfg".utf8)

    @Test func mapsASingleLineExcludingTheNewline() {
        #expect(lineSpans(src, lines: [2]) == [Span(start: 3, end: 6)])
    }

    @Test func mergesAdjacentLinesAcrossTheNewline() {
        #expect(lineSpans(src, lines: [1, 2]) == [Span(start: 0, end: 6)])
    }

    @Test func keepsNonAdjacentLinesSeparateAndSortsAndDedupes() {
        #expect(lineSpans(src, lines: [4, 1, 1]) == [Span(start: 0, end: 2), Span(start: 8, end: 10)])
    }

    @Test func givesAnEmptyLineAZeroLengthSpan() {
        #expect(lineSpans(src, lines: [3]) == [Span(start: 7, end: 7)])
    }

    @Test func excludesTheCarriageReturnOfCRLF() {
        #expect(lineSpans(Array("ab\r\ncd\r\n".utf8), lines: [1, 2]) == [Span(start: 0, end: 6)])
    }

    @Test func ignoresOutOfRangeLineNumbers() {
        #expect(lineSpans(src, lines: [0, 99]).isEmpty)
    }
}

@Suite struct SelectMutantsTests {
    private func m(_ file: String, _ span: Span, _ scope: Span) -> Mutant {
        fixtureMutant("\(file)\(span.start)-\(span.end)", file: file, span: span, scopeSpan: scope)
    }

    let fn = Span(start: 0, end: 100)
    let changed = ["x.ts": [Span(start: 10, end: 20)]]

    @Test func nodeModeKeepsMutantsIntersectingAChangedSpan() {
        let inside = m("x.ts", Span(start: 15, end: 16), fn)
        let overlapping = m("x.ts", Span(start: 5, end: 11), fn)
        let touchingBefore = m("x.ts", Span(start: 5, end: 10), fn)
        let touchingAfter = m("x.ts", Span(start: 20, end: 25), fn)
        #expect(selectMutants([inside, overlapping, touchingBefore, touchingAfter], changed: changed, mode: .node) == [inside, overlapping])
    }

    @Test func nodeModeIgnoresMutantsOfOtherFiles() {
        #expect(selectMutants([m("y.ts", Span(start: 15, end: 16), fn)], changed: changed, mode: .node).isEmpty)
    }

    @Test func zeroLengthChangedSpanCountsWithinTheMutant() {
        let point = ["x.ts": [Span(start: 10, end: 10)]]
        let atEnd = m("x.ts", Span(start: 5, end: 10), fn)
        let atStart = m("x.ts", Span(start: 10, end: 12), fn)
        let outside = m("x.ts", Span(start: 11, end: 12), fn)
        #expect(selectMutants([atEnd, atStart, outside], changed: point, mode: .node) == [atEnd, atStart])
    }

    @Test func scopeModeSelectsEveryMutantWhoseScopeIntersects() {
        let signature = ["x.ts": [Span(start: 0, end: 5)]]
        let a = m("x.ts", Span(start: 50, end: 51), fn)
        let b = m("x.ts", Span(start: 150, end: 151), Span(start: 120, end: 200))
        #expect(selectMutants([a, b], changed: signature, mode: .node).isEmpty)
        #expect(selectMutants([a, b], changed: signature, mode: .scope) == [a])
    }
}
