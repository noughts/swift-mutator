import Testing
@testable import MutatorCore

// Not in the original's tests (Swift-specific rules); the ported ones are in MutatorsTests.swift
// and InstrumentTests.swift.

@Suite struct AnalyzeTests {
    @Test func conditionsOfIfAndGuard() {
        let found = edits("""
        func f(_ x: Int?, _ y: Int) -> Int {
            guard let x, y > 0 else { return 0 }
            if x > y { return 1 }
            return 2
        }
        """)
        #expect(found.contains("ConditionalExpression: y > 0 -> true"))
        #expect(found.contains("ConditionalExpression: y > 0 -> false"))
        #expect(found.contains("ConditionalExpression: x > y -> true"))
        #expect(found.contains("ConditionalExpression: x > y -> false"))
        #expect(found.contains("BlockStatement: { return 1 } -> {}"))
    }

    @Test func scopeIdsFollowTheDeclarationPath() {
        let source = """
        struct Cart {
            var items: [Int] = []
            func total(discount: Int) -> Int { items.map { $0 - discount }.reduce(0, +) }
            var isEmpty: Bool { items.count == 0 }
        }
        """
        let ids = Set(analyze(file: "f.swift", source: source).scopes.map(\.id))
        #expect(ids == ["Cart", "Cart.total(discount:)", "Cart.total(discount:)>map", "Cart.isEmpty.get"])
    }

    @Test func optionalChainingWrapsTheWholeChain() {
        let source = "func f(_ s: String?) -> Int? { s?.utf8.count }"
        let (analysis, emission) = emitted(source)
        #expect(analysis.mutants.first { $0.mutator == .optionalChaining }?.replacement == "!")
        #expect(emission.code.hasPrefix("func f(_ s: String?) -> Int? { "))
        #expect(emission.code.contains("? (s!.utf8.count) :"))
    }

    @Test func typesWrittenLikeLiteralsAreNotMutated() {
        // Found by the switching oracle: `[Int]()` became `[]()`.
        #expect(edits("let a = [Int](); let d = [String: Int](); let r = [Int](repeating: 0, count: 2); let n = [[Int]](); let t = [Int].self; let i = [Int].init()").isEmpty)
    }

    @Test func plainCastsAreTransparent() {
        #expect(!edits(#"x = ("a" as String) + b"#).contains { $0.hasPrefix("ArithmeticOperator") })
        // `0 as Int` already returns 0.
        #expect(analyzed("func f() -> Int { 0 as Int }").filter { $0.mutator == .fnValue }.map(\.replacement) == ["{ return 1 }", "{ return -1 }"])
    }

    @Test func expressionPatternsAreMutatedAndBindingsAreNotWrapped() throws {
        let source = #"func f(_ p: (Int, String)) -> Int { switch p { case (let n, "GET"): return n; default: return 0 } }"#
        let (analysis, emission) = emitted(source)
        let literal = try #require(analysis.mutants.first { $0.original == #""GET""# })
        #expect(literal.ignored == nil)
        // The literal is switched where it is; the pattern binding `let n` is never inside a switch.
        #expect(emission.code.contains(#"case (let n, (__mutator_on("#))
    }
}
