import SwiftParser
import SwiftSyntax

// Mutators: pure functions (node, source) -> candidate edits. Placement (mutation switching),
// identity, arid and disable handling are done by `analyze`.

struct Candidate {
    let mutator: MutatorName
    /// Region of the original source that is replaced.
    let span: Span
    let replacement: String
    /// Node from which the placement search starts.
    let anchor: Syntax
}

struct MutatorContext {
    let bytes: [UInt8]

    func text(_ span: Span) -> String { bytes.text(span) }
    func text(_ node: some SyntaxProtocol) -> String { bytes.text(node.span) }
}

typealias Mutator = @Sendable (Syntax, MutatorContext) -> [Candidate]

private func whole(_ node: Syntax, _ mutator: MutatorName, _ replacement: String) -> Candidate {
    Candidate(mutator: mutator, span: node.span, replacement: replacement, anchor: node)
}

private func infixOperator(_ node: Syntax) -> (InfixOperatorExprSyntax, TokenSyntax)? {
    guard let infix = node.as(InfixOperatorExprSyntax.self), let op = infix.operator.as(BinaryOperatorExprSyntax.self) else { return nil }
    return (infix, op.operator)
}

/// The whole infix expression with its operator token replaced.
private func swapOperator(_ node: Syntax, _ token: TokenSyntax, to: String, _ mutator: MutatorName, _ ctx: MutatorContext) -> Candidate {
    let span = node.span
    let op = token.span
    let text = ctx.text(Span(start: span.start, end: op.start)) + to + ctx.text(Span(start: op.end, end: span.end))
    return whole(node, mutator, text)
}

private func isStringy(_ expr: ExprSyntax) -> Bool {
    unwrapParens(expr).is(StringLiteralExprSyntax.self)
}

private func isCollectionLiteral(_ expr: ExprSyntax) -> Bool {
    let inner = unwrapParens(expr)
    return inner.is(ArrayExprSyntax.self) || inner.is(DictionaryExprSyntax.self)
}

// ---- operators -------------------------------------------------------------

private let arithmetic: [String: String] = ["+": "-", "-": "+", "*": "/", "/": "*", "%": "*", "&+": "&-", "&-": "&+"]

private let arithmeticOperator: Mutator = { node, ctx in
    guard let (infix, token) = infixOperator(node), let to = arithmetic[token.text] else { return [] }
    if token.text == "+" || token.text == "&+" {
        // `"a" + b` and `xs + [x]` concatenate: `-` does not type-check there.
        let left = unwrapParens(infix.leftOperand)
        let leftmost = left.as(InfixOperatorExprSyntax.self)?.rightOperand ?? infix.leftOperand
        let operands = [infix.leftOperand, infix.rightOperand, leftmost]
        if operands.contains(where: { isStringy($0) || isCollectionLiteral($0) }) { return [] }
    }
    return [swapOperator(node, token, to: to, .arithmeticOperator, ctx)]
}

let equality: [String: [String]] = [
    "<": ["<=", ">="],
    "<=": ["<", ">"],
    ">": [">=", "<="],
    ">=": [">", "<"],
    "==": ["!="],
    "!=": ["=="],
    "===": ["!=="],
    "!==": ["==="],
]

private let equalityOperator: Mutator = { node, ctx in
    guard let (_, token) = infixOperator(node) else { return [] }
    return (equality[token.text] ?? []).map { swapOperator(node, token, to: $0, .equalityOperator, ctx) }
}

private let logicalOperator: Mutator = { node, ctx in
    guard let (infix, token) = infixOperator(node) else { return [] }
    switch token.text {
    case "&&": return [swapOperator(node, token, to: "||", .logicalOperator, ctx)]
    case "||": return [swapOperator(node, token, to: "&&", .logicalOperator, ctx)]
    // `a ?? b` -> `b`: always the default. Has the type of `b` like the original.
    case "??": return [whole(node, .logicalOperator, ctx.text(infix.rightOperand))]
    default: return []
    }
}

private let assignment: [String: String] = [
    "+=": "-=", "-=": "+=", "*=": "/=", "/=": "*=", "%=": "*=",
    "<<=": ">>=", ">>=": "<<=", "&=": "|=", "|=": "&=",
]

private let assignmentOperator: Mutator = { node, ctx in
    guard let (infix, token) = infixOperator(node), let to = assignment[token.text] else { return [] }
    if token.text == "+=", isStringy(infix.rightOperand) || isCollectionLiteral(infix.rightOperand) { return [] }
    return [swapOperator(node, token, to: to, .assignmentOperator, ctx)]
}

