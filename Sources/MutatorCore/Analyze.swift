import SwiftOperators
import SwiftParser
import SwiftSyntax

// Analysis: parse a file, run the mutators over its runtime code, give every mutant a
// position independent key, and decide where its switch goes. `emit` turns the result into
// instrumented source.

public struct AnalyzeOptions: Hashable, Sendable {
    public var excludedMutators: Set<MutatorName>
    /// Logging-call patterns for arid suppression; nil disables it.
    public var aridCallees: [String]?

    public init(excludedMutators: Set<MutatorName> = [], aridCallees: [String]? = defaultAridCallees) {
        self.excludedMutators = excludedMutators
        self.aridCallees = aridCallees
    }
}

public struct Analysis: Sendable {
    /// Every mutant, including ignored ones.
    public let mutants: [Mutant]
    /// Every scope of the file, with or without mutants.
    public let scopes: [Scope]
    public let placements: [PlacementPlan]
    /// Spans of the statements and member declarations of runtime code (for blaming compiler errors).
    public let statements: [Span]
    /// The file did not parse; nothing was mutated.
    public let parseError: Bool
}

/// Subtrees without mutable runtime code, or where a switch could not be compiled.
private func isSkipped(_ node: Syntax) -> Bool {
    if node.is(TypeSyntax.self) || isTypeLiteral(node) { return true }
    // Patterns bind names; the expressions of an expression pattern (`case "GET":`) are values.
    if node.is(PatternSyntax.self), !node.is(ExpressionPatternSyntax.self) { return true }
    switch node.kind {
    case .attributeList, .importDecl, .typeAliasDecl, .associatedTypeDecl, .protocolDecl, .operatorDecl, .precedenceGroupDecl,
         .enumCaseDecl, .macroExpansionExpr, .macroExpansionDecl, .macroDecl, .genericParameterClause, .genericWhereClause,
         .inheritanceClause, .functionSignature, .closureSignature, .functionParameterClause, .returnClause, .typeAnnotation,
         .genericArgumentClause, .keyPathExpr, .availabilityCondition, .poundSourceLocation:
        return true
    default:
        break
    }
    if node.isKeyPath(\IfConfigClauseSyntax.condition) { return true }
    if let function = node.as(FunctionDeclSyntax.self), function.body == nil { return true }
    return isInlinable(node)
}

/// Depth-first pre-order walk over runtime syntax. Each child gets a path component
/// `kind:n` (n = index among same-kind siblings), stable when unrelated siblings change.
private func walk(_ node: Syntax, component: String, visit: (Syntax, String) -> Void, leave: (Syntax) -> Void) {
    if isSkipped(node) { return }
    visit(node, component)
    var counts: [SyntaxKind: Int] = [:]
    for child in node.children(viewMode: .sourceAccurate) {
        let n = counts[child.kind, default: 0]
        counts[child.kind] = n + 1
        walk(child, component: "\(child.kind):\(n)", visit: visit, leave: leave)
    }
    leave(node)
}

/// Spans of the nodes the walk opens scopes for: nested scopes are holes in their parent's hash.
/// Skipped subtrees stay part of the enclosing hash, so editing them still invalidates it.
private func scopeSpans(_ tree: Syntax) -> [Span] {
    var out: [Span] = []
    walk(tree, component: "", visit: { node, _ in
        if isFunctionLike(node) || isTypeDecl(node) { out.append(node.span) }
    }, leave: { _ in })
    return out
}

private struct Found {
    let candidate: Candidate
    let scope: Scope
    let astPath: String
}

/// Mutants a statement removal would only duplicate: another mutant lies inside the statement.
private func redundantCallStatements(_ found: [Found]) -> Set<Int> {
    Set(found.indices.filter { i in
        found[i].candidate.mutator == .callExpression && found.indices.contains { $0 != i && found[i].candidate.span.contains(found[$0].candidate.span) }
    })
}

