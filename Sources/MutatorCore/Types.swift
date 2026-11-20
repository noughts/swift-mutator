// Contract layer: plain data shared by the instrumenter, the planner and the CLI.

/// UTF-8 byte offsets into a source file; `end` is exclusive.
public struct Span: Hashable, Sendable {
    public var start: Int
    public var end: Int

    public init(start: Int, end: Int) {
        self.start = start
        self.end = end
    }

    public func contains(_ other: Span) -> Bool { start <= other.start && other.end <= end }
    public func contains(offset: Int) -> Bool { start <= offset && offset < end }
}

/// 1-based line, 0-based UTF-8 column.
public struct Position: Hashable, Sendable {
    public let line: Int
    public let column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }
}

public struct Location: Hashable, Sendable {
    public let start: Position
    public let end: Position

    public init(start: Position, end: Position) {
        self.start = start
        self.end = end
    }
}

public enum MutatorName: String, CaseIterable, Sendable {
    case arithmeticOperator = "ArithmeticOperator"
    case arrayDeclaration = "ArrayDeclaration"
    case assignmentOperator = "AssignmentOperator"
    case blockStatement = "BlockStatement"
    case booleanLiteral = "BooleanLiteral"
    case callExpression = "CallExpression"
    case conditionalExpression = "ConditionalExpression"
    case dictionaryLiteral = "DictionaryLiteral"
    case equalityOperator = "EqualityOperator"
    case fnValue = "FnValue"
    case logicalOperator = "LogicalOperator"
    case methodExpression = "MethodExpression"
    case optionalChaining = "OptionalChaining"
    case regex = "Regex"
    case stringLiteral = "StringLiteral"
    case unaryOperator = "UnaryOperator"
}

/// The enclosing unit used for identity and cache invalidation.
public struct Scope: Hashable, Sendable {
    /// Position independent path, e.g. `Cart.total(for:)>map` or `<top:3f2a1b>`.
    public let id: String
    /// Hash of the scope's tokens (comments and whitespace dropped, nested scopes as holes).
    public let hash: String
    public let span: Span
    public enum Kind: Sendable {
        /// Function, initializer, accessor, closure.
        case function
        /// Type or global.
        case declaration
        /// Adds members and conformances to a type declared elsewhere.
        case `extension`
    }

    public let kind: Kind

    public var isFunction: Bool { kind == .function }

    public init(id: String, hash: String, span: Span, kind: Kind) {
        self.id = id
        self.hash = hash
        self.span = span
        self.kind = kind
    }

    public func key(file: String) -> String { "\(file)#\(id)" }
}

public struct Mutant: Hashable, Sendable {
    /// Position independent identity: hash(file, scope.id, astPath, mutator, replacement).
    public let key: String
    /// Path relative to the package root.
    public let file: String
    public let mutator: MutatorName
    /// Region of the original source that is replaced.
    public let span: Span
    public let location: Location
    public let original: String
    public let replacement: String
    public let scope: Scope
    /// Set when the mutant is reported but never placed (disable comment, arid, unplaceable).
    public var ignored: String?

    public init(key: String, file: String, mutator: MutatorName, span: Span, location: Location, original: String, replacement: String, scope: Scope, ignored: String? = nil) {
        self.key = key
        self.file = file
        self.mutator = mutator
        self.span = span
        self.location = location
        self.original = original
        self.replacement = replacement
        self.scope = scope
        self.ignored = ignored
    }
}

public enum MutantStatus: String, Codable, Sendable {
    case killed = "Killed"
    case survived = "Survived"
    case noCoverage = "NoCoverage"
    case timeout = "Timeout"
    case ignored = "Ignored"
    /// Does not compile; never run, excluded from the score.
    case compileError = "CompileError"
    /// Needed a run but was not run (outside `--since`); never reused.
    case pending = "Pending"

    public var isDetected: Bool { self == .killed || self == .timeout }
    public var isUndetected: Bool { self == .survived || self == .noCoverage }
}

public struct MutantResult: Codable, Hashable, Sendable {
    public let key: String
    public let file: String
    public let scopeId: String
    public let scopeHash: String
    public let status: MutantStatus
    /// Tests that failed with this mutant active.
    public let killedBy: [String]
    /// Tests that reached this mutant in the dry run.
    public let coveredBy: [String]
    public let durationMs: Int?

    /// `file#scopeId`, as `Scope.key(file:)`.
    public var scopeKey: String { "\(file)#\(scopeId)" }

    public init(mutant: Mutant, status: MutantStatus, killedBy: [String], coveredBy: [String], durationMs: Int? = nil) {
        key = mutant.key
        file = mutant.file
        scopeId = mutant.scope.id
        scopeHash = mutant.scope.hash
        self.status = status
        self.killedBy = killedBy
        self.coveredBy = coveredBy
        self.durationMs = durationMs
    }
}

public struct TestInfo: Codable, Hashable, Sendable {
    public let id: String
    /// Changes whenever the test or the test code it shares changes.
    public let fingerprint: String
    public let durationMs: Int

    public init(id: String, fingerprint: String, durationMs: Int) {
        self.id = id
        self.fingerprint = fingerprint
        self.durationMs = durationMs
    }
}

/// Persisted outcome of a previous run: the cache the planners reuse.
public struct Snapshot: Codable, Sendable {
    public let toolVersion: String
    /// Hash of the manifest, resolved dependencies, compiler version and mutation options.
    public let envHash: String
    public let results: [MutantResult]
    public let tests: [TestInfo]
    /// Test id -> keys of the mutants it reached in the dry run.
    public let coverage: [String: [String]]
    /// `file#scopeId` -> hash, for every scope of the mutated files.
    public let scopes: [String: String]
    /// `file#scopeId` of the declaration-level scopes (types, globals): a change there re-measures every test.
    public let declarationScopes: [String]

    public init(toolVersion: String, envHash: String, results: [MutantResult], tests: [TestInfo], coverage: [String: [String]], scopes: [String: String], declarationScopes: [String]) {
        self.toolVersion = toolVersion
        self.envHash = envHash
        self.results = results
        self.tests = tests
        self.coverage = coverage
        self.scopes = scopes
        self.declarationScopes = declarationScopes
    }

    /// The snapshot when it was written by this tool version under the same environment.
    public func valid(toolVersion: String, envHash: String) -> Snapshot? {
        self.toolVersion == toolVersion && self.envHash == envHash ? self : nil
    }
}