private let unaryOperator: Mutator = { node, ctx in
    // Deletion only (cargo-mutants): the operand has the type of the whole expression.
    guard let prefix = node.as(PrefixOperatorExprSyntax.self), ["-", "~"].contains(prefix.operator.text) else { return [] }
    return [whole(node, .unaryOperator, ctx.text(prefix.expression))]
}

private let booleanLiteral: Mutator = { node, ctx in
    if let literal = node.as(BooleanLiteralExprSyntax.self) {
        return [whole(node, .booleanLiteral, literal.literal.text == "true" ? "false" : "true")]
    }
    if let prefix = node.as(PrefixOperatorExprSyntax.self), prefix.operator.text == "!" {
        return [whole(node, .booleanLiteral, ctx.text(prefix.expression))]
    }
    return []
}

// ---- conditions ------------------------------------------------------------

private enum TestPosition {
    /// if / guard / ternary condition; `first` among the expression conditions of its list.
    case branch(first: Bool)
    /// while / repeat-while condition.
    case loop(first: Bool)
}

/// Whether the value of `node` is only used for its truth by an if / guard / while / repeat / ternary.
private func testPosition(_ node: Syntax) -> TestPosition? {
    let position = outermost(node)
    if position.isKeyPath(\TernaryExprSyntax.condition) { return .branch(first: true) }
    if position.isKeyPath(\RepeatStmtSyntax.condition) { return .loop(first: true) }
    guard position.isKeyPath(\ConditionElementSyntax.condition), let element = position.parent?.as(ConditionElementSyntax.self),
          let list = element.parent?.as(ConditionElementListSyntax.self), let owner = list.parent else { return nil }
    let first = list.first { if case .expression = $0.condition { true } else { false } }?.id == element.id
    if owner.is(WhileStmtSyntax.self) { return .loop(first: first) }
    if owner.is(IfExprSyntax.self) || owner.is(GuardStmtSyntax.self) { return .branch(first: first) }
    return nil
}

private let conditionalExpression: Mutator = { node, _ in
    guard node.is(ExprSyntax.self) else { return [] }
    switch testPosition(node) {
    case let .branch(first):
        // Several conditions act like `&&`: each may become true; one false stands for all.
        return [whole(node, .conditionalExpression, "true")] + (first ? [whole(node, .conditionalExpression, "false")] : [])
    case let .loop(first):
        return first ? [whole(node, .conditionalExpression, "false")] : []
    case nil:
        break
    }
    guard let (_, token) = infixOperator(node), equality[token.text] != nil || token.text == "&&" || token.text == "||" else { return [] }
    // `a || <x>` with x=true / `a && <x>` with x=false collapse to mutants of the parent.
    let outer = outermost(node).parent.flatMap(infixOperator)?.1.text
    var out: [Candidate] = []
    if outer != "||" { out.append(whole(node, .conditionalExpression, "true")) }
    if outer != "&&" { out.append(whole(node, .conditionalExpression, "false")) }
    return out
}

// ---- literals ----------------------------------------------------------------

private let placeholder = "Stryker was here!"

private let arrayDeclaration: Mutator = { node, _ in
    guard let array = node.as(ArrayExprSyntax.self), !array.elements.isEmpty else { return [] }
    return [whole(node, .arrayDeclaration, "[]")]
}

private let dictionaryLiteral: Mutator = { node, _ in
    guard let dictionary = node.as(DictionaryExprSyntax.self), case let .elements(elements) = dictionary.content, !elements.isEmpty else { return [] }
    return [whole(node, .dictionaryLiteral, "[:]")]
}

private let stringLiteral: Mutator = { node, _ in
    guard let literal = node.as(StringLiteralExprSyntax.self) else { return [] }
    let empty = literal.segments.allSatisfy { segment in
        if case let .stringSegment(part) = segment { part.content.text.isEmpty } else { false }
    }
    return [whole(node, .stringLiteral, empty ? "\"\(placeholder)\"" : "\"\"")]
}

// ---- statements ----------------------------------------------------------------

func isVoid(_ returnClause: ReturnClauseSyntax?) -> Bool {
    guard let type = returnClause?.type else { return true }
    let text = type.trimmedDescription
    return text == "Void" || text == "()"
}

/// Blocks that may be emptied: statement bodies and bodies of functions that return nothing.
/// `guard` bodies must exit, initializers must initialize, other function bodies are FnValue's.
private func canEmpty(_ block: CodeBlockSyntax) -> Bool {
    guard let owner = block.parent else { return false }
    switch owner.kind {
    case .ifExpr: return !isValueBranching(owner)
    case .whileStmt, .forStmt, .repeatStmt, .doStmt, .catchClause, .deferStmt, .deinitializerDecl: return true
    case .functionDecl: return isVoid(owner.as(FunctionDeclSyntax.self)?.signature.returnClause)
    case .accessorDecl: return ["set", "willSet", "didSet"].contains(owner.as(AccessorDeclSyntax.self)?.accessorSpecifier.text ?? "")
    default: return false
    }
}

