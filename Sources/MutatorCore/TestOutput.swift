import Foundation

// Which tests failed in a run: from XCTest's console output and swift-testing's event stream.
// A test that started but never ended crashed the process.

/// Failed or crashed tests among `requested` (XCTest ids `Module.Class/method`), in requested order.
public func failedXCTests(output: String, requested: [String]) -> [String] {
    var started: [String] = []
    var ended = Set<String>()
    var failed = Set<String>()
    let pattern = /Test Case '(?:-\[(\S+) (\S+)\]|(\S+)\.(\S+))' (started|passed|failed)/
    for line in output.split(separator: "\n") {
        guard let match = line.firstMatch(of: pattern) else { continue }
        // macOS: `-[Module.Class method]`; Linux: `Class.method` without the module.
        let id = if let type = match.1, let method = match.2 { "\(type)/\(method)" } else { "\(match.3!)/\(match.4!)" }
        switch match.5 {
        case "started": started.append(id)
        case "failed":
            ended.insert(id)
            failed.insert(id)
        default: ended.insert(id)
        }
    }
    failed.formUnion(started.filter { !ended.contains($0) })
    return requested.filter { id in failed.contains(id) || failed.contains { id.hasSuffix(".\($0)") } }
}

private struct Event: Decodable {
    struct Payload: Decodable {
        struct Issue: Decodable { let isKnown: Bool? }
        let kind: String?
        let testID: String?
        let issue: Issue?
    }

    let kind: String
    let payload: Payload?
}

/// `Module.Suite/test()/File.swift:12:4` -> `Module.Suite/test()`.
public func swiftTestingId(_ eventId: String) -> String {
    guard let slash = eventId.lastIndex(of: "/"), eventId[slash...].contains(".swift:") else { return eventId }
    return String(eventId[..<slash])
}

/// Failed or crashed tests among `requested` from a swift-testing JSON Lines event stream.
public func failedSwiftTestingTests(eventStream: String, requested: [String]) -> [String] {
    var started: [String] = []
    var ended = Set<String>()
    var failed = Set<String>()
    let decoder = JSONDecoder()
    for line in eventStream.split(separator: "\n") where line.contains("\"testID\"") {
        guard let event = try? decoder.decode(Event.self, from: Data(line.utf8)), event.kind == "event",
              let payload = event.payload, let raw = payload.testID else { continue }
        let id = swiftTestingId(raw)
        switch payload.kind {
        case "testStarted": started.append(id)
        case "testEnded": ended.insert(id)
        case "issueRecorded": if payload.issue?.isKnown != true { failed.insert(id) }
        default: break
        }
    }
    failed.formUnion(started.filter { !ended.contains($0) && $0.contains("(") })
    return requested.filter(failed.contains)
}

/// swift-testing tests have a function name with parentheses; XCTest ids never do.
public func isSwiftTestingId(_ id: String) -> Bool { id.hasSuffix(")") }

/// `Module.Type/test` -> `Module`.
public func testModule(_ id: String) -> String { String(id.prefix { $0 != "." }) }

/// `swift test list` output -> test ids.
public func parseTestList(_ output: String) -> [String] {
    let id = /[A-Za-z_][A-Za-z0-9_]*\.\S+/
    return stripEscapes(output).split(separator: "\n").map(String.init).filter { $0.wholeMatch(of: id) != nil }
}

/// A `--filter` regex matching exactly one swift-testing id (event ids carry a `/File.swift:l:c` suffix).
public func swiftTestingFilter(_ id: String) -> String {
    "^" + escapeRegex(id) + "(?:/|$)"
}