public func analyze(file: String, source: String, options: AnalyzeOptions = .init()) -> Analysis {
    let bytes = Array(source.utf8)
    let parsed = Parser.parse(source: source)
    if parsed.hasError {
        return Analysis(mutants: [], scopes: [], placements: [], statements: [], parseError: true)
    }
    let tree = OperatorTable.standardOperators.foldAll(parsed) { _ in }
    let lines = LineIndex(bytes)
    let holes = scopeSpans(tree)
    let hashOf = { (node: Syntax) in stableHash(normalizedTokens(node, holes: holes)) }
    let disabled = disabledBy(collectComments(tree), line: { lines.position($0).line })
    let isArid = options.aridCallees.map { aridCheck(callees: $0) } ?? { _ in false }
    let context = MutatorContext(bytes: bytes)

    var tracker = ScopeTracker(hashOf: hashOf)
    var path: [String] = []
    var scopes: [Scope] = []
    var statements: [Span] = []
    var found: [Found] = []
    walk(tree, component: "", visit: { node, component in
        path.append(component)
        if let scope = tracker.enter(node, depth: path.count) { scopes.append(scope) }
        if node.is(CodeBlockItemSyntax.self) || node.is(MemberBlockItemSyntax.self) { statements.append(node.span) }
        guard let frame = tracker.current else { return }
        let astPath = path[frame.depth...].joined(separator: "/")
        for mutate in mutators {
            for candidate in mutate(node, context) where !options.excludedMutators.contains(candidate.mutator) {
                found.append(Found(candidate: candidate, scope: frame.scope, astPath: astPath))
            }
        }
    }, leave: { node in
        path.removeLast()
        tracker.leave(node)
    })

    let redundant = redundantCallStatements(found)

    var mutants: [Mutant] = []
    var seenEdits = Set<String>()
    var usedKeys: [String: Int] = [:]
    var placements: [(node: Syntax, kind: PlacementKind, keys: [String])] = []
    var placementIndex: [SyntaxIdentifier: Int] = [:]
    for (i, f) in found.enumerated() where !redundant.contains(i) {
        let c = f.candidate
        // Two mutators producing the same edit: the first one keeps it.
        guard seenEdits.insert("\(c.span.start):\(c.span.end):\(c.replacement)").inserted else { continue }
        var key = stableHash("\(file)\0\(f.scope.id)\0\(f.astPath)\0\(c.mutator.rawValue)\0\(c.replacement)")
        let dup = usedKeys[key, default: 0] + 1
        usedKeys[key] = dup
        if dup > 1 { key = "\(key)-\(dup)" }
        var mutant = Mutant(key: key, file: file, mutator: c.mutator, span: c.span, location: lines.location(c.span), original: context.text(c.span), replacement: c.replacement, scope: f.scope)
        if let reason = disabled(c.mutator, c.span.start) ?? (isArid(c.anchor) ? "arid: logging" : nil) {
            mutant.ignored = reason
        } else if let placement = findPlacement(c.anchor) {
            if let index = placementIndex[placement.node.id] {
                placements[index].keys.append(key)
            } else {
                placementIndex[placement.node.id] = placements.count
                placements.append((placement.node, placement.kind, [key]))
            }
        } else {
            mutant.ignored = "unplaceable"
        }
        mutants.append(mutant)
    }

    let plans = placements.map { p in
        PlacementPlan(span: replacedSpan(p.node), kind: p.kind, implicitReturnAt: implicitReturnOffset(p.node), keys: p.keys)
    }
    return Analysis(mutants: mutants, scopes: scopes, placements: plans, statements: statements, parseError: false)
}

/// The source with one mutant applied (for reports and previews).
public func applyMutant(_ source: String, _ mutant: Mutant) -> String {
    let bytes = Array(source.utf8)
    return bytes.text(Span(start: 0, end: mutant.span.start)) + mutant.replacement + bytes.text(Span(start: mutant.span.end, end: bytes.count))
}
