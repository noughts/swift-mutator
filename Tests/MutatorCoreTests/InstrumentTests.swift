import Testing
@testable import MutatorCore

// Ported from mizchi/mutator packages/core/test/instrument.test.ts (sources rewritten in Swift).
//
// Not ported: the `ranges` option, sourcemaps, JavaScript-only syntax (ASI, `++`, object keys,
// directives), module facts (`refs`, `declares`, `pure`, imports, `scanImports`), plugins and the
// hit limit. The mutation switching oracle and the coverage counters compile and run the
// instrumented code: see Tests/MutatorCLITests/SwitchingOracleTests.swift.

private func summary(_ mutants: [Mutant]) -> [String] { mutants.map(label) }

private func mutants(_ source: String, file: String = "m.swift", options: AnalyzeOptions = .init()) -> [Mutant] {
    analyzed(source, file: file, options: options)
}

@Suite struct MutantDiscoveryTests {
    @Test func arithmetic() {
        let out = summary(mutants("func f(_ a: Int, _ b: Int, _ c: Int) -> Int { a + b * c }"))
        #expect(out.contains("ArithmeticOperator: a + b * c -> a - b * c"))
        #expect(out.contains("ArithmeticOperator: b * c -> b / c"))
    }

    @Test func equalityEmitsBoundaryAndNegationMutants() {
        let out = summary(mutants("if a < b {}"))
        for expected in ["EqualityOperator: a < b -> a <= b", "EqualityOperator: a < b -> a >= b", "ConditionalExpression: a < b -> true", "ConditionalExpression: a < b -> false"] {
            #expect(out.contains(expected))
        }
    }

    @Test func stringConcatenationIsNotArithmeticMutated() {
        #expect(mutants(#"x = "a" + b"#).filter { $0.mutator == .arithmeticOperator }.isEmpty)
    }

    @Test func typePositionsAreNeverMutated() {
        let source = #"typealias T = String; let x: T = "a"; func f(_ a: [String: Int]) -> String { "x" as String }"#
        let found = mutants(source)
        let bytes = Array(source.utf8)
        let typeAlias = Span(start: 0, end: byteOffset(of: ";", in: source))
        #expect(!found.contains { typeAlias.contains($0.span) })
        #expect(summary(found).contains(#"StringLiteral: "a" -> """#))
        #expect(summary(found).contains(#"StringLiteral: "x" -> """#))
        #expect(!found.contains { bytes.text($0.span).contains("String: Int") })
    }

    @Test func importsAttributesAndRawValuesAreNotMutated() {
        let source = """
        import Foundation
        enum E: String { case a = "raw" }
        @available(*, deprecated, message: "old")
        func f() {}
        """
        #expect(mutants(source).isEmpty)
    }

    @Test func excludedMutators() {
        #expect(mutants("x = a + b", options: AnalyzeOptions(excludedMutators: [.arithmeticOperator])).isEmpty)
    }

    @Test func locationsAreOneBasedLines() throws {
        let m = try #require(mutants("x = 1\ny = a + b").first { $0.mutator == .arithmeticOperator })
        #expect(m.location == Location(start: Position(line: 2, column: 4), end: Position(line: 2, column: 9)))
    }
}

@Suite struct IdentityTests {
    let base = "func add(_ a: Int, _ b: Int) -> Int {\n    return a + b\n}\nfunc sub(_ a: Int, _ b: Int) -> Int {\n    return a - b\n}\n"

    private func keys(_ source: String, _ scope: String) -> [String] {
        mutants(source).filter { $0.scope.id == scope }.map(\.key).sorted()
    }

    @Test func keysAreStableAcrossUnrelatedEditsAndLineShifts() {
        let edited = "// header comment\n\n" + base.replacingOccurrences(of: "a - b", with: "a - b - 1")
        #expect(keys(edited, "add(_:_:)") == keys(base, "add(_:_:)"))
    }

