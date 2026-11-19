import Foundation
import MutatorCore
import Testing
@testable import MutatorCLI

// Ported from mizchi/mutator: the "mutation switching oracle" of packages/core/test/instrument.test.ts
// and mutators.test.ts, and its "coverage counters". Running the instrumented program with mutant k
// active must behave exactly like the source with only k applied. Swift compiles, so each mutant
// applied on its own is a separate build; a mutant that does not compile on its own is skipped
// (the tool reports it as CompileError).

/// Every mutator over plain values; `report()` prints the results.
private let corpus = """
func arithmetic() -> [Int] { [1 + 2 * 3, 7 - 4 / 2, 9 % 4, -(1 + 1)] }
func nested(_ a: Int, _ b: Int) -> Bool { (a + b) * (a - b) > 0 && a != b }
func logical(_ a: Int?, _ b: Bool, _ c: Bool) -> [Int] { [a ?? 7, b && c ? 1 : 0, b || c ? 1 : 0, !b ? 1 : 0] }
func conditional() -> Int { var n = 0; for i in 0 ..< 3 { if i % 2 == 0 { n += i } else { n -= 1 } }; return n }
func whileLoop() -> Int { var i = 0; var s = 0; while i < 5 { s += i; i += 1 }; return s }
func strings(_ name: String) -> [String] { ["hi \\(name)", "", "abc", name.uppercased(), name.hasPrefix("x") ? "p" : "q"] }
func collections() -> [Int] { [[1, 2].count, [Int]().count, ["a": 1, "b": 2].count] }
func optional(_ s: String?) -> Int? { s?.utf8.count }
func assign() -> Int { var v = 10; v += 2; v *= 3; v -= 1; return v }
func booleans() -> [Bool] { [true, false, !true] }
func methods(_ xs: [Int]) -> [Int] { xs.filter { $0 > 1 }.sorted() + [max(xs.min() ?? 0, 1)] }
func labeled() -> Int { var t = 0; outer: for i in 0 ..< 3 { for j in 0 ..< 3 { if j > i { continue outer }; t += 1 } }; return t }
func switching(_ x: Int, _ word: String) -> Int { switch word { case "one": return 1; default: break }; switch (x, word) { case (let n, "two"): return n * 10; default: break }; switch x { case 1: return x + 1; default: return x - 1 } }
func guarded(_ x: Int?) -> Int { guard let x, x > 2 else { return -1 }; return x * 2 }
func repeated() -> Int { var k = 0; repeat { k += 2 } while k < 5; return k }
func pick(_ c: Bool) -> Int { if c { 10 } else { 20 } }
func regex(_ s: String) -> Bool { s.wholeMatch(of: /^[a-c]+\\d{1,2}$/) != nil }
func calls() -> [Int] { var log: [Int] = []; func record(_ v: Int) { log.append(v) }; record(1); record(2); log.reverse(); return log }
struct Counter { var value = 1 + 1; var doubled: Int { value * 2 }; mutating func bump() { value += 1 } }
func counter() -> Int { var c = Counter(); c.bump(); return c.doubled }
func report() -> String {
    "\\(arithmetic()) \\(nested(3, 1)) \\(nested(2, 2)) \\(logical(nil, true, false)) \\(conditional()) \\(whileLoop()) \\(strings("xy")) \\(collections()) \\(String(describing: optional("abc"))) \\(String(describing: optional(nil))) \\(assign()) \\(booleans()) \\(methods([3, 1, 2])) \\(labeled()) \\(switching(1, "one")) \\(switching(5, "two")) \\(guarded(4)) \\(guarded(1)) \\(repeated()) \\(pick(true)) \\(regex("ab1")) \\(regex("x")) \\(calls()) \\(counter())"
}
"""

private enum Outcome: Equatable {
    case output(String)
    /// Crashed or ran out of time: the two are equivalent for a test, which fails either way.
    case abnormal
}

/// Builds `source` as a program printing `report()`; nil when it does not compile. One file and one
/// frontend job: the corpus is all declarations, so `@main` can sit next to it.
private func build(_ source: String, in dir: URL) async throws -> URL? {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try (source + "\n@main enum Main { static func main() { print(report()) } }\n").write(to: dir.appendingPathComponent("Corpus.swift"), atomically: true, encoding: .utf8)
    let result = try await runProcess("swiftc", ["-swift-version", "6", "-Onone", "-parse-as-library", "Corpus.swift", "-o", "program"], cwd: dir)
    return result.status == 0 ? dir.appendingPathComponent("program") : nil
}

