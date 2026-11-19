import Testing
@testable import MutatorCore

private func mutants(_ source: String, options: AnalyzeOptions = .init()) -> [Mutant] {
    analyze(file: "Sources/Lib/File.swift", source: source, options: options).mutants
}

private func edits(_ source: String) -> [String] {
    mutants(source).filter { $0.ignored == nil }.map { "\($0.mutator.rawValue): \($0.original) -> \($0.replacement)" }
}

@Suite struct AnalyzeTests {
    @Test func arithmeticAndEquality() {
        let found = edits("func f(_ a: Int, _ b: Int) -> Bool { a + b > 2 }")
        #expect(found.contains("ArithmeticOperator: a + b -> a - b"))
        #expect(found.contains("EqualityOperator: a + b > 2 -> a + b >= 2"))
        #expect(found.contains("EqualityOperator: a + b > 2 -> a + b <= 2"))
        #expect(found.contains("ConditionalExpression: a + b > 2 -> true"))
        #expect(found.contains("FnValue: { a + b > 2 } -> { return true }"))
    }

    @Test func stringConcatenationIsNotSubtracted() {
        let found = edits(#"func f(_ name: String) -> String { "Hello " + name }"#)
        #expect(!found.contains { $0.hasPrefix("ArithmeticOperator") })
        #expect(found.contains(#"StringLiteral: "Hello " -> """#))
    }

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

    @Test func keysArePositionIndependent() {
        let a = mutants("func f(_ a: Int) -> Int { a + 1 }")
        let b = mutants("\n\n// moved\nfunc f(_ a: Int) -> Int {\n    a + 1\n}")
        #expect(a.map(\.key) == b.map(\.key))
        #expect(a.first?.scope.hash == b.first?.scope.hash)
        #expect(a.first?.scope.id == "f(_:)")
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

    @Test func disableComments() {
        let found = mutants("""
        func f(_ a: Int) -> Int {
            // mutator-disable-next-line ArithmeticOperator: intentionally unchecked
            let b = a + 1
            return b * 2
        }
        """)
        #expect(found.first { $0.original == "a + 1" }?.ignored == "disabled: intentionally unchecked")
        #expect(found.first { $0.original == "b * 2" }?.ignored == nil)
    }

    @Test func loggingIsArid() {
        let found = mutants(#"func f(_ a: Int) { if a > 1 { print("big \(a + 1)") } }"#)
        #expect(!found.isEmpty)
        #expect(found.allSatisfy { $0.ignored == "arid: logging" })
    }

    @Test func callStatementRemovalOnlyWithoutInnerMutants() {
        let found = edits("""
        func f(_ xs: inout [Int]) {
            xs.removeAll()
            xs.append(1 + 2)
        }
        """)
        #expect(found.contains("CallExpression: xs.removeAll() -> "))
        #expect(!found.contains("CallExpression: xs.append(1 + 2) -> "))
    }

    @Test func optionalChainingWrapsTheWholeChain() {
        let analysis = analyze(file: "f.swift", source: "func f(_ s: String?) -> Int? { s?.utf8.count }")
        let mutant = analysis.mutants.first { $0.mutator == .optionalChaining }
        #expect(mutant?.replacement == "!")
        let code = emit(Array("func f(_ s: String?) -> Int? { s?.utf8.count }".utf8), analysis).code
        #expect(code.hasPrefix("func f(_ s: String?) -> Int? { "))
        #expect(code.contains("? (s!.utf8.count) :"))
    }

    @Test func excludedMutatorsAreNotGenerated() {
        let found = mutants("func f(_ a: Int) -> Int { a + 1 }", options: AnalyzeOptions(excludedMutators: [.arithmeticOperator, .fnValue]))
        #expect(found.isEmpty)
    }
}
