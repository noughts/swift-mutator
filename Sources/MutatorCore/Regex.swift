// Small, dependency free regex pattern mutator (a subset of weapon-regex level 1).
// The pattern is tokenized just enough to know which characters are anchors,
// quantifiers, predefined classes and character classes; escapes and the inside
// of character classes are never edited (except for the class negation itself).

private struct Edit {
    let start: Int
    let end: Int
    let text: String
}

private let predefined: [Character: Character] = ["d": "D", "D": "d", "w": "W", "W": "w", "s": "S", "S": "s"]

/// `{n}`, `{n,}`, `{n,m}` at `i`: (length, n, hasComma).
private func braceQuantifier(_ chars: [Character], at i: Int) -> (Int, String, Bool)? {
    guard i < chars.count, chars[i] == "{" else { return nil }
    var j = i + 1
    var digits = ""
    while j < chars.count, chars[j].isASCII, chars[j].isNumber {
        digits.append(chars[j])
        j += 1
    }
    guard !digits.isEmpty, j < chars.count else { return nil }
    var comma = false
    if chars[j] == "," {
        comma = true
        j += 1
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
    }
    guard j < chars.count, chars[j] == "}" else { return nil }
    return (j + 1 - i, digits, comma)
}

private func collectEdits(_ chars: [Character]) -> [Edit] {
    var edits: [Edit] = []
    let n = chars.count
    /// Whether the previous token can take a quantifier.
    var atom = false
    var i = 0
    func skip(to close: Character) {
        var j = i
        while j < n, chars[j] != close { j += 1 }
        i = j < n ? j + 1 : n
    }
    while i < n {
        let c = chars[i]
        if c == "\\" {
            let start = i
            let next: Character? = i + 1 < n ? chars[i + 1] : nil
            i += 2
            if let next, "pPku".contains(next), i < n, chars[i] == "{" || chars[i] == "<" {
                skip(to: chars[i] == "{" ? "}" : ">")
            } else if let next, let to = predefined[next] {
                edits.append(Edit(start: start + 1, end: start + 2, text: String(to)))
            }
            atom = true
            continue
        }
        if c == "[" {
            let start = i
            i += 1
            let negated = i < n && chars[i] == "^"
            var depth = 1
            while i < n, depth > 0 {
                if chars[i] == "\\" {
                    i += 2
                    continue
                }
                if chars[i] == "]" { depth -= 1 }
                i += 1
            }
            edits.append(negated ? Edit(start: start + 1, end: start + 2, text: "") : Edit(start: start + 1, end: start + 1, text: "^"))
            atom = true
            continue
        }
        if c == "(" {
            i += 1
            if i < n, chars[i] == "?" {
                i += 1
                let kind: Character? = i < n ? chars[i] : nil
                let after: Character? = i + 1 < n ? chars[i + 1] : nil
                if kind == "<", after != "=", after != "!" {
                    skip(to: ">")
                } else if kind == "<" {
                    i += 2
                } else if kind == ":" || kind == "=" || kind == "!" {
                    i += 1
                } else {
                    skip(to: ":") // modifiers: (?i:...)
                }
            }
            atom = false
            continue
        }
        if c == ")" {
            i += 1
            atom = true
            continue
        }
        if c == "^" || c == "$" {
            edits.append(Edit(start: i, end: i + 1, text: ""))
            i += 1
            atom = false
            continue
        }
        if c == "|" {
            i += 1
            atom = false
            continue
        }
        if c == "*" || c == "+" || c == "?" {
            let start = i
            i += 1
            if i < n, chars[i] == "?" { i += 1 }
            if atom { edits.append(Edit(start: start, end: i, text: "")) }
            atom = false
            continue
        }
        if c == "{", atom, let (length, digits, comma) = braceQuantifier(chars, at: i) {
            if comma { edits.append(Edit(start: i, end: i + length, text: "{\(digits)}")) }
            i += length
            if i < n, chars[i] == "?" { i += 1 }
            atom = false
            continue
        }
        i += 1
        atom = true
    }
    return edits
}

private func isValidRegex(_ pattern: String) -> Bool {
    (try? Regex(pattern)) != nil
}

/// Mutated variants of `pattern`; every result is a valid regex, non-empty, and differs from the input.
public func regexMutations(_ pattern: String) -> [String] {
    let chars = Array(pattern)
    var out: [String] = []
    for edit in collectEdits(chars) {
        let mutated = String(chars[..<edit.start]) + edit.text + String(chars[edit.end...])
        if mutated.isEmpty || mutated == pattern || out.contains(mutated) || !isValidRegex(mutated) { continue }
        out.append(mutated)
    }
    return out
}
