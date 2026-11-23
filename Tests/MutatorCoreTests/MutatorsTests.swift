import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/mutators.test.ts (sources rewritten in Swift).
//
// Not ported: `for (;;)` and `new Array()` rules, the `ranges` option, regex flags, and the
// TypeScript-only types of FnValue (bigint, literal and union types, type predicates, Promise).
// The behavioural oracle is in Tests/MutatorCLITests/SwitchingOracleTests.swift (it compiles).

private func summary(_ source: String, _ only: MutatorName? = nil) -> [String] {
    analyzed(source).filter { only == nil || $0.mutator == only }.map(label)
}

/// Replacements of FnValue only.
private func fnValues(_ source: String) -> [String] {
    analyzed(source).filter { $0.mutator == .fnValue }.map(\.replacement)
}

@Suite struct RegexMutationsTests {
    @Test func anchors() {
        let out = regexMutations("^abc$")
        #expect(out.contains("abc$"))
        #expect(out.contains("^abc"))
    }

    @Test func characterClassNegation() {
        #expect(regexMutations("[abc]").contains("[^abc]"))
        #expect(regexMutations("[^abc]").contains("[abc]"))
    }

    @Test func predefinedClasses() {
        #expect(Set(regexMutations(#"\d\w\s"#)).isSuperset(of: [#"\D\w\s"#, #"\d\W\s"#, #"\d\w\S"#]))
        #expect(Set(regexMutations(#"\D\W\S"#)).isSuperset(of: [#"\d\W\S"#, #"\D\w\S"#, #"\D\W\s"#]))
    }

    @Test func editsComeInPatternOrder() {
        #expect(regexMutations("^[a-z]+\\d$") == ["[a-z]+\\d$", "^[^a-z]+\\d$", "^[a-z]\\d$", "^[a-z]+\\D$", "^[a-z]+\\d"])
    }

    @Test func quantifiers() {
        #expect(Set(regexMutations("a*b?c+")).isSuperset(of: ["ab?c+", "a*bc+", "a*b?c"]))
        #expect(regexMutations("a{1,3}").contains("a{1}"))
        #expect(regexMutations("a{2,}").contains("a{2}"))
        #expect(regexMutations("a{2}").isEmpty)
        #expect(regexMutations("a+?") == ["a"])
    }

    @Test func escapesAndClassesAreRespected() {
        #expect(regexMutations(#"\^\$\+"#).isEmpty)
        // `^` / `$` inside a class are not anchors; only the negation toggle applies.
        #expect(regexMutations("[$^]") == ["[^$^]"])
        #expect(regexMutations(#"[\]^]"#) == [#"[^\]^]"#])
        // `?` right after `(` is group syntax, not a quantifier.
        #expect(regexMutations("(?:a)").isEmpty)
        #expect(regexMutations("(?<n>a)").isEmpty)
        #expect(regexMutations(#"\p{L}+"#) == [#"\p{L}"#])
        #expect(regexMutations(#"\u{1F600}"#).isEmpty)
    }

