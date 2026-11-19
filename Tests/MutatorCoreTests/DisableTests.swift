import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/disable.test.ts (sources rewritten in Swift).

private func ignored(_ source: String) -> [String] {
    analyzed(source).compactMap { m in m.ignored.map { "\(m.original) -> \(m.replacement) (\($0))" } }
}

private func placed(_ source: String) -> [String] {
    analyzed(source).filter { $0.ignored == nil }.map { "\($0.original) -> \($0.replacement)" }
}

@Suite struct DisableCommentTests {
    @Test func disableNextLineIgnoresEveryMutantStartingOnTheNextLine() {
        let source = "x = 1 + 1\n// mutator-disable-next-line\ny = 2 + 2\nz = 3 + 3"
        #expect(ignored(source) == ["2 + 2 -> 2 - 2 (disabled)"])
        #expect(placed(source) == ["1 + 1 -> 1 - 1", "3 + 3 -> 3 - 3"])
    }

    @Test func disableLineAppliesToTheCommentLine() {
        #expect(ignored("y = 2 + 2 // mutator-disable-line") == ["2 + 2 -> 2 - 2 (disabled)"])
    }

    @Test func mutatorNamesAndReason() {
        let mutants = analyzed("// mutator-disable-next-line EqualityOperator: boundary is spec\nif a < b {}")
        #expect(mutants.filter { $0.mutator == .equalityOperator }.allSatisfy { $0.ignored == "disabled: boundary is spec" })
        #expect(mutants.contains { $0.mutator == .conditionalExpression })
        #expect(mutants.filter { $0.mutator == .conditionalExpression }.allSatisfy { $0.ignored == nil })
    }

    @Test func regionDisableAndEnable() {
        let source = "a = 1 + 1\n/* mutator-disable ArithmeticOperator */\nb = 2 + 2\nc = \"s\"\n// mutator-enable ArithmeticOperator\nd = 3 + 3"
        #expect(ignored(source) == ["2 + 2 -> 2 - 2 (disabled)"])
        #expect(placed(source).contains("\"s\" -> \"\""))
        #expect(placed(source).contains("3 + 3 -> 3 - 3"))
    }

    @Test func strykerCommentsAreHonouredForMigration() {
        let source = "// Stryker disable next-line all\ny = 2 + 2\n// Stryker disable all\nz = 3 + 3\n// Stryker restore all\nw = 4 + 4"
        #expect(placed(source) == ["4 + 4 -> 4 - 4"])
    }

    @Test func disabledMutantsAreNotPlaced() {
        #expect(emitted("// mutator-disable-next-line\ny = 2 + 2").1.keys.isEmpty)
    }
}
