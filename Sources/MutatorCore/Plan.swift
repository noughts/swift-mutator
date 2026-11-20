// Planner: decides per mutant whether to reuse a cached result, skip, or run (and with which tests).

public enum PlanEntry: Sendable {
    /// `mutant.ignored` says why.
    case ignored(Mutant)
    case reuse(Mutant, MutantResult)
    case noCoverage(Mutant)
    /// `tests` are ordered: likely killers first.
    case run(Mutant, tests: [String], timeoutMs: Int)

    public var mutant: Mutant {
        switch self {
        case let .ignored(m), let .reuse(m, _), let .noCoverage(m), let .run(m, _, _): m
        }
    }
}

public struct PlanInput: Sendable {
    /// Mutants of the current source, including ignored ones.
    public let mutants: [Mutant]
    /// Tests known in the current run.
    public let tests: [TestInfo]
    /// Current coverage: mutant key -> covering test ids.
    public let coverage: [String: [String]]
    /// A snapshot already validated for tool version and environment.
    public let previous: Snapshot?
    public let timeoutFactor: Double
    public let timeoutMs: Int

    public init(mutants: [Mutant], tests: [TestInfo], coverage: [String: [String]], previous: Snapshot?, timeoutFactor: Double = 1.5, timeoutMs: Int = 5000) {
        self.mutants = mutants
        self.tests = tests
        self.coverage = coverage
        self.previous = previous
        self.timeoutFactor = timeoutFactor
        self.timeoutMs = timeoutMs
    }
}

/// Tests that are new, removed, or whose fingerprint changed.
func changedTests(_ previous: Snapshot, _ tests: [TestInfo]) -> Set<String> {
    let before = Dictionary(previous.tests.map { ($0.id, $0.fingerprint) }, uniquingKeysWith: { first, _ in first })
    let now = Set(tests.map(\.id))
    var changed = Set(tests.filter { before[$0.id] != $0.fingerprint }.map(\.id))
    for id in before.keys where !now.contains(id) { changed.insert(id) }
    return changed
}

/// Tests that previously covered a scope whose hash changed or that disappeared.
private func testsOfChangedScopes(_ previous: Snapshot, _ mutants: [Mutant]) -> Set<String> {
    let current = Dictionary(mutants.map { ($0.scope.key(file: $0.file), $0.scope.hash) }, uniquingKeysWith: { first, _ in first })
    return Set(previous.results.filter { current[$0.scopeKey] != $0.scopeHash }.flatMap(\.coveredBy))
}

/// Mutants that did not compile before, in a function unchanged since: left out of the build
/// from the start instead of being found again, a build round each. `recorded` (key -> scope
/// hash) holds those found by runs that ended before writing a snapshot.
public func knownCompileErrors(previous: Snapshot?, recorded: [String: String] = [:], mutants: [Mutant]) -> Set<String> {
    let hashes = Dictionary(mutants.map { ($0.key, $0.scope.hash) }, uniquingKeysWith: { first, _ in first })
    let found = (previous?.results ?? []).filter { $0.status == .compileError }.map { ($0.key, $0.scopeHash) } + recorded.map { ($0.key, $0.value) }
    return Set(found.filter { hashes[$0.0] == $0.1 }.map(\.0))
}

