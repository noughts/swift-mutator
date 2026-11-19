import SwiftSyntax

// Helpers over swift-syntax trees: byte spans, transparent wrappers, function-like nodes, comments.

extension SyntaxProtocol {
    /// Span without leading / trailing trivia.
    var span: Span {
        Span(start: positionAfterSkippingLeadingTrivia.utf8Offset, end: endPositionBeforeTrailingTrivia.utf8Offset)
    }

    func isKeyPath(_ keyPath: AnyKeyPath) -> Bool { keyPathInParent == keyPath }
}

/// The span a switch replaces: a statement without its `;`, which must stay between statements.
func replacedSpan(_ node: Syntax) -> Span {
    node.as(CodeBlockItemSyntax.self)?.item.span ?? node.span
}

/// `(x)`: a tuple with one unlabeled element is a parenthesized expression.
func parenthesized(_ node: Syntax) -> ExprSyntax? {
    guard let tuple = node.as(TupleExprSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.label == nil else { return nil }
    return only.expression
}

/// A plain `as` coercion: it keeps the value (unlike `as?` / `as!`).
private func coerced(_ node: Syntax) -> ExprSyntax? {
    guard let cast = node.as(AsExprSyntax.self), cast.questionOrExclamationMark == nil else { return nil }
    return cast.expression
}

/// Strip parentheses.
func unwrapParens(_ expr: ExprSyntax) -> ExprSyntax {
    var current = expr
    while let inner = parenthesized(Syntax(current)) { current = inner }
    return current
}

/// Strip transparent wrappers (parentheses, plain `as`): the expression whose value it is.
func unwrap(_ expr: ExprSyntax) -> ExprSyntax {
    var current = expr
    while let inner = parenthesized(Syntax(current)) ?? coerced(Syntax(current)) { current = inner }
    return current
}

/// Strip parentheses, `try` and `await`: the call or value they wrap.
func unwrapEffects(_ expr: ExprSyntax) -> ExprSyntax {
    var current = unwrapParens(expr)
    while true {
        if let tryExpr = current.as(TryExprSyntax.self) {
            current = unwrapParens(tryExpr.expression)
        } else if let awaitExpr = current.as(AwaitExprSyntax.self) {
            current = unwrapParens(awaitExpr.expression)
        } else {
            return current
        }
    }
}

/// The outermost transparent wrapper around a node (the node itself when unwrapped): parentheses
/// and plain `as` coercions keep the value. Its parent is the position the node really occupies.
func outermost(_ node: Syntax) -> Syntax {
    var current = node
    while true {
        if let element = current.parent, element.is(LabeledExprSyntax.self),
           let list = element.parent, list.is(LabeledExprListSyntax.self),
           let tuple = list.parent, parenthesized(tuple) != nil {
            current = tuple
        } else if current.isKeyPath(\AsExprSyntax.expression), let cast = current.parent, coerced(cast) != nil {
            current = cast
        } else {
            return current
        }
    }
}

/// Functions, initializers, accessors, closures: nodes whose body runs on its own.
func isFunctionLike(_ node: Syntax) -> Bool {
    switch node.kind {
    case .functionDecl, .initializerDecl, .deinitializerDecl, .accessorDecl, .closureExpr:
        return true
    case .accessorBlock:
        return isImplicitGetter(node)
    default:
        return false
    }
}

/// `var x: Int { ... }` / `subscript(i: Int) -> Int { ... }` without `get` / `set` keywords.
func isImplicitGetter(_ node: Syntax) -> Bool {
    guard let block = node.as(AccessorBlockSyntax.self), case .getter = block.accessors else { return false }
    return true
}

/// The name of a struct, class, enum or actor, or the extended type of an extension; nil for other nodes.
func typeDeclName(_ node: Syntax) -> String? {
    if let extensionDecl = node.as(ExtensionDeclSyntax.self) { return extensionDecl.extendedType.trimmedDescription.filter { !$0.isWhitespace } }
    switch node.kind {
    case .structDecl, .classDecl, .enumDecl, .actorDecl: return node.asProtocol(NamedDeclSyntax.self)?.name.text
    default: return nil
    }
}

func isTypeDecl(_ node: Syntax) -> Bool { typeDeclName(node) != nil }

/// `(_:to:)`: argument labels as in Swift's own function names.
func parameterLabels(_ parameters: FunctionParameterListSyntax) -> String {
    "(" + parameters.map { "\($0.firstName.text):" }.joined() + ")"
}

/// A type written like a collection literal: `[Int]()`, `[String: Int](...)`, `[Item].self`, `[Int].init`.
func isTypeLiteral(_ node: Syntax) -> Bool {
    guard node.is(ArrayExprSyntax.self) || node.is(DictionaryExprSyntax.self) else { return false }
    if node.isKeyPath(\FunctionCallExprSyntax.calledExpression) { return true }
    guard node.isKeyPath(\MemberAccessExprSyntax.base), let member = node.parent?.as(MemberAccessExprSyntax.self) else { return false }
    return ["self", "init"].contains(member.declName.baseName.text)
}

/// `if` / `switch` used as a statement rather than as a value.
func isStatementLevel(_ node: Syntax) -> Bool {
    guard let parent = node.parent else { return false }
    if parent.is(ExpressionStmtSyntax.self) { return true }
    return parent.is(CodeBlockItemSyntax.self)
}

private let inlinableAttributes: Set<String> = ["inlinable", "_alwaysEmitIntoClient", "_transparent"]

/// Bodies that may be copied into clients cannot reference the file-private runtime.
func isInlinable(_ node: Syntax) -> Bool {
    guard let decl = node.asProtocol(WithAttributesSyntax.self) else { return false }
    return decl.attributes.contains { element in
        guard case let .attribute(attribute) = element else { return false }
        return inlinableAttributes.contains(attribute.attributeName.trimmedDescription)
    }
}

/// Comments of the file with their spans (from leading and trailing trivia).
func collectComments(_ tree: some SyntaxProtocol) -> [Comment] {
    var out: [Comment] = []
    for token in tree.tokens(viewMode: .sourceAccurate) {
        var offset = token.position.utf8Offset
        let collect = { (pieces: Trivia, start: Int) -> Int in
            var at = start
            for piece in pieces {
                let length = piece.sourceLength.utf8Length
                if let value = commentValue(piece) { out.append(Comment(value: value, span: Span(start: at, end: at + length))) }
                at += length
            }
            return at
        }
        offset = collect(token.leadingTrivia, offset)
        offset += token.trimmedLength.utf8Length
        _ = collect(token.trailingTrivia, offset)
    }
    return out
}

private func commentValue(_ piece: TriviaPiece) -> String? {
    switch piece {
    case let .lineComment(text):
        return String(text.dropFirst(2))
    case let .docLineComment(text):
        return String(text.dropFirst(3))
    case let .blockComment(text), let .docBlockComment(text):
        return String(text.dropFirst(2).dropLast(2))
    default:
        return nil
    }
}
