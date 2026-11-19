// Unified diff parsing and diff-scoped mutant selection. Pure: callers supply diff text and sources.

public struct DiffHunk: Hashable, Sendable {
    public let oldStart: Int
    public let oldLines: Int
    public let newStart: Int
    public let newLines: Int
    /// Raw lines with their ' ' / '+' / '-' prefix. "\ No newline" markers are dropped.
    public var lines: [String]
}

public struct FileDiff: Hashable, Sendable {
    /// nil = /dev/null
    public let oldPath: String?
    public let newPath: String?
    public let hunks: [DiffHunk]
    public let binary: Bool
}

public enum SelectMode: String, Sendable {
    /// Mutants whose own span intersects the diff.
    case node
    /// Mutants whose enclosing scope intersects the diff (catches signature changes).
    case scope
}

private let devNull = "/dev/null"

private struct RawFile {
    var header: (String, String)?
    var minus: String?
    var plus: String?
    var renameFrom: String?
    var renameTo: String?
    var binaryPaths: (String, String)?
    var created = false
    var deleted = false
    var binary = false
    var hunks: [DiffHunk] = []
}

public func parseUnifiedDiff(_ text: String) -> [FileDiff] {
    // `\r\n` is a single Character in Swift, so it is a separator of its own.
    let lines = text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }.map(String.init)
    var raws: [RawFile] = []
    var i = 0
    while i < lines.count {
        let line = lines[i]
        if line.hasPrefix("diff --git ") {
            raws.append(RawFile(header: splitGitHeader(String(line.dropFirst("diff --git ".count)))))
        } else if line.hasPrefix("--- "), i + 1 < lines.count, lines[i + 1].hasPrefix("+++ ") {
            if raws.isEmpty || raws[raws.count - 1].minus != nil || !raws[raws.count - 1].hunks.isEmpty {
                raws.append(RawFile())
            }
            raws[raws.count - 1].minus = headerPath(String(line.dropFirst(4)))
            raws[raws.count - 1].plus = headerPath(String(lines[i + 1].dropFirst(4)))
            i += 2
            continue
        } else if !raws.isEmpty {
            if let header = parseHunkHeader(line) {
                let (hunk, next) = readHunk(lines, from: i + 1, header: header)
                raws[raws.count - 1].hunks.append(hunk)
                i = next
                continue
            }
            readExtendedHeader(line, into: &raws[raws.count - 1])
        }
        i += 1
    }
    return raws.map(toFileDiff)
}

/// `@@ -a,b +c,d @@`: (oldStart, oldLines, newStart, newLines); omitted counts are 1.
private func parseHunkHeader(_ line: String) -> (Int, Int, Int, Int)? {
    guard let match = line.firstMatch(of: /^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@/) else { return nil }
    let number = { (s: Substring?) in s.flatMap { Int($0) } ?? 1 }
    return (number(match.1), number(match.2), number(match.3), number(match.4))
}

private func readHunk(_ lines: [String], from: Int, header: (Int, Int, Int, Int)) -> (DiffHunk, Int) {
    var hunk = DiffHunk(oldStart: header.0, oldLines: header.1, newStart: header.2, newLines: header.3, lines: [])
    var oldLeft = hunk.oldLines
    var newLeft = hunk.newLines
    var i = from
    while i < lines.count {
        let line = lines[i]
        if line.hasPrefix("\\") {
            i += 1
            continue
        }
        if oldLeft <= 0, newLeft <= 0 { break }
        if line.isEmpty, i == lines.count - 1 { break }
        let kind = line.first ?? " "
        if kind == " " {
            oldLeft -= 1
            newLeft -= 1
            hunk.lines.append(line.isEmpty ? " " : line)
        } else if kind == "-" {
            oldLeft -= 1
            hunk.lines.append(line)
        } else if kind == "+" {
            newLeft -= 1
            hunk.lines.append(line)
        } else {
            break
        }
        i += 1
    }
    return (hunk, i)
}

private func readExtendedHeader(_ line: String, into raw: inout RawFile) {
    if line.hasPrefix("rename from ") {
        raw.renameFrom = unquote(String(line.dropFirst("rename from ".count)))
    } else if line.hasPrefix("rename to ") {
        raw.renameTo = unquote(String(line.dropFirst("rename to ".count)))
    } else if line.hasPrefix("new file mode ") {
        raw.created = true
    } else if line.hasPrefix("deleted file mode ") {
        raw.deleted = true
    } else if line.hasPrefix("Binary files ") || line == "GIT binary patch" {
        raw.binary = true
        if let match = line.firstMatch(of: /^Binary files (.*) and (.*) differ$/) {
            raw.binaryPaths = (unquote(String(match.1)), unquote(String(match.2)))
        }
    }
}

private func toFileDiff(_ raw: RawFile) -> FileDiff {
    let renamed: (String, String)? = if let from = raw.renameFrom, let to = raw.renameTo { (from, to) } else { nil }
    let named: (String, String)? = if let minus = raw.minus, let plus = raw.plus { (minus, plus) } else { raw.binaryPaths ?? raw.header }
    // Renames are written without prefixes.
    let prefixed = renamed == nil && named.map { hasPrefixes(raw.header ?? $0) } == true
    let (oldRaw, newRaw) = renamed ?? named ?? (devNull, devNull)
    let normalize = { (path: String) -> String? in
        if path == devNull { return nil }
        return prefixed ? stripMnemonicPrefix(path) : path
    }
    return FileDiff(
        oldPath: raw.created ? nil : normalize(oldRaw),
        newPath: raw.deleted ? nil : normalize(newRaw),
        hunks: raw.hunks,
        binary: raw.binary
    )
}

