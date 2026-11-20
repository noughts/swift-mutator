import Testing
@testable import MutatorCore

@Suite struct DiagnosticsTests {
    @Test func parsesErrorsThroughColorsAndHyperlinks() {
        let output = """
        [1;31merror: [0mbuild failed
        /tmp/s/Sources/A.swift:3:17: \u{1B}[1;31merror: \u{1B}[1;39mbinary operator '-' cannot be applied\u{1B}[0;0m \u{1B}]8;;https://docs.swift.org/x\u{1B}\\[#Doc]\u{1B}]8;;\u{1B}\\
        /tmp/s/Sources/A.swift:3:17: error: binary operator '-' cannot be applied
        /tmp/s/Sources/A.swift:9:1: warning: unused
        """
        let errors = parseCompilerErrors(output)
        #expect(errors.count == 2)
        #expect(errors[0] == CompilerError(path: "/tmp/s/Sources/A.swift", line: 3, column: 17, message: "binary operator '-' cannot be applied [#Doc]"))
    }

    private func file(_ source: String) -> InstrumentedFile {
        let analysis = analyze(file: "A.swift", source: source)
        return InstrumentedFile(analysis: analysis, emission: emit(Array(source.utf8), analysis))
    }

    private func error(at needle: String, in file: InstrumentedFile) -> CompilerError {
        let code = file.emission.code
        let position = LineIndex(Array(code.utf8)).position(byteOffset(of: needle, in: code))
        return CompilerError(path: "A.swift", line: position.line, column: position.column + 1, message: "")
    }

    @Test func anErrorInsideMutatedCodeBlamesThatMutant() {
        let f = file("func join(_ a: String, _ b: String) -> String { a + b }")
        let blamed = blame([error(at: "a - b", in: f)], files: ["A.swift": f])
        let culprit = f.analysis.mutants.first { $0.replacement == "a - b" }!
        #expect(blamed.keys == [culprit.key])
        #expect(blamed.unattributed.isEmpty)
    }

    @Test func anErrorElsewhereInAFunctionBlamesItsMutants() {
        let f = file("func f(_ a: Int) -> Int {\n    let b = a + 1\n    return b\n}")
        // Points at `return b`: no switch around it, so the function's mutants are suspects.
        let blamed = blame([error(at: "return b", in: f)], files: ["A.swift": f])
        #expect(!blamed.keys.isEmpty)
        #expect(blamed.keys.isSubset(of: Set(f.emission.keys)))
    }

    @Test func anErrorOutsideAnyMutantBlamesTheMutantsOfItsStatement() {
        let source = "func f(_ a: Int, _ b: Int) -> Int {\n    let c = a + b\n    return c * 2\n}"
        let f = file(source)
        // A type error a mutant causes may show anywhere in its expression.
        let blamed = blame([error(at: "let c", in: f)], files: ["A.swift": f])
        #expect(blamed.keys == Set(f.analysis.mutants.filter { $0.original == "a + b" }.map(\.key)))
    }

    @Test func anErrorThatStaysIsBlamedOnTheNextStatementOut() {
        let source = "func f(_ a: Int, _ b: Int) -> Int {\n    let c = a + b\n    return c * 2\n}"
        // The statement's mutants were left out and the error is still there.
        let analysis = analyze(file: "A.swift", source: source)
        let first = Set(analysis.mutants.filter { $0.original == "a + b" }.map(\.key))
        let f = InstrumentedFile(analysis: analysis, emission: emit(Array(source.utf8), analysis, excluding: first))
        let blamed = blame([error(at: "let c", in: f)], files: ["A.swift": f])
        #expect(blamed.keys == Set(f.emission.keys))
        #expect(blamed.keys.isDisjoint(with: first))
    }

    @Test func errorsInFilesWithoutMutantsAreUnattributed() {
        let f = file("func f(_ a: Int) -> Int { a + 1 }")
        let other = CompilerError(path: "B.swift", line: 1, column: 1, message: "x")
        #expect(blame([other], files: ["A.swift": f]).unattributed == [other])
    }
}
