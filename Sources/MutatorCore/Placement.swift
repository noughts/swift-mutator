import SwiftSyntax

// Placement rules: where a mutant switch can wrap code without changing its meaning.

public enum PlacementKind: Sendable {
    /// `(on(1) ? (mutated) : (original))`
    case expression
    /// `if on(1) { mutated } else { original }` around one statement.
    case statement
    /// `{ if on(1) { mutated } else { original } }` replacing a code block.
    case block
}

func findPlacement(_ anchor: Syntax) -> (node: Syntax, kind: PlacementKind)? {
    var current: Syntax? = anchor
    while let node = current {
        if let kind = placementKind(node) { return (node, kind) }
        // Never leave a declared function: wrapping a declaration changes its scope.
        if node.is(SourceFileSyntax.self) || isTypeDecl(node) || (isFunctionLike(node) && !node.is(ClosureExprSyntax.self)) { return nil }
        current = node.parent
    }
    return nil
}

private func placementKind(_ node: Syntax) -> PlacementKind? {
    if let block = node.as(CodeBlockSyntax.self) { return blockAllowed(block) ? .block : nil }
    if isImplicitGetter(node) { return .block }
    if let item = node.as(CodeBlockItemSyntax.self) { return statementAllowed(item) ? .statement : nil }
    if let expr = node.as(ExprSyntax.self) { return expressionAllowed(expr) ? .expression : nil }
    return nil
}

/// An `if` / `switch` whose value is used: an initializer, an argument, or the implicit return of a body.
func isValueBranching(_ node: Syntax) -> Bool {
    let root = ifChainRoot(node)
    if !isStatementLevel(root) { return true }
    guard let item = root.parent?.parent?.as(CodeBlockItemSyntax.self) ?? root.parent?.as(CodeBlockItemSyntax.self) else { return false }
    return isImplicitReturn(item)
}

private func ifChainRoot(_ node: Syntax) -> Syntax {
    var current = node
    while current.isKeyPath(\IfExprSyntax.elseBody), let parent = current.parent { current = parent }
    return current
}

private func blockAllowed(_ block: CodeBlockSyntax) -> Bool {
    guard let owner = block.parent else { return false }
    switch owner.kind {
    case .functionDecl, .initializerDecl, .deinitializerDecl, .accessorDecl: return true
    case .ifExpr: return !isValueBranching(owner)
    case .whileStmt, .forStmt, .repeatStmt, .doStmt, .catchClause, .guardStmt: return true
    default: return false
    }
}

/// The offset of the lone expression of a body returning a value: the switch turns the body into
/// statements, so that expression needs an explicit `return`.
func implicitReturnOffset(_ node: Syntax) -> Int? {
    guard returnsValue(node) else { return nil }
    let items = node.as(CodeBlockSyntax.self)?.statements ?? node.as(AccessorBlockSyntax.self).flatMap { block in
        if case let .getter(getter) = block.accessors { getter } else { nil }
    }
    guard let items, items.count == 1, let only = items.first else { return nil }
    switch only.item {
    case let .expr(expr): return expr.span.start
    case let .stmt(stmt):
        guard let expr = stmt.as(ExpressionStmtSyntax.self)?.expression, branchesAreValues(Syntax(expr)) else { return nil }
        return expr.span.start
    case .decl: return nil
    }
}

/// An `if` / `switch` whose every branch is a single value (or a `throw`): it can be the value
/// returned. With a `return` or other statements in a branch it is a statement, and `return switch`
/// would not compile.
private func branchesAreValues(_ node: Syntax) -> Bool {
    let isValue = { (items: CodeBlockItemListSyntax) -> Bool in
        guard items.count == 1, let only = items.first?.item else { return false }
        switch only {
        case .expr: return true
        case let .stmt(stmt):
            if stmt.is(ThrowStmtSyntax.self) { return true }
            return stmt.as(ExpressionStmtSyntax.self).map { branchesAreValues(Syntax($0.expression)) } ?? false
        case .decl: return false
        }
    }
    if let ifExpr = node.as(IfExprSyntax.self) {
        guard isValue(ifExpr.body.statements) else { return false }
        switch ifExpr.elseBody {
        case let .codeBlock(block): return isValue(block.statements)
        case let .ifExpr(nested): return branchesAreValues(Syntax(nested))
        case nil: return false
        }
    }
    if let switchExpr = node.as(SwitchExprSyntax.self) {
        return switchExpr.cases.allSatisfy { $0.as(SwitchCaseSyntax.self).map { isValue($0.statements) } ?? false }
    }
    return false
}

private func statementAllowed(_ item: CodeBlockItemSyntax) -> Bool {
    switch item.item {
    case .decl: return false
    case .expr: return true
    case let .stmt(stmt):
        // A guard binds names for the rest of the block; a defer runs at the end of its own block.
        return !(stmt.is(GuardStmtSyntax.self) || stmt.is(DeferStmtSyntax.self) || stmt.is(FallThroughStmtSyntax.self))
    }
}

private func isAssignment(_ node: Syntax) -> Bool {
    guard let infix = node.as(InfixOperatorExprSyntax.self) else { return false }
    if infix.operator.is(AssignmentExprSyntax.self) { return true }
    guard let op = infix.operator.as(BinaryOperatorExprSyntax.self)?.operator.text else { return false }
    return op.hasSuffix("=") && equality[op] == nil
}

/// Positions where a value cannot be replaced by a parenthesized conditional.
private func isFixedPosition(_ node: Syntax) -> Bool {
    let fixed: [AnyKeyPath] = [
    \FunctionCallExprSyntax.calledExpression,
    \SubscriptCallExprSyntax.calledExpression,
    \MemberAccessExprSyntax.base,
    \MemberAccessExprSyntax.declName,
    \ForceUnwrapExprSyntax.expression,
    \OptionalChainingExprSyntax.expression,
    \PostfixOperatorExprSyntax.expression,
    \InOutExprSyntax.expression,
    \GenericSpecializationExprSyntax.expression,
    \ConsumeExprSyntax.expression,
    \CopyExprSyntax.expression,
    ]
    return fixed.contains { node.isKeyPath($0) }
}

/// Inside an expression pattern: whether the expression binds names (`.foo(let x, 0)`).
private func bindsNames(_ node: Syntax) -> Bool {
    var ancestor = node.parent
    while let current = ancestor, !current.is(ExpressionPatternSyntax.self) {
        if current.is(CodeBlockItemSyntax.self) || current.is(MemberBlockItemSyntax.self) { return false }
        ancestor = current.parent
    }
    guard ancestor != nil else { return false }
    func contains(_ syntax: Syntax) -> Bool { syntax.is(PatternExprSyntax.self) || syntax.children(viewMode: .sourceAccurate).contains(where: contains) }
    return contains(node)
}

private func expressionAllowed(_ expr: ExprSyntax) -> Bool {
    let node = Syntax(expr)
    switch node.kind {
    case .closureExpr, .inOutExpr, .binaryOperatorExpr, .assignmentExpr, .arrowExpr, .unresolvedAsExpr, .unresolvedIsExpr,
         .unresolvedTernaryExpr, .patternExpr, .typeExpr, .discardAssignmentExpr, .editorPlaceholderExpr, .missingExpr, .superExpr:
        return false
    case .ifExpr, .switchExpr:
        if isStatementLevel(node) { return false }
    default:
        break
    }
    if isAssignment(node) || bindsNames(node) { return false }
    let position = outermost(node)
    if isFixedPosition(position) { return false }
    if position.isKeyPath(\InfixOperatorExprSyntax.leftOperand), let parent = position.parent, isAssignment(parent) { return false }
    return true
}
