import Foundation
import MutatorCore

// Orchestration: analyze -> build the sandbox (dropping mutants that do not compile) ->
// dry run (per-test coverage) -> plan (reuse the snapshot) -> run mutants -> snapshot, reports.

private struct SourceFile {
    let path: String
    let text: String
    let bytes: [UInt8]
    let analysis: Analysis
}

func runMutation(_ options: Options) async throws -> Int32 {
    let started = Date()
    let root = URL(fileURLWithPath: options.root).standardizedFileURL.resolvingSymlinksInPath()
    let mutatorDir = root.appendingPathComponent(".mutator")
    let sandbox = mutatorDir.appendingPathComponent("sandbox")
    let snapshotURL = mutatorDir.appendingPathComponent("snapshot.json")
    let fm = FileManager.default
    guard fm.fileExists(atPath: root.appendingPathComponent("Package.swift").path) else {
        throw CLIError("no Package.swift in \(root.path)")
    }

    // 1. Sources and mutants (files analyzed in parallel: `analyze` is pure).
    async let described = describePackage(root)
    async let environment = environmentHash(root: root, options: options)
    let package = try await described
    let files = package.codeTargets.flatMap(\.swiftSources).filter { path in
        (options.include.isEmpty || options.include.contains { globMatches($0, path) }) && !options.exclude.contains { globMatches($0, path) }
    }.sorted()
    let texts = try files.map { try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8) }
    let analyzeOptions = options.analyzeOptions
    let sources = await concurrentMap(Array(zip(files, texts)), limit: ProcessInfo.processInfo.activeProcessorCount) { path, text in
        SourceFile(path: path, text: text, bytes: Array(text.utf8), analysis: analyze(file: path, source: text, options: analyzeOptions))
    }
    for file in sources where file.analysis.parseError { log("warning: \(file.path) does not parse; not mutated") }
    let mutants = sources.flatMap(\.analysis.mutants)
    if options.list {
        for m in mutants { print(formatMutant(m) + (m.ignored.map { "  (ignored: \($0))" } ?? "")) }
        log("\(mutants.count) mutants in \(files.count) files")
        return 0
    }
    log("\(mutants.count) mutants in \(files.count) files (\(mutants.filter { $0.ignored == nil }.count) to place)")

    // 2. The snapshot is reusable only under the same environment.
    let envHash = try await environment
    let previous = readSnapshot(snapshotURL)?.valid(toolVersion: toolVersion, envHash: envHash)

    // 3. Build with every mutant switched in; drop the ones that do not compile, rebuild. Every
    //    source is compiled at its original path (`atOriginalPath`), and each round's findings are
    //    recorded at once, so a run that stops later does not find them again.
    let recordURL = mutatorDir.appendingPathComponent("compile-errors.json")
    let record = readJSON(CompileErrorRecord.self, from: recordURL).flatMap { $0.envHash == envHash ? $0.scopeHashes : nil }
    var excluded = knownCompileErrors(recorded: record ?? [:], mutants: mutants)
    let atOriginal = { (path: String, code: String) in atOriginalPath(code, path: root.appendingPathComponent(path).path) }
    let plain = try Dictionary(uniqueKeysWithValues: Set(package.targets.flatMap(\.swiftSources)).subtracting(files).map {
        ($0, atOriginal($0, try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)))
    })
    let manifests = try fm.contentsOfDirectory(atPath: root.path).filter { $0 == "Package.swift" || ($0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift")) }
    var instrumented: [String: InstrumentedFile] = [:]
    var rounds = 0
    while true {
        rounds += 1
        instrumented = Dictionary(uniqueKeysWithValues: sources.map { ($0.path, InstrumentedFile(analysis: $0.analysis, emission: emit($0.bytes, $0.analysis, excluding: excluded))) })
        var overrides = plain
        for (path, file) in instrumented { overrides[path] = atOriginal(path, file.emission.code) }
        for manifest in manifests {
            let text = try String(contentsOf: root.appendingPathComponent(manifest), encoding: .utf8)
            overrides[manifest] = absolutizeLocalDependencies(manifest: text, packageRoot: root.path)
        }
        try syncSandbox(root: root, sandbox: sandbox, overrides: overrides)
        let placed = instrumented.values.reduce(0) { $0 + $1.emission.keys.count }
        log("build round \(rounds): \(placed) mutants switched in")
        let build = try await swift(["build", "--build-tests"], in: sandbox, merge: true)
        if build.status == 0 { break }
        let errors = parseCompilerErrors(build.stdout).map { error in
            CompilerError(path: sandboxRelative(error.path, sandbox: sandbox, root: root) ?? error.path, line: error.line, column: error.column, message: error.message)
        }
        let culprits = blame(errors, files: instrumented)
        let fresh = culprits.keys.subtracting(excluded)
        if fresh.isEmpty || rounds >= options.maxBuildRounds {
            let shown = (culprits.unattributed.isEmpty ? errors : culprits.unattributed).prefix(20).map { "  \($0.path):\($0.line):\($0.column): \($0.message)" }
            let detail = shown.isEmpty ? String(stripEscapes(build.stdout).suffix(4000)) : shown.joined(separator: "\n")
            throw CLIError("the package does not build in the sandbox (\(sandbox.path)):\n\(detail)", exitCode: 4)
        }
        excluded.formUnion(fresh)
        let scopeHashes = Dictionary(mutants.filter { excluded.contains($0.key) }.map { ($0.key, $0.scope.hash) }, uniquingKeysWith: { first, _ in first })
        try writeJSON(CompileErrorRecord(envHash: envHash, scopeHashes: scopeHashes), to: recordURL)
        log("  \(fresh.count) mutants do not compile; rebuilding without them")
    }

    // 4. Tests and their fingerprints.
    let toolchain = try await discoverToolchain(cwd: sandbox)
    let binPath = try await swift(["build", "--show-bin-path"], in: sandbox).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    let runner = TestRunner(sandbox: sandbox, bundles: try discoverBundles(binPath: binPath), toolchain: toolchain)
    let listed = try await swift(["test", "list", "--skip-build"], in: sandbox)
    guard listed.status == 0 else { throw CLIError("swift test list failed:\n\(listed.output)") }
    let testIds = parseTestList(listed.stdout)
    let testModules = try testSources(root: root, package: package)
    let fingerprints = testFingerprints(ids: testIds, modules: testModules, extra: try testResources(root: root, package: package))

    // 5. Dry run: per-test coverage, only for the tests whose coverage may have changed.
    let allScopes = sources.flatMap { file in file.analysis.scopes.map { (key: $0.key(file: file.path), scope: $0) } }
    let scopeHashes = Dictionary(allScopes.map { ($0.key, $0.scope.hash) }, uniquingKeysWith: { first, _ in first })
    let declarationScopes = Set(allScopes.filter { !$0.scope.isFunction }.map(\.key))
    let extensions = Set(allScopes.filter { $0.scope.kind == .extension }.map(\.key))
    let previousDurations = Dictionary((previous?.tests ?? []).map { ($0.id, $0.durationMs) }, uniquingKeysWith: { first, _ in first })
    let provisional = testIds.map { TestInfo(id: $0, fingerprint: fingerprints[$0] ?? "", durationMs: previousDurations[$0] ?? 0) }
    let toMeasure = testsToMeasure(previous: previous, tests: provisional, scopes: scopeHashes, extensions: extensions, full: options.fullDryRun)
    let measureIds = testIds.filter(toMeasure.contains)
    log("dry run: \(measureIds.count)/\(testIds.count) tests")
    let coverageDir = mutatorDir.appendingPathComponent("coverage")
    try? fm.removeItem(at: coverageDir)
    try fm.createDirectory(at: coverageDir, withIntermediateDirectories: true)
    let dry = await concurrentMap(Array(measureIds.enumerated()), limit: options.concurrency) { index, id in
        let file = coverageDir.appendingPathComponent("\(index).txt")
        let run = await runner.run([id], environment: [coverageEnvironment: file.path], timeoutMs: nil)
        let keys = ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
        return (id: id, run: run, keys: Array(Set(keys)).sorted())
    }
    try? fm.removeItem(at: coverageDir)
    let failing = dry.filter { if case .passed = $0.run.outcome { false } else { true } }
    if !failing.isEmpty {
        let details = failing.prefix(5).map { entry -> String in
            if case let .failed(_, _, output) = entry.run.outcome { return "  \(entry.id):\n" + output.split(separator: "\n").suffix(15).map { "    " + $0 }.joined(separator: "\n") }
            return "  \(entry.id): timed out"
        }
        throw CLIError("\(failing.count) test(s) fail without mutants:\n" + details.joined(separator: "\n"), exitCode: 4)
    }
    let measuredDurations = Dictionary(dry.map { ($0.id, $0.run.durationMs) }, uniquingKeysWith: { first, _ in first })
    let tests = testIds.map { TestInfo(id: $0, fingerprint: fingerprints[$0] ?? "", durationMs: measuredDurations[$0] ?? previousDurations[$0] ?? 0) }
    let liveKeys = Set(instrumented.values.flatMap(\.emission.keys))
    let coverageByTest = mergeCoverage(previous: previous, measured: Dictionary(dry.map { ($0.id, $0.keys) }, uniquingKeysWith: { first, _ in first }), tests: testIds, keys: liveKeys)
    let coverage = coverageByMutant(coverageByTest)
    if !testIds.isEmpty, coverage.isEmpty, !liveKeys.isEmpty { log("warning: tests ran but reached no mutant; check --include") }

    // 6. Plan, and with --since the focus.
    let entries = plan(PlanInput(mutants: mutants.filter { !excluded.contains($0.key) }, tests: tests, coverage: coverage, previous: previous, timeoutFactor: options.timeoutFactor, timeoutMs: options.timeoutMs, killMatrix: options.killMatrix))
    var focus: [String: Focus]?
    if let since = options.since {
        let changes = try await gitChanges(root, since: since)
        let spans = changedSpans(lines: changes.lines, newFiles: changes.newFiles, sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0.bytes) }))
        let touched = Set(selectMutants(mutants, changed: spans, mode: options.scope).map(\.key))
        focus = sinceFocus(touched: touched, previous: previous?.results ?? [], tests: tests)
    }

    // 7. Execute.
    let (decided, jobs) = triage(entries, compileErrors: mutants.filter { excluded.contains($0.key) }, coverage: coverage, focus: focus)
    log("\(mutants.count) mutants: \(jobs.count) to run, \(decided.filter { $0.source == .reuse }.count) reused, \(excluded.count) do not compile")
    let progress = Progress(total: jobs.count)
    let outcomes = await concurrentMap(jobs, limit: options.concurrency) { job in
        let run = await runner.run(job.tests, environment: [activeEnvironment: job.mutant.key], timeoutMs: job.timeoutMs, exhaustive: options.killMatrix)
        progress.tick()
        return run
    }
    var report = Dictionary(decided.map { ($0.mutant.key, $0) }, uniquingKeysWith: { first, _ in first })
    for (job, run) in zip(jobs, outcomes) {
        let (status, killedBy, complete): (MutantStatus, [String], Bool) = switch run.outcome {
        case .passed: (.survived, [], true)
        case let .failed(failed, complete, _): (.killed, failed, complete)
        case .timedOut: (.timeout, [], false)
        }
        report[job.mutant.key] = ReportEntry(mutant: job.mutant, status: status, source: .run, killedBy: killedBy, coveredBy: job.tests, incomplete: !complete)
    }

    // 8. Snapshot: every verdict, so the next run can reuse it.
    let ordered = mutants.compactMap { report[$0.key] }.map { entry -> ReportEntry in
        var entry = entry
        entry.focus = focus?[entry.mutant.key]
        return entry
    }
    let durationsByKey = Dictionary(zip(jobs, outcomes).map { ($0.0.mutant.key, $0.1.durationMs) }, uniquingKeysWith: { first, _ in first })
    let results = ordered.filter { $0.status != .ignored }.map { e in
        MutantResult(mutant: e.mutant, status: e.status, killedBy: e.killedBy, coveredBy: e.coveredBy, durationMs: durationsByKey[e.mutant.key], incomplete: e.incomplete)
    }
    let snapshot = Snapshot(toolVersion: toolVersion, envHash: envHash, results: results, tests: tests, coverage: coverageByTest, scopes: scopeHashes, declarationScopes: declarationScopes.sorted())
    try writeJSON(snapshot, to: snapshotURL)

    // 9. Reports and the quality gate.
    let thresholds = Thresholds(breakAt: options.thresholdBreak)
    let diffOnly = focus != nil
    // Test locations take a parse of every test file: only for the reports that show them.
    let catalog = options.killMatrix || options.reporters.contains("json") || options.reporters.contains("html") ? TestCatalog(
        ids: testIds,
        locations: testLocations(ids: testIds, modules: testModules),
        sources: Dictionary(testModules.values.flatMap { $0.map { ($0.path, $0.text) } }, uniquingKeysWith: { first, _ in first })
    ) : TestCatalog()
    let matrix = options.killMatrix ? killMatrix(ordered, tests: testIds, fileOf: catalog.locations.mapValues(\.file)) : nil
    let facts = RunFacts(durationMs: Int(Date().timeIntervalSince(started) * 1000), files: files.count, measuredTests: measureIds.count, totalTests: testIds.count, buildRounds: rounds, diffOnly: diffOnly)
    if options.reporters.contains("text") { print(formatSummary(ordered, facts: facts, thresholds: thresholds, killMatrix: matrix, tests: catalog)) }
    if options.reporters.contains("json") || options.reporters.contains("html") {
        let dir = options.reportDir.map { URL(fileURLWithPath: $0, relativeTo: root) } ?? mutatorDir.appendingPathComponent("report")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let mte = mutationTestingReport(ordered, sources: Dictionary(uniqueKeysWithValues: sources.map { ($0.path, $0.text) }), projectRoot: root.path, version: toolVersion, thresholds: thresholds, diffOnly: diffOnly, tests: catalog, killMatrix: matrix)
        if options.reporters.contains("json") { try encodeReport(mte).write(to: dir.appendingPathComponent("mutation.json"), atomically: true, encoding: .utf8) }
        if options.reporters.contains("html") { try htmlReport(mte).write(to: dir.appendingPathComponent("index.html"), atomically: true, encoding: .utf8) }
        log("reports written to \(dir.path)")
    }
    let failures = gateFailures(ordered, diffOnly: diffOnly, thresholds: thresholds, failOnSurvived: options.failOnSurvived)
    for failure in failures { log("quality gate: \(failure)") }
    return failures.isEmpty ? 0 : 2
}