    @Test(arguments: ["^(a+)+$", #"\k<x>(?<x>a)*"#, #"[a-z]{1,2}\d*"#, "a|^b|c$"])
    func neverYieldsAnInvalidOrUnchangedPattern(pattern: String) {
        for mutated in regexMutations(pattern) {
            #expect(mutated != pattern)
            #expect((try? Regex(mutated)) != nil)
        }
    }
}

@Suite struct RegexMutatorTests {
    @Test func regexLiterals() {
        let out = summary("x = /^a+$/", .regex)
        #expect(out.contains("Regex: /^a+$/ -> /a+$/"))
        #expect(out.contains("Regex: /^a+$/ -> /^a+/"))
        #expect(out.contains("Regex: /^a+$/ -> /^a$/"))
    }

    @Test func regexAndNSRegularExpressionStringArguments() {
        let out = summary(#"x = try Regex("^a"); y = try NSRegularExpression(pattern: "\\d")"#, .regex)
        #expect(out == [##"Regex: "^a" -> #"a"#"##, ##"Regex: "\\d" -> #"\D"#"##])
    }

    @Test func neverProducesAnEmptyRegexLiteral() {
        #expect(summary("x = /^/", .regex).isEmpty)
    }
}

@Suite struct CallExpressionMutatorTests {
    @Test func callStatementsAreEmptied() {
        #expect(summary("f(); a.b(c); g(1 + 2)", .callExpression) == ["CallExpression: f() -> ", "CallExpression: a.b(c) -> "])
    }

    @Test func notForSuperInitThrowOrStatementsThatAlreadyCarryMutants() {
        let source = """
        class B: A { override init() { super.init() } }
        func t() throws { throw E(x) }
        func s(_ arr: [Int]) { arr.sorted() }
        func u() { h { k(1 + 1) } }
        """
        #expect(summary(source, .callExpression).isEmpty)
    }
}

@Suite struct ConditionalExpressionThroughWrappersTests {
    @Test(arguments: ["(a > b) as Bool", "(a > b)", "((a > b))"])
    func aWrappedConditionIsMutatedOnceByTheStatement(condition: String) {
        #expect(summary("if \(condition) { f() }", .conditionalExpression) == ["ConditionalExpression: \(condition) -> true", "ConditionalExpression: \(condition) -> false"])
    }

    @Test func aWrappedOperandOfOrAndAndSkipsTheCollapsingValue() {
        let operand = { (source: String) in summary(source, .conditionalExpression).filter { $0.contains(": a > b ") } }
        #expect(operand("let v = x || ((a > b) as Bool)") == ["ConditionalExpression: a > b -> false"])
        #expect(operand("let v = x && (a > b) as Bool") == ["ConditionalExpression: a > b -> true"])
    }
}

@Suite struct ConditionalExpressionOfBindingsTests {
    @Test func aConditionListOfBindingsOnlyGetsAFalseAppended() {
        #expect(summary("func f(_ a: Int?, _ b: Int?) { guard let a, let b else { return }; g(a, b) }", .conditionalExpression) == ["ConditionalExpression: let a, let b -> let a, let b, false"])
        #expect(summary("func f(_ x: E) { if case .a = x { g() } }", .conditionalExpression) == ["ConditionalExpression: case .a = x -> case .a = x, false"])
        #expect(summary("func f() { while let x = next() { g(x) } }", .conditionalExpression) == ["ConditionalExpression: let x = next() -> let x = next(), false"])
    }

    @Test func aListWithABooleanConditionKeepsItsOwnMutants() {
        #expect(summary("func f(_ a: Int?) { if let a, a > 1 { g() } }", .conditionalExpression) == ["ConditionalExpression: a > 1 -> true", "ConditionalExpression: a > 1 -> false"])
    }

    @Test func theSwitchIsAppendedToTheList() {
        let source = "func f(_ a: Int?) -> Int {\n    guard let a else { return 0 }\n    return a\n}"
        let analysis = analyze(file: "A.swift", source: source)
        let code = emit(Array(source.utf8), analysis).code
        #expect(code.contains(/guard let a, !__mutator_on\(\d+\) else/))
    }
}

@Suite struct ConditionalExpressionInASwitchCaseTests {
    @Test func aComparisonUsedAsACasePatternIsMutatedLikeAnyOtherComparison() {
        #expect(summary("switch x { case a == b: f() default: break }", .conditionalExpression) == ["ConditionalExpression: a == b -> true", "ConditionalExpression: a == b -> false"])
    }
}

@Suite struct BlockStatementAndInitializersTests {
    // Swift initializers are never emptied: every stored property must be initialized, and a
    // class initializer must call super.init.
    @Test func anInitializerIsNeverEmptied() {
        #expect(summary("class B: A { override init() { super.init(); x = 1 } }", .blockStatement).isEmpty)
        #expect(summary("struct C { var a: Int; init(a: Int) { self.a = a } }", .blockStatement).isEmpty)
    }

    // Emptying these blocks does not compile, and Swift reports it only once the module
    // type-checks, a build round of its own: they are not emptied.
    @Test func aBlockInitializingAConstantDeclaredBeforeIsNotEmptied() {
        let source = "func f(_ c: Bool) -> Int { let x: Int; if c { x = 1 } else { x = 2 }; return x }"
        #expect(summary(source, .blockStatement).isEmpty)
        #expect(summary("func f(_ c: Bool) -> Int { var y: Int; do { y = try g() } catch { y = 0 }; return y }", .blockStatement).isEmpty)
        // The branch that returns is all that keeps `x` from being used uninitialized.
        #expect(summary("func f(_ a: Bool, _ b: Bool) -> Int { let x: Int; if a { x = 1 } else if b { x = 2 } else { return 0 }; return x }", .blockStatement).isEmpty)
        // Initialized where declared: the assignment may go.
        #expect(summary("func f(_ c: Bool) -> Int { var y = 0; if c { y = 1 }; return y }", .blockStatement) == ["BlockStatement: { y = 1 } -> {}"])
    }

    @Test func aBlockAssigningInAnInitializerIsNotEmptied() {
        #expect(summary("struct C { var a: Int; init(c: Bool) { if c { self.a = 1 } else { a = 2 } } }", .blockStatement).isEmpty)
        #expect(summary("struct C { init(c: Bool) { if c { print(1) } } }", .blockStatement) == ["BlockStatement: { print(1) } -> {}"])
    }

    @Test func aBranchOfAnIfElseThatReturnsIsNotEmptied() {
        #expect(summary("func f(_ c: Bool) -> Int { if c { return 1 } else { return 2 } }", .blockStatement).isEmpty)
        #expect(summary("func f(_ a: Bool, _ b: Bool) -> Int { if a { if b { return 1 } else { return 2 } } else { return 3 } }", .blockStatement).isEmpty)
        #expect(summary("func f() -> Int { do { return try g() } catch { throw E() } }", .blockStatement).isEmpty)
        #expect(summary("var v: Int { if c { return 1 } else { return 2 } }", .blockStatement).isEmpty)
        #expect(summary("func f(_ x: Int, _ c: Bool) -> Int { switch x { case 0: if c { return 1 } else { return 2 } default: return 3 } }", .blockStatement).isEmpty)
        #expect(summary("func f(_ x: Int?, _ c: Bool) -> Int { guard let x else { if c { return 1 } else { return 2 } }; return x }", .blockStatement).isEmpty)
        // The code after the `if` returns instead, or nothing is returned at all.
        #expect(summary("func f(_ c: Bool) -> Int { if c { return 1 }; return 2 }", .blockStatement) == ["BlockStatement: { return 1 } -> {}"])
        #expect(summary("func f(_ c: Bool) -> Int { if c { return 1 } else { log() }; return 2 }", .blockStatement) == ["BlockStatement: { return 1 } -> {}", "BlockStatement: { log() } -> {}"])
        #expect(summary("func f(_ c: Bool) { if c { return } else { return } }", .blockStatement).filter { $0.hasPrefix("BlockStatement: { return }") }.count == 2)
    }
}

@Suite struct FnValueMutatorTests {
    @Test func primitiveReturnTypes() {
        #expect(fnValues("func f() -> Bool { return g() }") == ["{ return true }", "{ return false }"])
        #expect(fnValues("func f() -> Int { return g() }") == ["{ return 0 }", "{ return 1 }", "{ return -1 }"])
        #expect(fnValues("func f() -> String { return g() }") == [#"{ return "" }"#, #"{ return "xyzzy" }"#])
        #expect(fnValues("func f() -> UInt8 { return g() }") == ["{ return 0 }", "{ return 1 }"])
    }

    @Test func collectionsOptionalsAndParentheses() {
        #expect(fnValues("func f() -> [Int] { return g() }") == ["{ return [] }"])
        #expect(fnValues("func f() -> Array<Int> { return g() }") == ["{ return [] }"])
        #expect(fnValues("func f() -> Set<Int> { return g() }") == ["{ return [] }"])
        #expect(fnValues("func f() -> [String: Int] { return g() }") == ["{ return [:] }"])
        #expect(fnValues("func f() -> String? { return g() }") == ["{ return nil }", #"{ return "" }"#, #"{ return "xyzzy" }"#])
        #expect(fnValues("func f() -> Optional<Bool> { return g() }") == ["{ return nil }", "{ return true }", "{ return false }"])
        #expect(fnValues("func f() -> (Bool) { return g() }") == ["{ return true }", "{ return false }"])
    }

    @Test func asyncAndThrowingFunctions() {
        #expect(fnValues("func f() async throws -> Bool { return try await g() }") == ["{ return true }", "{ return false }"])
    }

    @Test func skippedFunctionsAndTypes() {
        let source = """
        class C { init() {}; deinit {}; var x: Int { get { g() } set {} }; func m() { g() } }
        func a() -> Any { g() }
        func n() -> Never { fatalError() }
        func o() -> some Equatable { g() }
        func r() -> Foo { g() }
        func t() -> (Int, Int) { g() }
        func nr(_ x: Int) { _ = x }
        """
        #expect(fnValues(source).isEmpty)
    }

    @Test func voidIsLeftToBlockStatement() {
        let mutants = analyzed("func f() { g() }")
        #expect(mutants.filter { $0.replacement == "{}" }.map(\.mutator) == [.blockStatement])
        #expect(fnValues("func f() { g() }").isEmpty)
        #expect(fnValues("func f() -> Void { g() }").isEmpty)
    }

    @Test func skipsACandidateEqualToTheExistingBody() {
        #expect(fnValues("func f() -> Bool { return true }") == ["{ return false }"])
        #expect(fnValues(#"func f() -> String { return "" }"#) == [#"{ return "xyzzy" }"#])
        #expect(fnValues("func f() -> Int { return  -1 }") == ["{ return 0 }", "{ return 1 }"])
        #expect(fnValues("func f() -> Int { 0 }") == ["{ return 1 }", "{ return -1 }"])
    }

    @Test func comparisonEditsKeepTheirMutatorName() {
        let out = summary("func f(_ x: Int) -> Bool { x > 1 }").filter { $0.contains("x > 1 -> true") || $0.contains("x > 1 -> false") }
        #expect(out == ["ConditionalExpression: x > 1 -> true", "ConditionalExpression: x > 1 -> false"])
    }

    @Test func methods() {
        #expect(fnValues("class K { func m() -> Int { g() }; static func s() -> Bool { g() } }").count == 3 + 2)
    }
}
