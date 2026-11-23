// Kill matrix analysis (--kill-matrix), as mizchi/mutator's: which tests detect nothing mutation
// can observe, and which add no detection power over another single test. Pure functions over
// report entries.

public struct KillMatrix: Codable, Equatable, Sendable {
    public struct Mutants: Codable, Equatable, Sendable {
        /// Mutants whose kill set is complete (the analysis is computed over these only).
        public let full: Int
        /// Covered mutants that timed out.
        public let timeout: Int
        /// Other covered mutants without a complete kill set (a crash stopped tests, or not run).
        public let incomplete: Int
    }

    public struct Subsumed: Codable, Equatable, Sendable {
        public let test: String
        public let kills: Int
        /// Tests killing a strict superset: those in the same file first, then the largest kill set.
        public let by: [String]
    }

    public struct Duplicate: Codable, Equatable, Sendable {
        public let tests: [String]
        public let kills: Int
    }

    public enum Status: String, Codable, Sendable {
        /// Kills at least one mutant.
        case detected
        /// Reaches mutants, all measured completely, and kills none.
        case noKills
        /// Reaches no viable mutant: its detection power is not measured.
        case notReached
        /// Kills nothing, but some of its measurements are incomplete.
        case incomplete
    }

    public struct Observation: Codable, Equatable, Sendable {
        public let test: String
        public let status: Status
        public let kills: Int
        public let measured: Int
        public let incomplete: Int
    }

    public let mutants: Mutants
    /// Collected tests.
    public let tests: Int
    /// Tests reaching mutants with a full matrix that kill none of them.
    public let noKills: [String]
    public let subsumed: [Subsumed]
    /// Groups of tests with the same (non-empty) kill set.
    public let duplicates: [Duplicate]
    /// Every collected test.
    public let observations: [Observation]
}

/// A survivor ran every covering test, so its empty kill set is complete. A kill is complete
/// when no crash stopped the tests after it.
func hasFullMatrix(_ entry: ReportEntry) -> Bool {
    entry.status == .survived || (entry.status == .killed && !entry.incomplete)
}

/// Mutants that tell something about the tests covering them.
private func isViable(_ status: MutantStatus) -> Bool { ![.compileError, .ignored, .noCoverage].contains(status) }

private func observe(_ entries: [ReportEntry], tests: [String]) -> [KillMatrix.Observation] {
    var measured: [String: Int] = [:]
    var incomplete: [String: Int] = [:]
    var kills: [String: Int] = [:]
    for entry in entries where isViable(entry.status) {
        let full = hasFullMatrix(entry)
        let killedBy = Set(entry.killedBy)
        for test in Set(entry.coveredBy).union(killedBy) {
            if full { measured[test, default: 0] += 1 } else { incomplete[test, default: 0] += 1 }
            if entry.status == .killed, killedBy.contains(test) { kills[test, default: 0] += 1 }
        }
    }
    return Set(tests).union(measured.keys).union(incomplete.keys).sorted().map { test in
        let (k, m, i) = (kills[test] ?? 0, measured[test] ?? 0, incomplete[test] ?? 0)
        let status: KillMatrix.Status = k > 0 ? .detected : i > 0 ? .incomplete : m > 0 ? .noKills : .notReached
        return KillMatrix.Observation(test: test, status: status, kills: k, measured: m, incomplete: i)
    }
}

/// `tests`: every collected test. `fileOf`: test id -> its source file, to prefer a subsuming test
/// of the same file (a broad test elsewhere is seldom a reason to delete one).
public func killMatrix(_ entries: [ReportEntry], tests: [String], fileOf: [String: String] = [:]) -> KillMatrix {
    let observations = observe(entries, tests: tests)
    var full = 0, timeout = 0, incomplete = 0
    /// test -> keys of the mutants it kills; mutant key -> its killers.
    var kills: [String: Set<String>] = [:]
    var killers: [String: [String]] = [:]
    for entry in entries {
        guard hasFullMatrix(entry) else {
            if entry.coveredBy.isEmpty, entry.killedBy.isEmpty { continue }
            if entry.status == .timeout { timeout += 1 } else if isViable(entry.status) { incomplete += 1 }
            continue
        }
        full += 1
        for test in entry.killedBy { kills[test, default: []].insert(entry.mutant.key) }
        killers[entry.mutant.key] = entry.killedBy
    }
    let noKills = observations.filter { $0.status == .noKills }.map(\.test)
    // An incomplete measurement cannot establish that one test's kill set includes another's.
    let measuredIncompletely = Set(observations.filter { $0.incomplete > 0 }.map(\.test))
    kills = kills.filter { !measuredIncompletely.contains($0.key) }

    var subsumed: [KillMatrix.Subsumed] = []
    for (test, own) in kills {
        // A test killing all of `own` is among the killers of its rarest mutant. The same size
        // means the same set: a duplicate, grouped below.
        let rarest = own.min { (killers[$0]?.count ?? 0, $0) < (killers[$1]?.count ?? 0, $1) }
        let by = (rarest.flatMap { killers[$0] } ?? []).filter { other in
            guard other != test, let theirs = kills[other], theirs.count > own.count else { return false }
            return theirs.isSuperset(of: own)
        }
        guard !by.isEmpty else { continue }
        let sameFile = { (other: String) in fileOf[other] != nil && fileOf[other] == fileOf[test] }
        let ordered = by.sorted { a, b in
            (sameFile(a) ? 0 : 1, -(kills[a]?.count ?? 0), a) < (sameFile(b) ? 0 : 1, -(kills[b]?.count ?? 0), b)
        }
        subsumed.append(KillMatrix.Subsumed(test: test, kills: own.count, by: ordered))
    }

    let groups = Dictionary(grouping: kills.keys, by: { kills[$0]!.sorted().joined(separator: "\0") })
    let duplicates = groups.values.filter { $0.count > 1 }.map { tests in
        KillMatrix.Duplicate(tests: tests.sorted(), kills: kills[tests[0]]!.count)
    }.sorted { $0.tests[0] < $1.tests[0] }

    return KillMatrix(
        mutants: KillMatrix.Mutants(full: full, timeout: timeout, incomplete: incomplete),
        tests: observations.count,
        noKills: noKills,
        subsumed: subsumed.sorted { $0.test < $1.test },
        duplicates: duplicates,
        observations: observations
    )
}
