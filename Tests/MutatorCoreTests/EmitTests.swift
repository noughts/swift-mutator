import Testing
@testable import MutatorCore

/// The instrumented code without the appended runtime.
private func body(_ emission: Emission) -> String {
    String(emission.code.split(separator: "\n\n// ---- swift-mutator runtime", maxSplits: 1, omittingEmptySubsequences: false)[0])
}

@Suite struct EmitTests {
    @Test func expressionSwitch() {
        let (_, emission) = emitted("let x = a + b", excluding: { $0.mutator != .arithmeticOperator })
        #expect(body(emission) == "let x = (__mutator_on(0) ? (a - b) : (a + b))")
        #expect(emission.keys.count == 1)
    }

    @Test func statementSwitchKeepsTheSemicolonOutside() {
        let source = "func f() { g(); h() }"
        let (_, emission) = emitted(source, excluding: { $0.mutator != .callExpression })
        #expect(body(emission) == "func f() { if __mutator_on(0) {  } else { g() }; if __mutator_on(1) {  } else { h() } }")
    }

    @Test func blockSwitchAddsReturnToAnImplicitReturn() {
        let (_, emission) = emitted("func f(_ a: Int) -> Int { a + 1 }", excluding: { $0.mutator != .fnValue && $0.mutator != .arithmeticOperator })
        let code = body(emission)
        #expect(code.hasPrefix("func f(_ a: Int) -> Int { if __mutator_on(0) { return 0 } else if __mutator_on(1) { return 1 } else if __mutator_on(2) { return -1 } else { return (__mutator_on(3) ? (a - 1) : (a + 1)) } }"))
    }

    @Test func excludedMutantsLeaveTheSourceAlone() {
        let source = "let x = a + b"
        let (_, emission) = emitted(source, excluding: { _ in true })
        #expect(emission.code == source)
        #expect(emission.keys.isEmpty)
    }

    @Test func spansPointAtTheMutatedCode() {
        let (analysis, emission) = emitted("let x = a + b", excluding: { $0.mutator != .arithmeticOperator })
        let key = analysis.mutants.first { $0.mutator == .arithmeticOperator }!.key
        let bytes = Array(emission.code.utf8)
        #expect(bytes.text(emission.mutantSpans[key]!) == "a - b")
        #expect(bytes.text(emission.placementSpans[0].span) == "(__mutator_on(0) ? (a - b) : (a + b))")
        // Copied text maps to itself, inserted text to its insertion point.
        #expect(emission.sourceOffset(byteOffset(of: "(a + b)", in: emission.code) + 1) == 8)
        #expect(emission.sourceOffset(byteOffset(of: "__mutator_on", in: emission.code)) == 8)
        #expect(emission.sourceOffset(0) == 0)
    }

    @Test func theRuntimeListsThePlacedKeysInIndexOrder() {
        let (_, emission) = emitted("let x = a + b")
        #expect(emission.code.contains("static let keys: [String] = [\(emission.keys.map { "\"\($0)\"" }.joined(separator: ", "))]"))
        #expect(emission.code.contains("SWIFT_MUTATOR_ACTIVE"))
    }
}
