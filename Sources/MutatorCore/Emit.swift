// Emission: wraps placed nodes in mutant switches (mutation switching). Pure text work on the
// original bytes; the runtime that answers `__mutator_on(i)` is appended to the file.

public struct PlacementPlan: Hashable, Sendable {
    public let span: Span
    public let kind: PlacementKind
    /// Block placements: offset of a lone implicitly returned expression, which needs `return`.
    public let implicitReturnAt: Int?
    /// Mutants switched here, in emission order.
    public let keys: [String]
}

public struct Emission: Sendable {
    public let code: String
    /// Keys of the placed mutants, in runtime index order.
    public let keys: [String]
    /// Output span of the mutated code of each placed mutant.
    public let mutantSpans: [String: Span]
    /// Output offset -> original offset, as (output start, source start, inserted) segments.
    let segments: [(output: Int, source: Int, inserted: Bool)]

    /// The original offset an output offset comes from (inserted text maps to its insertion point).
    public func sourceOffset(_ output: Int) -> Int {
        var lo = 0
        var hi = segments.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if segments[mid].output <= output { lo = mid } else { hi = mid - 1 }
        }
        guard lo < segments.count else { return 0 }
        let segment = segments[lo]
        return segment.inserted ? segment.source : segment.source + (output - segment.output)
    }
}

private struct Insert {
    let text: String
    /// (key, start, end) relative to `text`.
    var spans: [(String, Int, Int)] = []
}

public let activeEnvironment = "SWIFT_MUTATOR_ACTIVE"
public let coverageEnvironment = "SWIFT_MUTATOR_COVERAGE"

/// Instrumented source of a file: every placed mutant not in `excluded` behind a switch.
public func emit(_ bytes: [UInt8], _ analysis: Analysis, excluding excluded: Set<String> = []) -> Emission {
    let mutants = Dictionary(analysis.mutants.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
    let plans = analysis.placements
        .map { PlacementPlan(span: $0.span, kind: $0.kind, implicitReturnAt: $0.implicitReturnAt, keys: $0.keys.filter { !excluded.contains($0) }) }
        .filter { !$0.keys.isEmpty }
        .sorted { $0.span.start != $1.span.start ? $0.span.start < $1.span.start : $0.span.end > $1.span.end }
    let source = String(decoding: bytes, as: UTF8.self)
    guard !plans.isEmpty else {
        return Emission(code: source, keys: [], mutantSpans: [:], segments: [(0, 0, false)])
    }
    let keys = plans.flatMap(\.keys)
    let index = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })

    var right: [Int: [Insert]] = [:]
    var left: [Int: [Insert]] = [:]
    for plan in plans {
        let (prefix, suffix) = wrapper(bytes, plan, mutants: plan.keys.compactMap { mutants[$0] }, index: index)
        right[plan.span.start, default: []].append(prefix)
        if let at = plan.implicitReturnAt {
            right[at, default: []].append(Insert(text: "return "))
        }
        left[plan.span.end, default: []].insert(Insert(text: suffix), at: 0)
    }

    var out: [UInt8] = []
    out.reserveCapacity(bytes.count * 2)
    var segments: [(output: Int, source: Int, inserted: Bool)] = []
    var mutantSpans: [String: Span] = [:]
    var contentStart: Int?
    for i in 0 ... bytes.count {
        let inserts = (left[i] ?? []) + (right[i] ?? [])
        if !inserts.isEmpty { contentStart = nil }
        for insert in inserts {
            let at = out.count
            segments.append((at, i, true))
            for (key, start, end) in insert.spans { mutantSpans[key] = Span(start: at + start, end: at + end) }
            out.append(contentsOf: Array(insert.text.utf8))
        }
        guard i < bytes.count else { break }
        if contentStart == nil {
            contentStart = i
            segments.append((out.count, i, false))
        }
        out.append(bytes[i])
    }
    let code = String(decoding: out, as: UTF8.self) + runtime(keys: keys)
    return Emission(code: code, keys: keys, mutantSpans: mutantSpans, segments: segments)
}

