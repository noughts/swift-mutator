import SwiftParser
import SwiftSyntax

// Scopes give mutants a position independent identity: functions are named by their path
// (`Cart.total(for:)>map`), types by name, other top-level code by a content hash.

/// Top-level code gets scope ids starting with `<top`; such scopes never qualify nested names.
public func isTopLevelScope(_ id: String) -> Bool { id.hasPrefix("<top") }

/// Tokens of `node` joined by single spaces, nested scopes replaced by `placeholder` (or dropped):
/// formatting and comments do not change it, string contents and everything else do.
func normalizedTokens(_ node: Syntax, holes: [Span], placeholder: String? = "ƒ") -> String {
    let own = node.span
    let inner = holes.filter { own.contains($0) && $0 != own }
    var parts: [String] = []
    var holeIndex = 0
    var skipUntil = -1
    for token in node.tokens(viewMode: .sourceAccurate) {
        let start = token.positionAfterSkippingLeadingTrivia.utf8Offset
        if start < skipUntil { continue }
        while holeIndex < inner.count, inner[holeIndex].end <= start { holeIndex += 1 }
        if holeIndex < inner.count, inner[holeIndex].start <= start {
            if let placeholder { parts.append(placeholder) }
            skipUntil = inner[holeIndex].end
            holeIndex += 1
            continue
        }
        parts.append(token.text)
    }
    return parts.joined(separator: " ")
}

struct ScopeFrame {
    let scope: Scope
    let node: Syntax
    /// Length of the AST path where this scope starts (for paths relative to the scope).
    let depth: Int
}

/// Tracks the scope stack during one walk. Local to `analyze`.
struct ScopeTracker {
    private(set) var stack: [ScopeFrame] = []
    private var used: Set<String> = []
    private var anonymous: [String: Int] = [:]
    let hashOf: (Syntax) -> String

    init(hashOf: @escaping (Syntax) -> String) {
        self.hashOf = hashOf
    }

    var current: ScopeFrame? { stack.last }

    /// Call on entering a node; returns the scope the node opened, if any.
    mutating func enter(_ node: Syntax, depth: Int) -> Scope? {
        guard var id = scopeId(node) else { return nil }
        let hash = hashOf(node)
        if used.contains(id) {
            // Same-named siblings (overloads, several `map` closures) are told apart by content,
            // not position, so inserting one does not rename the others.
            let base = "\(id)#\(hash.prefix(6))"
            id = base
            var n = 2
            while used.contains(id) {
                id = "\(base)#\(n)"
                n += 1
            }
        }
        used.insert(id)
        let scope = Scope(id: id, hash: hash, span: node.span, isFunction: isFunctionLike(node))
        stack.append(ScopeFrame(scope: scope, node: node, depth: depth))
        return scope
    }

    mutating func leave(_ node: Syntax) {
        if stack.last?.node.id == node.id { stack.removeLast() }
    }

    private mutating func scopeId(_ node: Syntax) -> String? {
        if isFunctionLike(node) {
            let name = functionName(node) ?? nextAnonymous()
            return qualify(name)
        }
        if let name = typeDeclName(node) { return qualify(name) }
        if current == nil, isTopLevelStatement(node) {
            return topLevelName(node) ?? "<top:\(hashOf(node).prefix(6))>"
        }
        return nil
    }

    private mutating func nextAnonymous() -> String {
        let parent = current?.scope.id ?? ""
        let n = (anonymous[parent] ?? 0) + 1
        anonymous[parent] = n
        return "<anon\(n)>"
    }

    private func qualify(_ name: String) -> String {
        guard let parent = current?.scope, !isTopLevelScope(parent.id) else { return name }
        return parent.isFunction ? "\(parent.id)>\(name)" : "\(parent.id).\(name)"
    }
}

/// A top-level item that is not itself a function or type (those open their own scopes).
private func isTopLevelStatement(_ node: Syntax) -> Bool {
    guard let item = node.as(CodeBlockItemSyntax.self), item.parent?.parent?.is(SourceFileSyntax.self) == true else { return false }
    let inner = Syntax(item.item)
    return !isFunctionLike(inner) && !isTypeDecl(inner)
}

private func topLevelName(_ node: Syntax) -> String? {
    guard let item = node.as(CodeBlockItemSyntax.self), let variable = item.item.as(VariableDeclSyntax.self),
          variable.bindings.count == 1, let pattern = variable.bindings.first?.pattern.as(IdentifierPatternSyntax.self) else { return nil }
    return pattern.identifier.text
}

/// Position independent name of a function-like node, or nil when anonymous.
private func functionName(_ node: Syntax) -> String? {
    if let decl = node.as(FunctionDeclSyntax.self) { return decl.name.text + parameterLabels(decl.signature.parameterClause.parameters) }
    if let decl = node.as(InitializerDeclSyntax.self) {
        return "init" + (decl.optionalMark?.text ?? "") + parameterLabels(decl.signature.parameterClause.parameters)
    }
    if node.is(DeinitializerDeclSyntax.self) { return "deinit" }
    if let accessor = node.as(AccessorDeclSyntax.self) {
        // AccessorDecl -> AccessorDeclList -> AccessorBlock -> owner
        let owner = accessor.parent?.parent.flatMap(accessorOwnerName)
        return [owner, accessor.accessorSpecifier.text].compactMap { $0 }.joined(separator: ".")
    }
    if node.is(AccessorBlockSyntax.self) {
        return [accessorOwnerName(node), "get"].compactMap { $0 }.joined(separator: ".")
    }
    if node.is(ClosureExprSyntax.self) { return closureName(node) }
    return nil
}

/// The property or subscript an accessor block belongs to.
private func accessorOwnerName(_ block: Syntax) -> String? {
    guard let owner = block.parent else { return nil }
    if let binding = owner.as(PatternBindingSyntax.self) {
        return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    }
    if let subscriptDecl = owner.as(SubscriptDeclSyntax.self) {
        return "subscript" + parameterLabels(subscriptDecl.parameterClause.parameters)
    }
    return nil
}

/// A closure is named after the call it is passed to and that call's first string argument
/// (`map`, `sink`, `group("io")`), or after the binding it initializes.
private func closureName(_ node: Syntax) -> String? {
    if node.isKeyPath(\InitializerClauseSyntax.value), let binding = node.parent?.parent?.as(PatternBindingSyntax.self) {
        return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
    }
    let call: FunctionCallExprSyntax?
    if node.isKeyPath(\FunctionCallExprSyntax.trailingClosure) {
        call = node.parent?.as(FunctionCallExprSyntax.self)
    } else if node.isKeyPath(\LabeledExprSyntax.expression) {
        call = node.parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
    } else if node.isKeyPath(\MultipleTrailingClosureElementSyntax.closure) {
        call = node.parent?.parent?.parent?.as(FunctionCallExprSyntax.self)
    } else {
        call = nil
    }
    guard let call, let name = calleeName(call.calledExpression) else { return nil }
    if let first = call.arguments.first?.expression.as(StringLiteralExprSyntax.self), let label = first.representedLiteralValue {
        return "\(name)(\(quoted(label)))"
    }
    return name
}

/// `f`, `obj.m` -> `m`.
func calleeName(_ callee: ExprSyntax) -> String? {
    if let ref = callee.as(DeclReferenceExprSyntax.self) { return ref.baseName.text }
    if let member = callee.as(MemberAccessExprSyntax.self) { return member.declName.baseName.text }
    return nil
}

func quoted(_ value: String) -> String {
    var out = "\""
    for ch in value {
        switch ch {
        case "\"": out += "\\\""
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        default: out.append(ch)
        }
    }
    return out + "\""
}
