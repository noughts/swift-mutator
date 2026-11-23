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
    unwrap(expr).is(StringLiteralExprSyntax.self)
}

private func isCollectionLiteral(_ expr: ExprSyntax) -> Bool {
    let inner = unwrap(expr)
    return inner.is(ArrayExprSyntax.self) || inner.is(DictionaryExprSyntax.self)
}

// ---- operators -------------------------------------------------------------

private let arithmetic: [String: String] = ["+": "-", "-": "+", "*": "/", "/": "*", "%": "*", "&+": "&-", "&-": "&+"]

private let arithmeticOperator: Mutator = { node, ctx in
    guard let (infix, token) = infixOperator(node), let to = arithmetic[token.text] else { return [] }
    if token.text == "+" || token.text == "&+" {
        // `"a" + b` and `xs + [x]` concatenate: `-` does not type-check there.
        let left = unwrap(infix.leftOperand)
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

/// Whether `node` itself is the condition of an if / guard / while / repeat / ternary: its value
/// is only used for its truth.
private func testPosition(_ node: Syntax) -> TestPosition? {
    if node.isKeyPath(\TernaryExprSyntax.condition) { return .branch(first: true) }
    if node.isKeyPath(\RepeatStmtSyntax.condition) { return .loop(first: true) }
    guard node.isKeyPath(\ConditionElementSyntax.condition), let element = node.parent?.as(ConditionElementSyntax.self),
          let list = element.parent?.as(ConditionElementListSyntax.self), let owner = list.parent else { return nil }
    let first = list.first { if case .expression = $0.condition { true } else { false } }?.id == element.id
    if owner.is(WhileStmtSyntax.self) { return .loop(first: first) }
    if owner.is(IfExprSyntax.self) || owner.is(GuardStmtSyntax.self) { return .branch(first: first) }
    return nil
}

/// `if let a, let b` -> `if let a, let b, false`: a condition list without a boolean condition has
/// no expression to replace, so a `false` is appended (the `true` direction has no type-free spelling).
private func bindingsOnly(_ list: ConditionElementListSyntax, _ ctx: MutatorContext) -> [Candidate] {
    guard let owner = list.parent,
          owner.is(IfExprSyntax.self) || owner.is(GuardStmtSyntax.self) || owner.is(WhileStmtSyntax.self),
          list.allSatisfy({ element in
              switch element.condition {
              case .optionalBinding, .matchingPattern: true
              default: false
              }
          }) else { return [] }
    return [whole(Syntax(list), .conditionalExpression, ctx.text(list) + ", false")]
}

private let conditionalExpression: Mutator = { node, ctx in
    if let list = node.as(ConditionElementListSyntax.self) { return bindingsOnly(list, ctx) }
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
    // Inside parentheses or a cast in a condition, the condition itself already produced these.
    let position = outermost(node)
    if testPosition(position) != nil { return [] }
    // `a || <x>` with x=true / `a && <x>` with x=false collapse to mutants of the parent.
    let outer = position.parent.flatMap(infixOperator)?.1.text
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
    case .ifExpr: return !isValueBranching(owner) && !breaksFlow(block, owner: owner)
    case .whileStmt, .forStmt, .repeatStmt, .doStmt, .catchClause, .deferStmt: return !breaksFlow(block, owner: owner)
    case .deinitializerDecl: return true
    case .functionDecl: return isVoid(owner.as(FunctionDeclSyntax.self)?.signature.returnClause)
    case .accessorDecl: return ["set", "willSet", "didSet"].contains(owner.as(AccessorDeclSyntax.self)?.accessorSpecifier.text ?? "")
    default: return false
    }
}

/// Emptying the block leaves a path that returns no value, or a value used uninitialized: the
/// mutant does not compile. Swift checks this only once the module type-checks, so leaving it to
/// the compiler costs a build round of its own.
private func breaksFlow(_ block: CodeBlockSyntax, owner: Syntax) -> Bool {
    let function = sequence(first: owner) { $0.parent }.first(where: isFunctionLike)
    let uninitialized = Set(localNodes(function ?? owner.root).compactMap(uninitializedName))
    // A branch that exits keeps a later use from seeing a value its siblings initialize.
    let completes = owner.is(DoStmtSyntax.self) || owner.is(CatchClauseSyntax.self) || owner.as(IfExprSyntax.self)?.elseBody != nil
    if completes, alwaysExits(block), endsValueBody(owner) || !uninitialized.isEmpty { return true }
    let assigned = Set(localNodes(Syntax(block)).compactMap(assignedName))
    if assigned.isEmpty { return false }
    // An initializer must set every stored property, with or without `self.`.
    if function?.is(InitializerDeclSyntax.self) == true { return true }
    return !assigned.isDisjoint(with: uninitialized)
}

/// The block ends in `return` or `throw`, or in an `if` / `else` whose branches all do.
private func alwaysExits(_ block: CodeBlockSyntax) -> Bool {
    guard let last = block.statements.last?.item else { return false }
    if last.is(ReturnStmtSyntax.self) || last.is(ThrowStmtSyntax.self) { return true }
    guard let ifExpr = last.as(ExpressionStmtSyntax.self)?.expression.as(IfExprSyntax.self) else { return false }
    return ifAlwaysExits(ifExpr)
}

private func ifAlwaysExits(_ ifExpr: IfExprSyntax) -> Bool {
    guard alwaysExits(ifExpr.body), let elseBody = ifExpr.elseBody else { return false }
    switch elseBody {
    case let .codeBlock(block): return alwaysExits(block)
    case let .ifExpr(nested): return ifAlwaysExits(nested)
    }
}

/// `statement` (an `if`, `do` or `catch`) is the last thing a body that must not fall through runs
/// (it returns a value, or is a `guard` body), so every path through it must exit. When the body is
/// not recognized, true: a mutant that does not compile costs a build round and its function's
/// other mutants, a mutant not made costs only itself.
private func endsValueBody(_ statement: Syntax) -> Bool {
    // An `else if` ends where its `if` does, a `catch` where its `do` does.
    if let parent = statement.parent, parent.is(IfExprSyntax.self) { return endsValueBody(parent) }
    if statement.is(CatchClauseSyntax.self), let doStmt = statement.parent?.parent { return endsValueBody(doStmt) }
    guard let item = statement.parent?.as(CodeBlockItemSyntax.self) ?? statement.parent?.parent?.as(CodeBlockItemSyntax.self),
          let list = item.parent?.as(CodeBlockItemListSyntax.self), let body = list.parent else { return true }
    if list.last?.id != item.id || body.is(SourceFileSyntax.self) { return false }
    // A closure's return type is not known here: it may return a value.
    if body.is(ClosureExprSyntax.self) || returnsValue(body) { return true }
    // A `case` ends where its `switch` does.
    if body.is(SwitchCaseSyntax.self), let switchExpr = body.parent?.parent { return endsValueBody(switchExpr) }
    guard body.is(CodeBlockSyntax.self), let owner = body.parent else { return true }
    switch owner.kind {
    case .ifExpr, .doStmt, .catchClause: return endsValueBody(owner)
    case .functionDecl, .initializerDecl, .deinitializerDecl, .accessorDecl, .whileStmt, .forStmt, .repeatStmt, .deferStmt: return false
    default: return true
    }
}

/// Nodes under `node` outside nested closures and functions, where its locals are not.
private func localNodes(_ node: Syntax) -> [Syntax] {
    node.children(viewMode: .sourceAccurate).filter { !isFunctionLike($0) }.flatMap { [$0] + localNodes($0) }
}

/// `x` of `x = ...` and `self.x = ...`.
private func assignedName(_ node: Syntax) -> String? {
    guard let infix = node.as(InfixOperatorExprSyntax.self), infix.operator.is(AssignmentExprSyntax.self) else { return nil }
    if let name = infix.leftOperand.as(DeclReferenceExprSyntax.self)?.baseName.text { return name }
    guard let member = infix.leftOperand.as(MemberAccessExprSyntax.self), member.base?.as(DeclReferenceExprSyntax.self)?.baseName.text == "self" else { return nil }
    return member.declName.baseName.text
}

/// `x` of `let x: Int` / `var x: Int`, declared without a value.
private func uninitializedName(_ node: Syntax) -> String? {
    guard let binding = node.as(PatternBindingSyntax.self), binding.initializer == nil, binding.accessorBlock == nil else { return nil }
    return binding.pattern.as(IdentifierPatternSyntax.self)?.identifier.text
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
    if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.count == 1, let only = tuple.elements.first, only.firstName == nil {
        return typeValues(only.type)
    }
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
    unwrap(expr).trimmedDescription.filter { !$0.isWhitespace } == value.filter { !$0.isWhitespace }
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
