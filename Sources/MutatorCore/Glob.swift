/// Glob match on `/`-separated relative paths: `**` spans directories, `*` and `?` do not.
public func globMatches(_ pattern: String, _ path: String) -> Bool {
    var regex = ""
    let chars = Array(pattern)
    var i = 0
    while i < chars.count {
        let c = chars[i]
        if c == "*", i + 1 < chars.count, chars[i + 1] == "*" {
            let slash = i + 2 < chars.count && chars[i + 2] == "/"
            regex += slash ? "(?:.*/)?" : ".*"
            i += slash ? 3 : 2
            continue
        }
        switch c {
        case "*": regex += "[^/]*"
        case "?": regex += "[^/]"
        default: regex += escapeRegex(String(c))
        }
        i += 1
    }
    guard let compiled = try? Regex(regex) else { return false }
    return path.wholeMatch(of: compiled) != nil
}
