// Source text helpers over UTF-8 bytes: spans, line positions, slicing.

/// Overlap of half-open spans; an empty span is a point and touches a span at either edge.
public func intersects(_ a: Span, _ b: Span) -> Bool {
    if a.start == a.end { return b.start <= a.start && a.start <= b.end }
    if b.start == b.end { return a.start <= b.start && b.start <= a.end }
    return a.start < b.end && b.start < a.end
}

/// Offsets of the first byte of each line (`\n` separated).
public struct LineIndex: Sendable {
    public let starts: [Int]
    public let count: Int

    public init(_ bytes: [UInt8]) {
        var starts = [0]
        for (i, byte) in bytes.enumerated() where byte == UInt8(ascii: "\n") {
            starts.append(i + 1)
        }
        self.starts = starts
        count = bytes.count
    }

    /// 1-based line and 0-based column of `offset`.
    public func position(_ offset: Int) -> Position {
        var lo = 0
        var hi = starts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if starts[mid] <= offset { lo = mid } else { hi = mid - 1 }
        }
        return Position(line: lo + 1, column: offset - starts[lo])
    }

    public func location(_ span: Span) -> Location {
        Location(start: position(span.start), end: position(span.end))
    }

    /// Offset of a 1-based line and 0-based column, clamped to the text.
    public func offset(line: Int, column: Int) -> Int {
        guard line >= 1 else { return 0 }
        guard line <= starts.count else { return count }
        return min(starts[line - 1] + max(column, 0), count)
    }
}

public extension Array where Element == UInt8 {
    func text(_ span: Span) -> String {
        String(decoding: self[Swift.max(span.start, 0) ..< Swift.min(span.end, count)], as: UTF8.self)
    }
}

/// `text` with the regex metacharacters escaped.
public func escapeRegex(_ text: String) -> String {
    let special = Set("\\^$.|?*+()[]{}/")
    return text.map { special.contains($0) ? "\\\($0)" : String($0) }.joined()
}
