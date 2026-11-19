import Testing
@testable import MutatorCore

@Suite struct DisableTests {
    private func reasons(_ source: String) -> [String: String] {
        let found = analyze(file: "f.swift", source: source).mutants
        return Dictionary(found.map { ("\($0.mutator.rawValue) \($0.original)", $0.ignored ?? "-") }, uniquingKeysWith: { first, _ in first })
    }

    @Test func nextLineAndSameLine() {
        let r = reasons("""
        func f(_ a: Int) -> Int {
            // mutator-disable-next-line
            let x = a + 1
            let y = a * 2 // mutator-disable-line ArithmeticOperator
            return x - y
        }
        """)
        #expect(r["ArithmeticOperator a + 1"] == "disabled")
        #expect(r["ArithmeticOperator a * 2"] == "disabled")
        #expect(r["ArithmeticOperator x - y"] == "-")
    }

    @Test func regionsAndMutatorNames() {
        let r = reasons("""
        func f(_ a: Int) -> Bool {
            // mutator-disable EqualityOperator: thresholds are tuned elsewhere
            let x = a > 1
            let y = a + 1 > 2
            // mutator-enable
            return x && y && a < 3
        }
        """)
        #expect(r["EqualityOperator a > 1"] == "disabled: thresholds are tuned elsewhere")
        #expect(r["ArithmeticOperator a + 1"] == "-")
        #expect(r["EqualityOperator a < 3"] == "-")
    }

    @Test func strykerComments() {
        let r = reasons("""
        func f(_ a: Int) -> Int {
            // Stryker disable next-line all
            return a + 1
        }
        """)
        #expect(r["ArithmeticOperator a + 1"] == "disabled")
    }
}