private let blockStatement: Mutator = { node, _ in
    guard let block = node.as(CodeBlockSyntax.self), !block.statements.isEmpty, canEmpty(block) else { return [] }
    return [whole(node, .blockStatement, "{}")]
}

/// A body that produces a value: of a function with a return type, of a getter, or an implicit getter.
func returnsValue(_ body: Syntax) -> Bool {
    if isImplicitGetter(body) { return true }
    guard body.is(CodeBlockSyntax.self), let owner = body.parent else { return false }
    if let function = owner.as(FunctionDeclSyntax.self) { return !isVoid(function.signature.returnClause) }
    return owner.as(AccessorDeclSyntax.self)?.accessorSpecifier.text == "get"
}

/// The only statement of a closure or of a body returning a value: it is the implicit return value.
func isImplicitReturn(_ item: CodeBlockItemSyntax) -> Bool {
    guard let list = item.parent?.as(CodeBlockItemListSyntax.self), list.count == 1, let owner = list.parent else { return false }
    return owner.is(ClosureExprSyntax.self) || returnsValue(owner)
}

private let neverReturning: Set<String> = ["fatalError", "preconditionFailure", "exit", "abort"]

/// `call()` as a statement -> removed. `throw` is not mutated: removing it mostly duplicates
/// the guarding condition's mutants. Dropped later when another mutant lies inside the statement.
private let callExpression: Mutator = { node, _ in
    guard let item = node.as(CodeBlockItemSyntax.self), case let .expr(expr) = item.item, !isImplicitReturn(item),
          let call = unwrapEffects(expr).as(FunctionCallExprSyntax.self) else { return [] }
    let callee = call.calledExpression.trimmedDescription
    if callee.hasSuffix(".init") || callee == "init" || neverReturning.contains(callee) { return [] }
    return [Candidate(mutator: .callExpression, span: replacedSpan(node), replacement: "", anchor: node)]
}

// ---- methods -----------------------------------------------------------------

private let methodRemovals: Set<String> = ["filter", "sorted", "reversed", "trimmingCharacters"]
private let methodSwaps: [String: String] = [
    "hasPrefix": "hasSuffix", "hasSuffix": "hasPrefix",
    "lowercased": "uppercased", "uppercased": "lowercased",
    "min": "max", "max": "min",
    "first": "last", "last": "first",
    "prefix": "suffix", "suffix": "prefix",
    "dropFirst": "dropLast", "dropLast": "dropFirst",
    "removeFirst": "removeLast", "removeLast": "removeFirst",
]
/// Only swapped in the trailing closure form, where the argument labels cannot differ.
private let closureSwaps: [String: String] = ["allSatisfy": "contains", "contains": "allSatisfy"]

private let methodExpression: Mutator = { node, ctx in
    guard let call = node.as(FunctionCallExprSyntax.self) else { return [] }
    if let ref = call.calledExpression.as(DeclReferenceExprSyntax.self), let to = ["min": "max", "max": "min"][ref.baseName.text] {
        return [Candidate(mutator: .methodExpression, span: ref.baseName.span, replacement: to, anchor: node)]
    }
    guard let member = call.calledExpression.as(MemberAccessExprSyntax.self), let base = member.base else { return [] }
    let name = member.declName.baseName
    if methodRemovals.contains(name.text) { return [whole(node, .methodExpression, ctx.text(base))] }
    let trailingOnly = call.arguments.isEmpty && call.leftParen == nil && call.trailingClosure != nil
    guard let to = methodSwaps[name.text] ?? (trailingOnly ? closureSwaps[name.text] : nil) else { return [] }
    return [Candidate(mutator: .methodExpression, span: name.span, replacement: to, anchor: node)]
}

/// `a?.b` -> `a!.b`: traps where the original yields nil. Placement climbs the postfix chain, so
/// the switch wraps the whole chain, whose optional type the forced form is promoted to.
private let optionalChaining: Mutator = { node, _ in
    guard let chain = node.as(OptionalChainingExprSyntax.self) else { return [] }
    return [Candidate(mutator: .optionalChaining, span: chain.questionMark.span, replacement: "!", anchor: node)]
}

// ---- regex -------------------------------------------------------------------

