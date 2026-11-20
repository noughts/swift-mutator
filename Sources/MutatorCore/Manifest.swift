import SwiftParser
import SwiftSyntax

// The sandbox copy of a package lives elsewhere: local dependencies given by relative paths
// (`.package(path: "../Shared")`) are rewritten to absolute paths, and sources are compiled as if
// they were at their original path.

/// `code` compiled as the file at `path`: `#filePath` (tests finding fixtures next to them or up
/// the tree) and compiler diagnostics name the original file, with the original line numbers.
public func atOriginalPath(_ code: String, path: String) -> String {
    "#sourceLocation(file: \(quoted(path)), line: 1)\n" + code
}

/// `path` resolved against `base`, with `.` and `..` removed.
public func resolvePath(_ path: String, base: String) -> String {
    let joined = path.hasPrefix("/") ? path : base + "/" + path
    var parts: [Substring] = []
    for part in joined.split(separator: "/") {
        if part == "." || part.isEmpty { continue }
        if part == "..", !parts.isEmpty {
            parts.removeLast()
            continue
        }
        parts.append(part)
    }
    return "/" + parts.joined(separator: "/")
}

public func absolutizeLocalDependencies(manifest: String, packageRoot: String) -> String {
    let tree = Parser.parse(source: manifest)
    let bytes = Array(manifest.utf8)
    var edits: [(Span, String)] = []
    for token in tree.tokens(viewMode: .sourceAccurate) where token.text == "package" {
        guard let member = token.parent?.parent?.as(MemberAccessExprSyntax.self), member.base == nil,
              let call = member.parent?.as(FunctionCallExprSyntax.self) else { continue }
        for argument in call.arguments where argument.label?.text == "path" {
            guard let literal = argument.expression.as(StringLiteralExprSyntax.self), let value = literal.representedLiteralValue, !value.hasPrefix("/") else { continue }
            edits.append((literal.span, quoted(resolvePath(value, base: packageRoot))))
        }
    }
    var out = ""
    var at = 0
    for (span, text) in edits.sorted(by: { $0.0.start < $1.0.start }) {
        out += bytes.text(Span(start: at, end: span.start)) + text
        at = span.end
    }
    return out + bytes.text(Span(start: at, end: bytes.count))
}
