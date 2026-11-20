// Diff-driven dry run: only tests whose coverage may have changed are measured again.

/// Tests whose coverage must be measured again; the others keep the coverage recorded in `previous`.
/// - Every test without a valid snapshot, with `full`, when a declaration-level scope (a type, an
///   extension, a global) changed or disappeared, or when an extension appeared: members and
///   conformances added or removed can change dispatch anywhere.
/// - Otherwise new and changed tests, and tests that covered a function whose hash changed or that
///   disappeared. A new function, type or global is reached only through an edited caller or test,
///   measured anyway.
public func testsToMeasure(previous: Snapshot?, tests: [TestInfo], scopes: [String: String], extensions: Set<String>, full: Bool) -> Set<String> {
    let all = Set(tests.map(\.id))
    guard let previous, !full else { return all }
    let before = Set(previous.declarationScopes)
    if before.contains(where: { previous.scopes[$0] != scopes[$0] }) || !extensions.isSubset(of: before) { return all }
    var out = changedTests(previous, tests).intersection(all)
    let changedScopes = Set(previous.scopes.filter { scopes[$0.key] != $0.value }.map(\.key))
    let scopeOf = Dictionary(previous.results.map { ($0.key, $0.scopeKey) }, uniquingKeysWith: { first, _ in first })
    for (test, keys) in previous.coverage where all.contains(test) && !out.contains(test) {
        if keys.contains(where: { scopeOf[$0].map(changedScopes.contains) ?? true }) { out.insert(test) }
    }
    return out
}

/// Coverage of every current test: freshly measured, or kept from `previous` (restricted to live mutants).
public func mergeCoverage(previous: Snapshot?, measured: [String: [String]], tests: [String], keys: Set<String>) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for test in tests {
        out[test] = (measured[test] ?? previous?.coverage[test] ?? []).filter(keys.contains)
    }
    return out
}

/// Test -> keys, inverted to key -> tests (tests in a stable order).
public func coverageByMutant(_ byTest: [String: [String]]) -> [String: [String]] {
    var out: [String: [String]] = [:]
    for test in byTest.keys.sorted() {
        for key in byTest[test]! { out[key, default: []].append(test) }
    }
    return out
}
