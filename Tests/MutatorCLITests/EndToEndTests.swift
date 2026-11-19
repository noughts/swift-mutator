import Foundation
import MutatorCore
import Testing
@testable import MutatorCLI

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

/// A fresh copy of Examples/Pricing (without build products) in a temporary directory.
private func examplePackage() throws -> URL {
    let fm = FileManager.default
    let root = fm.temporaryDirectory.appendingPathComponent("swift-mutator-e2e-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    let example = repository.appendingPathComponent("Examples/Pricing")
    for item in ["Package.swift", "Sources", "Tests"] {
        try fm.copyItem(at: example.appendingPathComponent(item), to: root.appendingPathComponent(item))
    }
    return root
}

private func snapshot(_ root: URL) throws -> Snapshot {
    try #require(readSnapshot(root.appendingPathComponent(".mutator/snapshot.json")))
}

@Suite(.serialized) struct EndToEndTests {
    @Test func findsTheTestGapsAndReusesResultsOnARerun() async throws {
        let root = try examplePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        var options = Options()
        options.root = root.path
        options.reporters = ["json"]
        options.concurrency = 4

        #expect(try await runMutation(options) == 0)
        let first = try snapshot(root)
        let analyses = try ["Sources/Pricing/Cart.swift", "Sources/Pricing/Shipping.swift"].map { path in
            analyze(file: path, source: try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8))
        }
        let mutants = Dictionary(uniqueKeysWithValues: analyses.flatMap(\.mutants).map { ($0.key, $0) })
        let status = { (original: String, replacement: String) in
            first.results.first { mutants[$0.key]?.original == original && mutants[$0.key]?.replacement == replacement }?.status
        }
        // The boundary 5000 itself is never tested; an empty code is never passed.
        #expect(status("subtotal >= 5000", "subtotal > 5000") == .survived)
        #expect(status("!code.isEmpty", "true") == .survived)
        #expect(status("$0 + $1.price * $1.quantity", "$0 - $1.price * $1.quantity") == .killed)
        // shippingLabel has no test at all.
        #expect(first.results.filter { $0.scopeId == "shippingLabel(fee:)" }.allSatisfy { $0.status == .noCoverage })
        #expect(first.results.filter { $0.status == .killed }.count >= 25)
        // The killers are named: the subtotal test kills the multiplication mutant.
        let multiplication = first.results.first { mutants[$0.key]?.replacement == "$1.price / $1.quantity" }
        #expect(multiplication?.killedBy.contains("PricingTests.CartTests/testSubtotalMultipliesQuantity") == true)
        #expect(FileManager.default.fileExists(atPath: root.appendingPathComponent(".mutator/report/mutation.json").path))

        // Nothing changed: every verdict is reused, no mutant runs (only runs record a duration).
        #expect(try await runMutation(options) == 0)
        let second = try snapshot(root)
        #expect(second.results.allSatisfy { $0.durationMs == nil })
        #expect(Dictionary(uniqueKeysWithValues: second.results.map { ($0.key, $0.status) }) == Dictionary(uniqueKeysWithValues: first.results.map { ($0.key, $0.status) }))

        // The quality gate fails on the survivors.
        options.failOnSurvived = true
        #expect(try await runMutation(options) == 2)
    }

    @Test func mutantsThatDoNotCompileAreLeftOut() async throws {
        let root = try examplePackage()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("Sources/Pricing/Joins.swift")
        // `[Int] - [Int]` and `String - String` do not type-check.
        try "public func merged(_ a: [Int], _ b: [Int]) -> [Int] { a + b }\npublic func greeting(_ name: String, _ suffix: String) -> String { name + suffix }\n".write(to: file, atomically: true, encoding: .utf8)
        var options = Options()
        options.root = root.path
        options.concurrency = 4

        #expect(try await runMutation(options) == 0)
        let compileErrors = try snapshot(root).results.filter { $0.status == .compileError }
        #expect(compileErrors.count == 2)
        #expect(compileErrors.allSatisfy { $0.file == "Sources/Pricing/Joins.swift" })
    }

    @Test func instrumentedSourcesTypeCheck() async throws {
        let source = """
        import Foundation
        public enum Level: String { case low = "l", high = "h" }
        public struct Box: Sendable {
            public var items: [Int] = [1, 2]
            public var table: [String: Int] = ["a": 1]
            public init(items: [Int]) { self.items = items; if items.count > 3 { self.items.removeAll() } }
            public var isEmpty: Bool { items.count == 0 }
            public var count: Int { get { items.count + 0 } set { items = Array(repeating: 0, count: newValue) } }
            public func total() -> Int { items.map { $0 * 2 }.reduce(0, +) }
            public mutating func add(_ x: Int) { items.append(x); if x < 0, items.count > 2 { items.removeAll() } else if x == 0 { print("zero") } }
            public func label(_ level: Level?) -> String { guard let level else { return "none" }; switch level { case .low: return "l" + "!"; case .high: return level.rawValue.uppercased() } }
            public func find(_ s: String?) -> Int? { s?.utf8.count }
            public func either(_ a: Int?, _ b: Int) -> Int { a ?? b }
            public func flag(_ a: Bool) -> Bool { !a && -items.count < 0 }
            public func pick(_ c: Bool) -> Int { if c { 1 } else { 2 } }
            public func risky(_ x: Int) throws -> Int { if x > 10 { throw CocoaError(.fileNoSuchFile) }; return x * 3 }
            public func work() async throws -> Int { try await Task.sleep(nanoseconds: 1); return try risky(1) + 1 }
            public func loop(_ n: Int) -> Int { var i = 0; var sum = 0; while i < n { sum += i; i += 1 }; repeat { sum -= 1 } while sum > 100; for x in items where x > 1 { sum += x }; return sum }
            public func text(_ s: String) -> Bool { s.hasPrefix("a") && s.lowercased() == "abc" && (try? Regex("^[a-z]+$").wholeMatch(in: s)) != nil }
            public func best() -> Int { max(items.min() ?? 0, 1) }
            public func every() -> Bool { items.allSatisfy { $0 > 0 } }
            @inlinable public func inlined(_ a: Int) -> Int { a + 1 }
        }
        public let globalTable = [1, 2, 3].map { $0 + 1 }
        """
        let analysis = analyze(file: "Box.swift", source: source)
        let emission = emit(Array(source.utf8), analysis)
        #expect(emission.keys.count > 60)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("swift-mutator-tc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try emission.code.write(to: dir.appendingPathComponent("Box.swift"), atomically: true, encoding: .utf8)
        let result = try await runProcess("swiftc", ["-swift-version", "6", "-parse-as-library", "-typecheck", "Box.swift"], cwd: dir)
        #expect(result.status == 0, "\(result.output)")
    }
}
