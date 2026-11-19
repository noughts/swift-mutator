import SwiftSyntax

// Arid node suppression (Google, "Practical Mutation Testing at Scale"): a simple node is arid
// when an expert rule says so, a compound node when all of its parts are. Mutants anchored in
// arid code are reported but not run.

/// Callee patterns: `logger.*` (any segment but the last), `*.debug` (last segment), `print` (exact).
public let defaultAridCallees = ["print", "debugPrint", "dump", "NSLog", "os_log", "logger.*", "log.*", "*.debug", "*.trace", "debug"]

private func calleePath(_ callee: ExprSyntax) -> String? {
    var names: [String] = []
    var current = unwrapParens(callee)
    while true {
        if let ref = current.as(DeclReferenceExprSyntax.self) {
            names.append(ref.baseName.text)
            break
        }
        if let member = current.as(MemberAccessExprSyntax.self), let base = member.base {
            names.append(member.declName.baseName.text)
            current = base
            continue
        }
        if let chained = current.as(OptionalChainingExprSyntax.self) {
            current = chained.expression
            continue
        }
        if let forced = current.as(ForceUnwrapExprSyntax.self) {
            current = forced.expression
            continue
        }
        return nil
    }
    let path = names.reversed()
    return (path.first == "self" ? path.dropFirst() : path[...]).joined(separator: ".")
}

private func matcher(_ patterns: [String]) -> (String) -> Bool {
    let tests: [(String) -> Bool] = patterns.map { pattern in
        if pattern.hasSuffix(".*") {
            let head = String(pattern.dropLast(2))
            return { path in path == head || path.hasPrefix("\(head).") || path.split(separator: ".").dropLast().contains(Substring(head)) }
        }
        if pattern.hasPrefix("*.") {
            let tail = String(pattern.dropFirst(2))
            return { path in path.hasSuffix(".\(tail)") }
        }
        return { path in path == pattern }
    }
    return { path in tests.contains { $0(path) } }
}

/// A check telling whether a mutant anchored at a node lies in logging-only code.
func aridCheck(callees: [String]) -> (Syntax) -> Bool {
    let isLoggingPath = matcher(callees)

    func isLoggingCall(_ expr: ExprSyntax) -> Bool {
        guard let call = unwrapEffects(expr).as(FunctionCallExprSyntax.self), let path = calleePath(call.calledExpression) else { return false }
        return isLoggingPath(path)
    }

    func aridItem(_ item: CodeBlockItemSyntax) -> Bool {
        switch item.item {
        case let .expr(expr): return isLoggingCall(expr)
        case let .stmt(stmt): return stmt.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self).map(aridIf) ?? false
        case .decl: return false
        }
    }

    func aridBlock(_ block: CodeBlockSyntax) -> Bool {
        !block.statements.isEmpty && block.statements.allSatisfy(aridItem)
    }

    func aridIf(_ ifExpr: IfExprSyntax) -> Bool {
        guard aridBlock(ifExpr.body) else { return false }
        switch ifExpr.elseBody {
        case nil: return true
        case let .codeBlock(block)?: return aridBlock(block)
        case let .ifExpr(next)?: return aridIf(next)
        }
    }

    return { anchor in
        var current: Syntax? = anchor
        while let node = current {
            if let call = node.as(FunctionCallExprSyntax.self), isLoggingCall(ExprSyntax(call)) { return true }
            if let item = node.as(CodeBlockItemSyntax.self) {
                if aridItem(item) { return true }
                // Other statements and declarations end the search; expression statements and ifs climb on.
                switch item.item {
                case .expr: break
                case let .stmt(stmt): if stmt.as(ExpressionStmtSyntax.self)?.expression.is(IfExprSyntax.self) != true { return false }
                case .decl: return false
                }
            }
            if let block = node.as(CodeBlockSyntax.self), aridBlock(block) { return true }
            if let ifExpr = node.as(IfExprSyntax.self), isStatementLevel(Syntax(ifExpr)), aridIf(ifExpr) { return true }
            if isFunctionLike(node) || isTypeDecl(node) || node.is(SourceFileSyntax.self) { return false }
            current = node.parent
        }
        return false
    }
}