    @Test func scopeHashIgnoresCommentsAndWhitespaceButTracksCode() {
        let hash = { (source: String) in mutants(source).first { $0.scope.id == "add(_:_:)" }!.scope.hash }
        #expect(hash(base.replacingOccurrences(of: "return a + b", with: "return a  +  b // c")) == hash(base))
        #expect(hash(base.replacingOccurrences(of: "return a + b", with: "return a + b + 0")) != hash(base))
    }

    @Test func scopeIdsArePositionIndependentPaths() {
        let source = "class K { func m() -> Int { let inner = { 1 + 1 }; return inner() } }\nlet f = { () -> Int in 2 * 2 }"
        #expect(Set(mutants(source).map(\.scope.id)) == ["K.m()", "K.m()>inner", "f"])
    }

    @Test func keysAreUniqueWithinAFile() {
        let source = """
        func a(_ x: Int) -> Int { x + 1 }
        func b(_ x: Int) -> Int { x + 1 }
        func c(_ xs: [Int]) -> [Int] { xs.map { $0 + 1 }.map { $0 + 1 }.filter { $0 > 1 } }
        struct S { var v = 1 + 1; func a(_ x: Int) -> Int { x + 1 }; func a(_ x: String) -> Int { 1 + 1 } }
        """
        let found = mutants(source)
        #expect(found.count > 20)
        #expect(Set(found.map(\.key)).count == found.count)
    }

    @Test func keysDependOnTheIdentityPathNotOnTheCheckout() {
        let source = "func f(_ a: Int, _ b: Int) -> Int { a + b }"
        let a = mutants(source, file: "Sources/M/m.swift").map(\.key)
        #expect(a == mutants(source, file: "Sources/M/m.swift").map(\.key))
        #expect(a != mutants(source, file: "Sources/N/m.swift").map(\.key))
    }

    @Test func methodsOfDifferentTypesAreNamedAfterTheirOwner() {
        let source = "struct Tested { func run() -> Int { 1 + 1 } }\nstruct Untested { func run() -> Int { 2 + 2 } }"
        #expect(Set(mutants(source).map(\.scope.id)) == ["Tested.run()", "Untested.run()"])
    }

    @Test func swappingTwoTypesKeepsEachMethodIdentity() {
        let a = "struct Tested { func run() -> Int { 1 + 1 } }\nstruct Untested { func run() -> Int { 1 + 1 } }"
        let b = "struct Untested { func run() -> Int { 1 + 1 } }\nstruct Tested { func run() -> Int { 1 + 1 } }"
        let keyed = { (source: String) in Dictionary(uniqueKeysWithValues: mutants(source).map { ("\($0.scope.id) \($0.mutator.rawValue) \($0.replacement)", $0.key) }) }
        #expect(keyed(b) == keyed(a))
    }
}

@Suite struct OutputTests {
    @Test func preservesFormattingOutsideMutatedRegions() {
        let source = "let   spaced  =  1\nlet r = spaced + 1\n"
        #expect(emitted(source).1.code.hasPrefix("let   spaced  =  1\n"))
    }

    @Test func typeAnnotationsAreKept() {
        let source = "public func f(_ a: Int) -> Int { return a + 1 }"
        #expect(emitted(source).1.code.contains("_ a: Int) -> Int"))
    }

    @Test func keepsTheShebangFirst() {
        let source = "#!/usr/bin/env swift\nx = 1 + 1\n"
        #expect(emitted(source).1.code.hasPrefix("#!/usr/bin/env swift\n"))
    }

    @Test func noMutantsLeavesTheSourceUnchanged() {
        let source = "import Foundation\npublic typealias X = Int\n"
        #expect(emitted(source).1.code == source)
    }
}

@Suite struct InstrumentRegressionTests {
    @Test func methodNamesOutsideTheTablesAreNotMutated() {
        #expect(mutants(#"x = n.formatted(); y = o.description; z = d.index(forKey: "k")"#).filter { $0.mutator == .methodExpression }.isEmpty)
    }