private func wrapper(_ bytes: [UInt8], _ plan: PlacementPlan, mutants: [Mutant], index: [String: Int]) -> (Insert, String) {
    let span = plan.span
    let mutated = { (m: Mutant) -> String in
        var text = bytes.text(Span(start: span.start, end: m.span.start)) + m.replacement + bytes.text(Span(start: m.span.end, end: span.end))
        // A whole-body replacement (FnValue) brings its own `return`.
        if let at = plan.implicitReturnAt, m.span.start >= at {
            let utf8 = Array(text.utf8)
            let cut = at - span.start
            text = String(decoding: utf8[..<cut], as: UTF8.self) + "return " + String(decoding: utf8[cut...], as: UTF8.self)
        }
        return text
    }
    var text = ""
    var spans: [(String, Int, Int)] = []
    let add = { (m: Mutant, before: String, body: String, after: String) in
        text += before
        let start = text.utf8.count
        text += body
        spans.append((m.key, start, start + body.utf8.count))
        text += after
    }
    switch plan.kind {
    case .expression:
        text = "("
        for m in mutants { add(m, "__mutator_on(\(index[m.key]!)) ? (", mutated(m), ") : ") }
        text += "("
        return (Insert(text: text, spans: spans), "))")
    case .statement:
        for m in mutants { add(m, "if __mutator_on(\(index[m.key]!)) { ", mutated(m), " } else ") }
        text += "{ "
        return (Insert(text: text, spans: spans), " }")
    case .block:
        text = "{ "
        for m in mutants { add(m, "if __mutator_on(\(index[m.key]!)) ", mutated(m), " else ") }
        return (Insert(text: text, spans: spans), " }")
    case .condition:
        for m in mutants { add(m, ", ", "!__mutator_on(\(index[m.key]!))", "") }
        return (Insert(text: text, spans: spans), "")
    }
}

/// Per-file runtime: `__mutator_on(i)` is true for the active mutant (`SWIFT_MUTATOR_ACTIVE`), and in
/// dry runs (`SWIFT_MUTATOR_COVERAGE`) records that the switch was reached; the keys reached are
/// appended to that file when the process exits. File-private, so every file carries its own copy;
/// static lets, so it is initialized on first use even in `main.swift`.
func runtime(keys: [String]) -> String {
    let list = keys.map { "\"\($0)\"" }.joined(separator: ", ")
    // C calls are qualified by module so that user functions of the same name never shadow them.
    let platforms = ["Darwin", "Glibc", "Musl"].enumerated().map { i, module in
        """
        \(i == 0 ? "#if" : "#elseif") canImport(\(module))
        import \(module)
        fileprivate func __mutator_env(_ name: String) -> String? { \(module).getenv(name).map { String(cString: $0) } }
        fileprivate func __mutator_atexit() { _ = \(module).atexit { __MutatorState.flush() } }
        fileprivate func __mutator_append(_ path: String, _ text: String) {
            let fd = \(module).open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
            guard fd >= 0 else { return }
            _ = text.withCString { \(module).write(fd, $0, text.utf8.count) }
            _ = \(module).close(fd)
        }
        """
    }.joined(separator: "\n")
    return """


    // ---- swift-mutator runtime (generated) ----
    fileprivate enum __MutatorState {
        static let keys: [String] = [\(list)]
        static let active: Int = __mutator_env("\(activeEnvironment)").flatMap { keys.firstIndex(of: $0) } ?? -1
        nonisolated(unsafe) static let hits: UnsafeMutablePointer<UInt8>? = {
            guard __mutator_env("\(coverageEnvironment)") != nil else { return nil }
            let hits = UnsafeMutablePointer<UInt8>.allocate(capacity: keys.count)
            hits.initialize(repeating: 0, count: keys.count)
            __mutator_atexit()
            return hits
        }()
        static func flush() {
            guard let hits, let path = __mutator_env("\(coverageEnvironment)") else { return }
            var text = ""
            for i in 0 ..< keys.count where hits[i] != 0 { text += keys[i] + "\\n" }
            if !text.isEmpty { __mutator_append(path, text) }
        }
    }
    fileprivate func __mutator_on(_ i: Int) -> Bool {
        if let hits = __MutatorState.hits { hits[i] = 1 }
        return i == __MutatorState.active
    }
    \(platforms)
    #endif

    """
}