/// git's mnemonic prefixes (`a/`, `b/`, `c/`, `i/`, `w/`, `o/`), absent with `--no-prefix`.
private func hasMnemonicPrefix(_ path: String) -> Bool {
    path.wholeMatch(of: /[abciwo]\/.*/) != nil
}

private func stripMnemonicPrefix(_ path: String) -> String {
    hasMnemonicPrefix(path) ? String(path.dropFirst(2)) : path
}

/// Prefixes are stripped only when every non-/dev/null side carries one.
private func hasPrefixes(_ pair: (String, String)) -> Bool {
    let sides = [pair.0, pair.1].filter { $0 != devNull }
    return !sides.isEmpty && sides.allSatisfy(hasMnemonicPrefix)
}

private func headerPath(_ s: String) -> String {
    if s.hasPrefix("\"") { return unquote(s) }
    if let tab = s.firstIndex(of: "\t") { return String(s[..<tab]) }
    return s
}

/// Splits `a/x b/x`. Unquoted paths with spaces are resolved by assuming both sides name the same file.
private func splitGitHeader(_ rest: String) -> (String, String)? {
    let chars = Array(rest)
    if rest.hasPrefix("\"") {
        let end = quotedEnd(chars)
        let second = String(chars[end...]).drop { $0 == " " }
        return (unquote(String(chars[..<end])), unquote(String(second)))
    }
    if let quoted = rest.firstRange(of: " \"") {
        return (String(rest[..<quoted.lowerBound]), unquote(String(rest[rest.index(after: quoted.lowerBound)...])))
    }
    let spaces = chars.indices.filter { chars[$0] == " " }
    if spaces.count == 1 {
        return (String(chars[..<spaces[0]]), String(chars[(spaces[0] + 1)...]))
    }
    return spaces.lazy.map { (String(chars[..<$0]), String(chars[($0 + 1)...])) }.first { a, b in
        a == b || (hasPrefixes((a, b)) && stripMnemonicPrefix(a) == stripMnemonicPrefix(b))
    }
}

private func quotedEnd(_ chars: [Character]) -> Int {
    var i = 1
    while i < chars.count {
        if chars[i] == "\\" {
            i += 1
        } else if chars[i] == "\"" {
            return i + 1
        }
        i += 1
    }
    return chars.count
}

private let escapes: [Character: UInt8] = ["a": 7, "b": 8, "t": 9, "n": 10, "v": 11, "f": 12, "r": 13, "\"": 34, "\\": 92]

/// Decodes git's C-style quoted path (octal escapes are UTF-8 bytes). Unquoted input is returned as is.
private func unquote(_ s: String) -> String {
    guard s.hasPrefix("\"") else { return s }
    let chars = Array(s)
    let body = Array(chars[1 ..< max(1, quotedEnd(chars) - 1)])
    var bytes: [UInt8] = []
    var i = 0
    while i < body.count {
        let c = body[i]
        if c != "\\" {
            bytes.append(contentsOf: Array(String(c).utf8))
            i += 1
            continue
        }
        let digits = body[(i + 1)...].prefix(3)
        if digits.count == 3, digits.allSatisfy({ ("0" ... "7").contains($0) }), let value = UInt8(String(digits), radix: 8) {
            bytes.append(value)
            i += 4
        } else if i + 1 < body.count {
            let next = body[i + 1]
            bytes.append(escapes[next] ?? Array(String(next).utf8).first ?? 0)
            i += 2
        } else {
            i += 1
        }
    }
    return String(decoding: bytes, as: UTF8.self)
}

// ---- line analysis ----------------------------------------------------------

/// 1-based new-side line where the hunk's first line sits. A "+k,0" hunk lies after line k.
private func firstNewLine(_ hunk: DiffHunk) -> Int {
    hunk.newLines == 0 ? hunk.newStart + 1 : hunk.newStart
}

/// Mirrors cargo-mutants `affected_lines`: '+' lines are changed; a '-' marks the new-side line
/// before it, and the "after delete" flag is cleared only by the next context line, which is also marked.
public func changedLines(_ file: FileDiff) -> [Int] {
    var out = Set<Int>()
    for hunk in file.hunks {
        var lineno = firstNewLine(hunk)
        var afterDelete = false
        for line in hunk.lines {
            let kind = line.first
            if kind == "-" {
                if lineno - 1 >= 1 { out.insert(lineno - 1) }
                afterDelete = true
                continue
            }
            if kind == "+" || afterDelete { out.insert(lineno) }
            if kind == " " { afterDelete = false }
            lineno += 1
        }
    }
    return out.sorted()
}

/// Byte spans of the given 1-based lines, adjacent lines merged.
public func lineSpans(_ source: [UInt8], lines: [Int]) -> [Span] {
    let index = LineIndex(source)
    let starts = index.starts
    let lineEnd = { (n: Int) -> Int in
        guard n < starts.count else { return source.count }
        let next = starts[n]
        return next >= 2 && source[next - 2] == UInt8(ascii: "\r") ? next - 2 : next - 1
    }
    let wanted = Set(lines).filter { $0 >= 1 && $0 <= starts.count }.sorted()
    var out: [Span] = []
    var previous = -1
    for n in wanted {
        if !out.isEmpty, n == previous + 1 {
            out[out.count - 1].end = lineEnd(n)
        } else {
            out.append(Span(start: starts[n - 1], end: lineEnd(n)))
        }
        previous = n
    }
    return out
}

// ---- selection --------------------------------------------------------------

/// Mutants intersecting the changed spans of their file.
public func selectMutants(_ mutants: [Mutant], changed: [String: [Span]], mode: SelectMode) -> [Mutant] {
    mutants.filter { mutant in
        guard let spans = changed[mutant.file] else { return false }
        let target = mode == .scope ? mutant.scope.span : mutant.span
        return spans.contains { intersects($0, target) }
    }
}
