import SwiftParser
import SwiftSyntax

// Test fingerprints: a test changes when its own function changes, when the type holding it
// changes elsewhere (setUp, helpers inside it), when the private helpers of its file change, or
// when the module's shared test code changes (other helper types and functions). Other tests,
// imports and new test types do not count.

public struct TestSource: Sendable {
    public let path: String
    public let text: String

    public init(path: String, text: String) {
        self.path = path
        self.text = text
    }
}

private struct TestFunction {
    /// `Type/name`, `Type/name(labels:)`: XCTest and swift-testing ids without the module.
    let keys: [String]
    let span: Span
    let hash: String
}

private func functions(in node: Syntax, types: [String] = []) -> [TestFunction] {
    let types = types + (typeDeclName(node).map { [$0] } ?? [])
    if let function = node.as(FunctionDeclSyntax.self) {
        let plain = function.name.text
        let labeled = plain + parameterLabels(function.signature.parameterClause.parameters)
        let prefix = types.isEmpty ? "" : types.joined(separator: "/") + "/"
        return [TestFunction(keys: [prefix + plain, prefix + labeled], span: function.span, hash: stableHash(normalizedTokens(node, holes: [])))]
    }
    return node.children(viewMode: .sourceAccurate).flatMap { functions(in: $0, types: types) }
}

/// `private` / `fileprivate` at the top level: visible in its own file only.
private func isFilePrivate(_ node: Syntax) -> Bool {
    node.asProtocol(WithModifiersSyntax.self)?.modifiers.contains { ["private", "fileprivate"].contains($0.name.text) } == true
}

/// Test id (`Module.Type/name`) -> fingerprint. `extra` adds per-module content (resources).
public func testFingerprints(ids: [String], modules: [String: [TestSource]], extra: [String: String] = [:]) -> [String: String] {
    var out: [String: String] = [:]
    let byModule = Dictionary(grouping: ids, by: testModule)
    for (module, moduleIds) in byModule {
        let rest = { (id: String) in String(id.dropFirst(module.count + 1)) }
        let wanted = Set(moduleIds.map(rest))
        var own: [String: String] = [:]
        var shells: [String: [String]] = [:]
        var shared: [String] = []
        /// File -> its private declarations, which only its own tests can use.
        var local: [String: [String]] = [:]
        var fileOf: [String: String] = [:]
        var whole: [String] = []
        for source in (modules[module] ?? []).sorted(by: { $0.path < $1.path }) {
            let tree = Parser.parse(source: source.text)
            whole.append(normalizedTokens(Syntax(tree), holes: []))
            for item in tree.statements {
                let node = Syntax(item.item)
                if node.is(ImportDeclSyntax.self) { continue }
                let tests = functions(in: node).filter { $0.keys.contains(where: wanted.contains) }
                for test in tests {
                    for key in test.keys where wanted.contains(key) {
                        own[key] = test.hash
                        fileOf[key] = source.path
                    }
                }
                // A test at the top level is only its own.
                if tests.contains(where: { $0.span == node.span }) { continue }
                // Tests are dropped, not marked: adding a test leaves the others alone.
                let text = normalizedTokens(node, holes: tests.map(\.span).sorted { $0.start < $1.start }, placeholder: nil)
                if text.isEmpty { continue }
                if let type = typeDeclName(node), !tests.isEmpty {
                    shells[type, default: []].append(text)
                } else if isFilePrivate(node) {
                    local[source.path, default: []].append(text)
                } else {
                    shared.append(text)
                }
            }
        }
        let sharedHash = stableHash(shared.joined(separator: "\0") + "\0" + (extra[module] ?? ""))
        let wholeHash = stableHash(whole.joined(separator: "\0"))
        let shellHashes = shells.mapValues { stableHash($0.joined(separator: "\0")) }
        let localHashes = local.mapValues { stableHash($0.joined(separator: "\0")) }
        for id in moduleIds {
            let key = rest(id)
            let container = key.contains("/") ? String(key.prefix { $0 != "/" }) : nil
            let shell = container.flatMap { shellHashes[$0] } ?? ""
            let fileLocal = fileOf[key].flatMap { localHashes[$0] } ?? ""
            out[id] = stableHash([sharedHash, shell, fileLocal, own[key] ?? "*" + wholeHash].joined(separator: "\0"))
        }
    }
    return out
}
