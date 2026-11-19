import Foundation

// Disable comments: `// mutator-disable-next-line [Names][: reason]`, `// mutator-disable-line`,
// `// mutator-disable` / `// mutator-enable` regions, and StrykerJS-compatible
// `// Stryker disable|restore [next-line] names[: reason]`.

public struct Comment: Hashable, Sendable {
    /// Text without the comment delimiters (`//`, `///`, `/*`, `*/`).
    public let value: String
    public let span: Span

    public init(value: String, span: Span) {
        self.value = value
        self.span = span
    }
}

private struct Directive {
    enum Kind { case disable, enable }
    enum Extent { case line, region }
    let kind: Kind
    /// nil = all mutators
    let mutators: Set<String>?
    let reason: String?
    let extent: Extent
    let line: Int
    let offset: Int
}

private func parseNames(_ text: Substring) -> Set<String>? {
    let names = text.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    return names.isEmpty || names.contains(where: { $0.lowercased() == "all" }) ? nil : Set(names)
}

private func trimmedReason(_ text: Substring?) -> String? {
    guard let trimmed = text?.trimmingCharacters(in: .whitespaces), !trimmed.isEmpty else { return nil }
    return trimmed
}

private func parse(_ comment: Comment, line lineOf: (Int) -> Int) -> Directive? {
    // Most comments are not directives: skip the regexes for them.
    guard comment.value.contains("mutator-") || comment.value.contains("Stryker ") else { return nil }
    let line = lineOf(comment.span.start)
    let nextLine = lineOf(comment.span.end) + 1
    let own = /^\s*\*?\s*mutator-(disable-next-line|disable-line|disable|enable)\b([^:]*)(?::\s*(.*))?$/.wordBoundaryKind(.simple)
    let stryker = /^\s*\*?\s*Stryker (disable|restore)(?: (next-line))? ([a-zA-Z, ]+?)\s*(?::\s*(.*))?$/
    let parsed: (kind: Directive.Kind, extent: Directive.Extent, line: Int, names: Substring, reason: Substring?)
    if let match = comment.value.firstMatch(of: own) {
        parsed = switch match.1 {
        case "disable-next-line": (.disable, .line, nextLine, match.2, match.3)
        case "disable-line": (.disable, .line, line, match.2, match.3)
        case "disable": (.disable, .region, line, match.2, match.3)
        default: (.enable, .region, line, match.2, match.3)
        }
    } else if let match = comment.value.firstMatch(of: stryker) {
        let disable = match.1 == "disable"
        parsed = disable && match.2 != nil ? (.disable, .line, nextLine, match.3, match.4) : (disable ? .disable : .enable, .region, line, match.3, match.4)
    } else {
        return nil
    }
    return Directive(kind: parsed.kind, mutators: parseNames(parsed.names), reason: trimmedReason(parsed.reason), extent: parsed.extent, line: parsed.line, offset: comment.span.end)
}

/// A lookup returning the ignore reason (`disabled` / `disabled: <reason>`) of a mutant, or nil when it is enabled.
public func disabledBy(_ comments: [Comment], line lineOf: @escaping (Int) -> Int) -> (MutatorName, Int) -> String? {
    let directives = comments.compactMap { parse($0, line: lineOf) }
    let regions = directives.filter { $0.extent == .region }.sorted { $0.offset < $1.offset }
    let lines = directives.filter { $0.extent == .line }
    let matches = { (d: Directive, mutator: MutatorName) in d.mutators == nil || d.mutators!.contains(mutator.rawValue) }
    let label = { (d: Directive) in d.reason.map { "disabled: \($0)" } ?? "disabled" }
    return { mutator, offset in
        let line = lineOf(offset)
        if let byLine = lines.first(where: { $0.line == line && matches($0, mutator) }) { return label(byLine) }
        var active: Directive?
        for d in regions {
            if d.offset > offset { break }
            if !matches(d, mutator) { continue }
            active = d.kind == .disable ? d : nil
        }
        return active.map(label)
    }
}
