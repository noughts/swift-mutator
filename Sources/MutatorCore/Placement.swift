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
        guard let expr = stmt.as(ExpressionStmtSyntax.self)?.expression, expr.is(IfExprSyntax.self) || expr.is(SwitchExprSyntax.self) else { return nil }
        return expr.span.start
    case .decl: return nil
    }
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
    if isAssignment(node) { return false }
    let position = outermost(node)
    if isFixedPosition(position) { return false }
    if position.isKeyPath(\InfixOperatorExprSyntax.leftOperand), let parent = position.parent, isAssignment(parent) { return false }
    return true
}