/// Runs a program like a test process (the environment of `TestRunner`). A run takes milliseconds,
/// but macOS checks a new binary on its first launch, which under the load of parallel builds can
/// take seconds: the timeout, which cuts looping mutants short, leaves room for that.
private func run(_ program: URL, environment: [String: String] = [:]) async throws -> Outcome {
    let result = try await runProcess(program.path, [], cwd: program.deletingLastPathComponent(), environment: testEnvironment(environment), timeoutMs: 10000)
    return result.status == 0 && !result.timedOut ? .output(result.stdout) : .abnormal
}

private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("swift-mutator-oracle-\(UUID().uuidString)")
}

@Suite struct SwitchingOracleTests {
    @Test func everyMutantBehavesLikeTheSourceWithOnlyThatMutantApplied() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let analysis = analyze(file: "Corpus.swift", source: corpus)
        let placed = analysis.mutants.filter { $0.ignored == nil }
        #expect(Set(placed.map(\.mutator)).isSuperset(of: [.regex, .callExpression, .fnValue, .conditionalExpression, .optionalChaining, .methodExpression]))
        async let instrumentedBuild = build(emit(Array(corpus.utf8), analysis).code, in: root.appendingPathComponent("instrumented"))
        async let originalBuild = build(corpus, in: root.appendingPathComponent("original"))
        let instrumented = try #require(try await instrumentedBuild)
        let original = try #require(try await originalBuild)
        #expect(try await run(instrumented) == run(original))

        let verdicts = await concurrentMap(Array(placed.enumerated()), limit: ProcessInfo.processInfo.activeProcessorCount) { index, mutant -> (String, Outcome, Outcome)? in
            guard let applied = try? await build(applyMutant(corpus, mutant), in: root.appendingPathComponent("m\(index)")) else { return nil }
            async let expected = run(applied)
            async let actual = run(instrumented, environment: [activeEnvironment: mutant.key])
            guard let expected = try? await expected, let actual = try? await actual else { return nil }
            return (formatMutant(mutant), expected, actual)
        }
        let compared = verdicts.compactMap { $0 }
        for (label, expected, actual) in compared { #expect(actual == expected, "\(label)") }
        // Most mutants compile on their own; the few that do not are CompileErrors in a real run.
        #expect(compared.count * 10 >= placed.count * 8, "only \(compared.count) of \(placed.count) mutants compiled on their own")
    }

    @Test func coverageRecordsTheSwitchesReachedOnceEach() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "func used(_ a: Int) -> Int { a + 1 }\nfunc unused(_ a: Int) -> Int { a * 2 }\nfunc report() -> String { \"\\(used(1)) \\(used(2))\" }\n"
        let analysis = analyze(file: "Corpus.swift", source: source)
        let program = try #require(try await build(emit(Array(source.utf8), analysis).code, in: root))
        let file = root.appendingPathComponent("coverage.txt")

        #expect(try await run(program, environment: [coverageEnvironment: file.path]) == .output("2 3\n"))
        let recorded = try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
        let reached = analysis.mutants.filter { $0.scope.id != "unused(_:)" }.map(\.key)
        #expect(analysis.mutants.contains { $0.scope.id == "unused(_:)" })
        // `used` is reached twice and recorded once; the function no one calls is not recorded.
        #expect(recorded.sorted() == reached.sorted())
    }

    @Test func mutantRunsRecordNothing() async throws {
        let root = scratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = "func used(_ a: Int) -> Int { a + 1 }\nfunc report() -> String { \"\\(used(1))\" }\n"
        let analysis = analyze(file: "Corpus.swift", source: source)
        let program = try #require(try await build(emit(Array(source.utf8), analysis).code, in: root))
        let key = try #require(analysis.mutants.first { $0.mutator == .arithmeticOperator }?.key)
        #expect(try await run(program, environment: [activeEnvironment: key]) == .output("0\n"))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("coverage.txt").path))
    }
}
