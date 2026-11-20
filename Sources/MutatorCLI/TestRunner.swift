import Foundation
import MutatorCore

// Runs tests by launching the built test bundles directly (not `swift test`, which holds a lock
// on `.build` and so cannot run in parallel): XCTest through `xctest`, swift-testing through
// SwiftPM's testing helper, with its event stream telling which tests failed.

struct TestBundle: Sendable {
    let name: String
    /// The `.xctest` path.
    let path: String
    /// The binary inside it (macOS), or the bundle itself (Linux).
    let executable: String
}

struct Toolchain: Sendable {
    /// macOS: `xctest`; nil on Linux, where the bundle is executable.
    let xctest: String?
    /// macOS: `swiftpm-testing-helper`.
    let testingHelper: String?
    /// Variables the test processes need (frameworks of the platform on macOS).
    let environment: [String: String]
}

enum TestOutcome: Sendable {
    case passed
    /// Failing tests; empty when the run failed without naming one.
    case failed([String], output: String)
    case timedOut
}

struct TestRun: Sendable {
    let outcome: TestOutcome
    let durationMs: Int
}

func discoverToolchain(cwd: URL) async throws -> Toolchain {
    #if os(macOS)
    let find: @Sendable (String) async throws -> String = { tool in
        try await runProcess("xcrun", ["--find", tool], cwd: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    async let xctestPath = find("xctest")
    async let xcodeSwift = find("swift")
    async let platformPath = runProcess("xcrun", ["--show-sdk-platform-path"], cwd: cwd)
    // The `swift` on PATH may be a toolchain (swiftly) or the /usr/bin shim for Xcode's.
    let onPath = try await runProcess("which", ["swift"], cwd: cwd).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let xctest = try await xctestPath
    let candidates = [onPath, try await xcodeSwift].filter { !$0.isEmpty }.map { swift in
        URL(fileURLWithPath: swift).resolvingSymlinksInPath().deletingLastPathComponent()
            .appendingPathComponent("../libexec/swift/pm/swiftpm-testing-helper").standardizedFileURL.path
    }
    let helper = candidates.first { FileManager.default.fileExists(atPath: $0) }
    let platform = try await platformPath.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    return Toolchain(
        xctest: xctest.isEmpty ? nil : xctest,
        testingHelper: helper,
        environment: [
            "DYLD_FRAMEWORK_PATH": platform + "/Developer/Library/Frameworks",
            "DYLD_LIBRARY_PATH": platform + "/Developer/usr/lib",
        ]
    )
    #else
    return Toolchain(xctest: nil, testingHelper: nil, environment: [:])
    #endif
}

func discoverBundles(binPath: String) throws -> [TestBundle] {
    let entries = try FileManager.default.contentsOfDirectory(atPath: binPath).filter { $0.hasSuffix(".xctest") }.sorted()
    return entries.map { entry in
        let name = String(entry.dropLast(".xctest".count))
        let path = binPath + "/" + entry
        let macBinary = path + "/Contents/MacOS/" + name
        return TestBundle(name: name, path: path, executable: FileManager.default.fileExists(atPath: macBinary) ? macBinary : path)
    }
}

/// The bundle holding the tests: the native build system builds one for the whole package.
private func bundle(for module: String, in bundles: [TestBundle]) -> TestBundle? {
    bundles.count == 1 ? bundles[0] : bundles.first { $0.name.hasSuffix("PackageTests") }
}

/// The environment of a test process: ours without mutator variables, plus `extra`.
func testEnvironment(_ extra: [String: String]) -> [String: String] {
    var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("SWIFT_MUTATOR_") }
    env.merge(extra) { _, new in new }
    // Crashing mutants are common; the runtime backtracer would make each crash slow.
    env["SWIFT_BACKTRACE"] = "enable=no"
    return env
}

struct TestRunner: Sendable {
    let sandbox: URL
    let bundles: [TestBundle]
    let toolchain: Toolchain
    let baseEnvironment: [String: String]

    init(sandbox: URL, bundles: [TestBundle], toolchain: Toolchain) {
        self.sandbox = sandbox
        self.bundles = bundles
        self.toolchain = toolchain
        baseEnvironment = testEnvironment(toolchain.environment)
    }

    /// Runs `ids` in order of first appearance per bundle and library; stops at the first failing group.
    /// Side effect: a home directory of its own for the run, removed afterwards. Tests run in
    /// parallel processes (a `.serialized` suite included), so files they keep in the home
    /// (Application Support, caches, preferences) would race, and a mutant would leave them behind.
    /// `TMPDIR` points into it too, but on macOS Foundation's temporary directory ignores it
    /// (`confstr(_CS_DARWIN_USER_TEMP_DIR)`): what tests put there stays in the user's.
    func run(_ ids: [String], environment: [String: String], timeoutMs: Int?) async -> TestRun {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("swift-mutator-home-\(UUID().uuidString)")
        let tmp = home.appendingPathComponent("tmp")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: home) }
        let isolated = ["HOME": home.path, "CFFIXED_USER_HOME": home.path, "TMPDIR": tmp.path + "/"]
        let env = baseEnvironment.merging(environment) { _, new in new }.merging(isolated) { _, new in new }
        var groups: [(bundle: TestBundle, swiftTesting: Bool, ids: [String])] = []
        for id in ids {
            guard let target = bundle(for: testModule(id), in: bundles) else { continue }
            let swiftTesting = isSwiftTestingId(id)
            if let i = groups.firstIndex(where: { $0.bundle.path == target.path && $0.swiftTesting == swiftTesting }) {
                groups[i].ids.append(id)
            } else {
                groups.append((target, swiftTesting, [id]))
            }
        }
        var total = 0
        for group in groups {
            let remaining = timeoutMs.map { max($0 - total, 1) }
            let (result, failed) = await runGroup(group.bundle, swiftTesting: group.swiftTesting, ids: group.ids, environment: env, timeoutMs: remaining)
            total += result?.durationMs ?? 0
            guard let result else { return TestRun(outcome: .failed([], output: "could not launch the tests of \(group.bundle.name)"), durationMs: total) }
            if result.timedOut { return TestRun(outcome: .timedOut, durationMs: total) }
            // Only the tail is kept: it is shown for a failing dry run, and killed mutants are many.
            if result.status != 0 { return TestRun(outcome: .failed(failed(), output: String(result.output.suffix(4000))), durationMs: total) }
        }
        return TestRun(outcome: .passed, durationMs: total)
    }

    /// The process result, and a parse of the failing tests (to call only when it failed).
    private func runGroup(_ bundle: TestBundle, swiftTesting: Bool, ids: [String], environment: [String: String], timeoutMs: Int?) async -> (ProcessResult?, () -> [String]) {
        if swiftTesting {
            let events = FileManager.default.temporaryDirectory.appendingPathComponent("swift-mutator-events-\(UUID().uuidString).jsonl")
            defer { try? FileManager.default.removeItem(at: events) }
            let filters = ids.flatMap { ["--filter", swiftTestingFilter($0)] }
            let tail = ["--testing-library", "swift-testing"] + filters + ["--event-stream-output-path", events.path, "--event-stream-version", "0"]
            let command: (String, [String]) = if let helper = toolchain.testingHelper {
                (helper, ["--test-bundle-path", bundle.executable] + tail)
            } else {
                (bundle.executable, tail)
            }
            let result = try? await runProcess(command.0, command.1, cwd: sandbox, environment: environment, timeoutMs: timeoutMs, merge: true)
            let stream = result?.status == 0 ? "" : (try? String(contentsOf: events, encoding: .utf8)) ?? ""
            return (result, { failedSwiftTestingTests(eventStream: stream, requested: ids) })
        }
        let filter = ids.joined(separator: ",")
        let command: (String, [String]) = if let xctest = toolchain.xctest {
            (xctest, ["-XCTest", filter, bundle.path])
        } else {
            (bundle.executable, [filter])
        }
        let result = try? await runProcess(command.0, command.1, cwd: sandbox, environment: environment, timeoutMs: timeoutMs, merge: true)
        return (result, { failedXCTests(output: result?.output ?? "", requested: ids) })
    }
}