/// `swift <arguments>` in the sandbox, built with the native build system: once a compile fails,
/// Swift Build (the default of recent toolchains) starts no other, so a round would find only the
/// errors of the first few files to fail; the native one reports every file's. Every command on
/// the sandbox goes through here so that all of them see the same build products.
private func swift(_ arguments: [String], in sandbox: URL, merge: Bool = false) async throws -> ProcessResult {
    try await runProcess("swift", arguments + ["--build-system", "native"], cwd: sandbox, merge: merge)
}

/// Mutants found not to compile, written after each build round: the next run leaves them out
/// from the start, also when this one stops before its snapshot.
private struct CompileErrorRecord: Codable {
    let envHash: String
    /// Mutant key -> hash of its scope when it did not compile.
    let scopeHashes: [String: String]
}

private final class Progress: @unchecked Sendable {
    private let lock = NSLock()
    private var done = 0
    private var reported = 0
    private let total: Int

    init(total: Int) { self.total = total }

    func tick() {
        lock.withLock {
            done += 1
            let step = max(1, total / 10)
            if done == total || done - reported >= step {
                reported = done
                log("mutants: \(done)/\(total)")
            }
        }
    }
}

/// Test module -> its Swift sources (for fingerprints).
private func testSources(root: URL, package: PackageDescription) throws -> [String: [TestSource]] {
    var out: [String: [TestSource]] = [:]
    for target in package.testTargets {
        out[target.module] = try target.swiftSources.map { TestSource(path: $0, text: try String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) }
    }
    return out
}