public func plan(_ input: PlanInput) -> [PlanEntry] {
    let previous = input.previous
    let testById = Dictionary(input.tests.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let prevByKey = Dictionary((previous?.results ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    // A test that ran changed code, or changed itself, affects a mutant it covers.
    let affected = previous.map { changedTests($0, input.tests).union(testsOfChangedScopes($0, input.mutants)) } ?? []
    let affects = affected.contains

    // scope -> test -> number of mutants it killed there (for sibling-killer ordering)
    var killsByScope: [String: [String: Int]] = [:]
    for r in previous?.results ?? [] where r.status == .killed {
        for t in r.killedBy { killsByScope[r.scopeKey, default: [:]][t, default: 0] += 1 }
    }

    // Every covering test is unaffected and none is new: running again would give the same outcome.
    let sameTests = { (m: Mutant, prev: MutantResult) -> Bool in
        if prev.coveredBy.contains(where: affects) { return false }
        if prev.status == .timeout { return true }
        let now = input.coverage[m.key] ?? []
        if prev.status == .noCoverage, !now.isEmpty { return false }
        let before = Set(prev.coveredBy)
        return now.allSatisfy(before.contains)
    }

    let canReuse = { (m: Mutant, prev: MutantResult) -> Bool in
        guard prev.scopeHash == m.scope.hash, prev.file == m.file else { return false }
        switch prev.status {
        case .killed: return prev.killedBy.contains { testById[$0] != nil && !affects($0) }
        case .ignored, .pending, .compileError: return false
        case .survived, .noCoverage, .timeout: return sameTests(m, prev)
        }
    }

    let order = { (m: Mutant, prev: MutantResult?, selected: [String]) -> [String] in
        let killers = Dictionary((prev?.killedBy ?? []).enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
        let siblings = killsByScope[m.scope.key(file: m.file)] ?? [:]
        // Previous killers of this mutant count towards siblings too; subtract them out.
        let own = Set(prev?.status == .killed ? prev!.killedBy : [])
        let siblingKills = { (t: String) in (siblings[t] ?? 0) - (own.contains(t) ? 1 : 0) }
        let duration = { (t: String) in testById[t].map { Double($0.durationMs) } ?? .infinity }
        let rank = { (t: String) -> (Double, Double, Double) in
            if let k = killers[t] { return (0, Double(k), 0) }
            let s = siblingKills(t)
            return s > 0 ? (1, Double(-s), duration(t)) : (2, duration(t), 0)
        }
        // Ranked once per test, not per comparison.
        return selected.map { (rank: rank($0), id: $0) }.sorted { $0.rank != $1.rank ? $0.rank < $1.rank : $0.id < $1.id }.map(\.id)
    }

    return input.mutants.map { m in
        if m.ignored != nil { return .ignored(m) }
        let prev = prevByKey[m.key]
        if let prev, canReuse(m, prev) { return .reuse(m, prev) }
        var seen = Set<String>()
        // A covering test with no known duration is kept, and runs last.
        let selected = (input.coverage[m.key] ?? []).filter { seen.insert($0).inserted }
        if selected.isEmpty { return .noCoverage(m) }
        let ordered = order(m, prev, selected)
        let total = ordered.reduce(0) { $0 + (testById[$1]?.durationMs ?? 0) }
        return .run(m, tests: ordered, timeoutMs: Int((Double(total) * input.timeoutFactor).rounded()) + input.timeoutMs)
    }
}

public struct Job: Sendable {
    public let mutant: Mutant
    /// Ordered: likely killers first.
    public let tests: [String]
    public let timeoutMs: Int
}

/// Report entries for the mutants decided without running, and the mutants to run, cheapest
/// first. With a focus (`--since`), a mutant outside it that needs a run is left Pending.
public func triage(_ entries: [PlanEntry], compileErrors: [Mutant], coverage: [String: [String]], focus: [String: Focus]?) -> (decided: [ReportEntry], jobs: [Job]) {
    var decided = compileErrors.map { ReportEntry(mutant: $0, status: .compileError, source: .decided) }
    var jobs: [Job] = []
    for entry in entries {
        switch entry {
        case let .ignored(m):
            decided.append(ReportEntry(mutant: m, status: .ignored, source: .decided))
        case let .reuse(m, result):
            decided.append(ReportEntry(mutant: m, status: result.status, source: .reuse, killedBy: result.killedBy, coveredBy: coverage[m.key] ?? result.coveredBy))
        case let .noCoverage(m):
            decided.append(ReportEntry(mutant: m, status: .noCoverage, source: .decided))
        case let .run(m, tests, timeoutMs):
            if let focus, focus[m.key] == nil {
                decided.append(ReportEntry(mutant: m, status: .pending, source: .decided, coveredBy: tests))
            } else {
                jobs.append(Job(mutant: m, tests: tests, timeoutMs: timeoutMs))
            }
        }
    }
    // The timeout grows with the covering tests' time: cheapest first.
    jobs.sort { $0.timeoutMs != $1.timeoutMs ? $0.timeoutMs < $1.timeoutMs : $0.mutant.key < $1.mutant.key }
    return (decided, jobs)
}
