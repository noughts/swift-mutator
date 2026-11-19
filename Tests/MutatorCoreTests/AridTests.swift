import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/arid.test.ts (sources rewritten in Swift:
// `console.log` becomes `print`, `this.` becomes `self.`).

private func run(_ source: String, options: AnalyzeOptions = .init()) -> (arid: [String], placed: [String]) {
    let mutants = analyzed(source, options: options)
    return (mutants.filter { $0.ignored?.hasPrefix("arid") == true }.map(label), mutants.filter { $0.ignored == nil }.map(label))
}

@Suite struct AridNodeTests {
    @Test func mutantsInsideLoggingCallsAreArid() {
        let (arid, placed) = run(#"func f(_ a: Int) -> Int { print("value", a + 1); return a * 2 }"#)
        #expect(arid.contains(#"StringLiteral: "value" -> """#))
        #expect(arid.contains("ArithmeticOperator: a + 1 -> a - 1"))
        #expect(placed.contains("ArithmeticOperator: a * 2 -> a / 2"))
    }

    @Test func removingALoggingStatementIsArid() {
        #expect(run("func f(_ x: Int) -> Int { logger.info(x); return 1 }").arid.contains("CallExpression: logger.info(x) -> "))
    }

    @Test func aBlockOrIfThatOnlyLogsIsAridByTheCompoundRule() {
        // A function without a return value: its body can be emptied (BlockStatement) as in the original.
        let (arid, placed) = run(#"func f(_ a: Int) { if a > 1 { self.logger.debug("big") }; total += a }"#)
        #expect(arid.contains("ConditionalExpression: a > 1 -> true"))
        #expect(arid.contains("EqualityOperator: a > 1 -> a >= 1"))
        #expect(arid.contains(#"BlockStatement: { self.logger.debug("big") } -> {}"#))
        #expect(placed.contains { $0.hasPrefix("BlockStatement: { if") })
    }

    @Test func aBlockMixingLoggingAndLogicIsNotArid() {
        let (_, placed) = run(#"func f(_ a: Int) -> Int { if a > 1 { print("big"); return 0 }; return a }"#)
        #expect(placed.contains("ConditionalExpression: a > 1 -> true"))
    }

    @Test func memberCallsNamedDebugOrTraceAreAridOtherCallsAreNot() {
        let (arid, placed) = run("func f(_ d: D, _ a: Int) { d.debug(a + 1); d.trace(a + 2); d.send(a + 3) }")
        #expect(arid.contains("ArithmeticOperator: a + 1 -> a - 1"))
        #expect(arid.contains("ArithmeticOperator: a + 2 -> a - 2"))
        #expect(placed.contains("ArithmeticOperator: a + 3 -> a - 3"))
    }

    @Test func canBeDisabledOrExtended() {
        #expect(run("func f(_ a: Int) { print(a + 1) }", options: AnalyzeOptions(aridCallees: nil)).arid.isEmpty)
        #expect(run("func f(_ a: Int) { metrics.count(a + 1) }", options: AnalyzeOptions(aridCallees: ["metrics.*"])).arid.contains("ArithmeticOperator: a + 1 -> a - 1"))
    }

    @Test func aridMutantsAreNotPlaced() {
        #expect(emitted("func f(_ a: Int) { print(a + 1) }").1.keys.isEmpty)
    }
}