/// Test module -> hash of its non-Swift files (fixtures, resources).
private func testResources(root: URL, package: PackageDescription) throws -> [String: String] {
    var out: [String: String] = [:]
    for target in package.testTargets {
        let dir = root.appendingPathComponent(target.path)
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isRegularFileKey]) else { continue }
        var parts: [String] = []
        for case let url as URL in enumerator where url.pathExtension != "swift" {
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true, let data = try? Data(contentsOf: url) else { continue }
            parts.append(url.path.replacingOccurrences(of: dir.path, with: "") + "\0" + stableHash(String(decoding: data, as: UTF8.self)))
        }
        out[target.module] = parts.sorted().joined(separator: "\0")
    }
    return out
}

/// Compiler, manifest, resolved dependencies and mutation options: a change invalidates the snapshot.
private func environmentHash(root: URL, options: Options) async throws -> String {
    let compiler = try await runProcess("swift", ["--version"], cwd: root).output
    var parts = [toolVersion, compiler, options.analyzeOptions.excludedMutators.map(\.rawValue).sorted().joined(separator: ","), (options.analyzeOptions.aridCallees ?? ["<none>"]).joined(separator: ",")]
    for name in ["Package.swift", "Package.resolved"] {
        parts.append((try? String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)) ?? "")
    }
    return stableHash(parts.joined(separator: "\0"))
}

func readSnapshot(_ url: URL) -> Snapshot? { readJSON(Snapshot.self, from: url) }

private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
}

private func writeJSON(_ value: some Encodable, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try encoder.encode(value).write(to: url, options: .atomic)
}