    @Test func nilCoalescingChainsGiveTheDefaultOfEachLevel() {
        // `??` is right-associative: `a ?? (b ?? c)`.
        let out = summary(mutants("x = a ?? b ?? c")).filter { $0.hasPrefix("LogicalOperator") }
        #expect(out == ["LogicalOperator: a ?? b ?? c -> b ?? c", "LogicalOperator: b ?? c -> c"])
    }
}

@Suite struct ScopesTests {
    @Test func everyFunctionAndTopLevelStatementIsReportedWithOrWithoutMutants() {
        let scopes = analyze(file: "m.swift", source: "let LIMIT = 10\nfunc noop() {}\nfunc f(_ n: Int) -> Bool { n > LIMIT }\n").scopes
        #expect(scopes.map(\.id).filter { !isTopLevelScope($0) } == ["noop()", "f(_:)"])
        #expect(scopes.filter { isTopLevelScope($0.id) }.count == 1)
    }

    @Test func editingAFunctionKeepsTheTopLevelScopes() {
        let top = { (source: String) in analyze(file: "m.swift", source: source).scopes.filter { isTopLevelScope($0.id) }.map { "\($0.id):\($0.hash)" } }
        #expect(top("func f(_ a: Int) -> Int { a + 1 }\nlet X = 1") == top("func f(_ a: Int) -> Int { a + 2 }\nlet X = 1"))
    }

    @Test func anOuterFunctionHashIgnoresTheBodyOfNestedFunctions() {
        let scope = { (inner: String, id: String) in
            analyze(file: "m.swift", source: "func outer() -> Int { let g = { \(inner) }; return g() + 1 }").scopes.first { $0.id == id }!.hash
        }
        #expect(scope("1", "outer()") == scope("2", "outer()"))
        #expect(scope("1", "outer()>g") != scope("2", "outer()>g"))
    }
}

@Suite struct AnonymousScopeNameTests {
    private func ids(_ source: String) -> [String] {
        Array(Set(mutants(source).map(\.scope.id))).filter { !isTopLevelScope($0) }.sorted()
    }

    @Test func callbacksAreNamedAfterTheCallAndItsFirstStringArgument() {
        let source = #"describe("math") { it("adds") { expect(1 + 1) } }"# + "\nlet xs = [1, 2].map { $0 * 2 }"
        #expect(ids(source) == [#"describe("math")"#, #"describe("math")>it("adds")"#, "map"])
    }

    @Test func insertingAnUnrelatedCallbackDoesNotRenameTheOthers() {
        let before = #"register("a") { 1 + 1 }"# + "\n" + #"register("b") { 2 + 2 }"# + "\nitems.forEach { _ = $0 - 1 }"
        let after = #"register("a") { 1 + 1 }"# + "\nother { 9 * 9 }\n" + #"register("b") { 2 + 2 }"# + "\nitems.forEach { _ = $0 - 1 }"
        let keyed = { (source: String) in Dictionary(uniqueKeysWithValues: mutants(source).map { ("\($0.scope.id) \($0.original) -> \($0.replacement)", $0.key) }) }
        let a = keyed(before)
        let b = keyed(after)
        for (label, key) in a { #expect(b[label] == key, "\(label)") }
    }

    @Test func insertingASameNamedCallbackKeepsTheIdsOfTheOthers() {
        let ids = { (source: String) in mutants(source).map(\.scope.id) }
        let before = ids("a.map { $0 + 1 }\nb.map { $0 * 2 }\nc.map { $0 - 3 }")
        let after = ids("a.map { $0 + 1 }\nd.map { $0 - 1 }\nb.map { $0 * 2 }\nc.map { $0 - 3 }")
        #expect(before.allSatisfy(after.contains))
        #expect(Set(after.filter { !before.contains($0) }).count == 1)
    }
}