private func rawStringLiteral(_ value: String) -> String {
    var pounds = "#"
    while value.contains("\"" + pounds) { pounds += "#" }
    return "\(pounds)\"\(value)\"\(pounds)"
}

private let regex: Mutator = { node, _ in
    if let literal = node.as(RegexLiteralExprSyntax.self) {
        // Extended `#/.../#` literals allow whitespace and comments the tokenizer does not know.
        guard literal.openingPounds == nil else { return [] }
        return regexMutations(literal.regex.text).map { whole(node, .regex, "/\($0)/") }
    }
    guard let call = node.as(FunctionCallExprSyntax.self), let callee = call.calledExpression.as(DeclReferenceExprSyntax.self) else { return [] }
    let label: String? = switch callee.baseName.text {
    case "Regex": nil
    case "NSRegularExpression": "pattern"
    default: "-"
    }
    guard label != "-", let argument = call.arguments.first, argument.label?.text == label,
          let string = argument.expression.as(StringLiteralExprSyntax.self), let pattern = string.representedLiteralValue else { return [] }
    let anchor = Syntax(argument.expression)
    return regexMutations(pattern).map { Candidate(mutator: .regex, span: string.span, replacement: rawStringLiteral($0), anchor: anchor) }
}

// ---- FnValue (cargo-mutants): replace a function body by a value of its declared return type ----

private let signedNumbers: Set<String> = ["Int", "Int8", "Int16", "Int32", "Int64", "Double", "Float", "Float80", "CGFloat", "Decimal"]
private let unsignedNumbers: Set<String> = ["UInt", "UInt8", "UInt16", "UInt32", "UInt64"]

/// Swift expressions inhabiting a type, derived syntactically. Unknown types yield nothing.
private func typeValues(_ type: TypeSyntax) -> [String] {
    if let optional = type.as(OptionalTypeSyntax.self) { return unique(["nil"] + typeValues(optional.wrappedType)) }
    if type.is(ArrayTypeSyntax.self) { return ["[]"] }
    if type.is(DictionaryTypeSyntax.self) { return ["[:]"] }
    let name: String? = if let identifier = type.as(IdentifierTypeSyntax.self) {
        identifier.name.text
    } else if let member = type.as(MemberTypeSyntax.self), member.baseType.trimmedDescription == "Swift" {
        member.name.text
    } else {
        nil
    }
    guard let name else { return [] }
    let arguments = type.as(IdentifierTypeSyntax.self)?.genericArgumentClause?.arguments
    switch name {
    case "Bool": return ["true", "false"]
    case "String": return ["\"\"", "\"xyzzy\""]
    case "Array", "Set": return ["[]"]
    case "Dictionary": return ["[:]"]
    case "Optional":
        guard case let .type(wrapped)? = arguments?.first?.argument else { return ["nil"] }
        return unique(["nil"] + typeValues(wrapped))
    default:
        if signedNumbers.contains(name) { return ["0", "1", "-1"] }
        if unsignedNumbers.contains(name) { return ["0", "1"] }
        return []
    }
}

private func unique(_ values: [String]) -> [String] {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }
}

private func sameValue(_ expr: ExprSyntax, _ value: String) -> Bool {
    unwrapParens(expr).trimmedDescription.filter { !$0.isWhitespace } == value.filter { !$0.isWhitespace }
}

/// The expression a body returns when it is its only statement (`{ x }` or `{ return x }`).
private func onlyReturnedValue(_ body: CodeBlockSyntax) -> ExprSyntax? {
    guard body.statements.count == 1, let item = body.statements.first?.item else { return nil }
    if case let .expr(expr) = item { return expr }
    if case let .stmt(stmt) = item { return stmt.as(ReturnStmtSyntax.self)?.expression }
    return nil
}

private let fnValue: Mutator = { node, _ in
    guard let function = node.as(FunctionDeclSyntax.self), let body = function.body, let returnType = function.signature.returnClause?.type else { return [] }
    let only = onlyReturnedValue(body)
    return typeValues(returnType)
        .filter { value in only.map { !sameValue($0, value) } ?? true }
        .map { Candidate(mutator: .fnValue, span: body.span, replacement: "{ return \($0) }", anchor: Syntax(body)) }
}

let mutators: [Mutator] = [
    arithmeticOperator,
    arrayDeclaration,
    assignmentOperator,
    blockStatement,
    booleanLiteral,
    callExpression,
    conditionalExpression,
    dictionaryLiteral,
    equalityOperator,
    logicalOperator,
    methodExpression,
    optionalChaining,
    regex,
    stringLiteral,
    unaryOperator,
    fnValue,
]
