import Foundation

// Side effects: child processes. Output goes to files (no pipe buffers to drain), and a run that
// exceeds its timeout is terminated, then killed.

struct ProcessResult: Sendable {
    let status: Int32
    let stdout: String
    let stderr: String
    let timedOut: Bool
    let durationMs: Int

    var output: String { stdout.isEmpty ? stderr : stderr.isEmpty ? stdout : stdout + "\n" + stderr }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

private final class ProcessBox: @unchecked Sendable {
    let process: Process
    init(_ process: Process) { self.process = process }
}

/// Runs `executable` (an absolute path, or a command name looked up through `/usr/bin/env`).
/// `merge` sends stderr to the same file as stdout, keeping their interleaving.
func runProcess(_ executable: String, _ arguments: [String], cwd: URL, environment: [String: String]? = nil, timeoutMs: Int? = nil, merge: Bool = false) async throws -> ProcessResult {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("swift-mutator-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: scratch) }
    let outURL = scratch.appendingPathComponent("stdout")
    let errURL = merge ? outURL : scratch.appendingPathComponent("stderr")
    FileManager.default.createFile(atPath: outURL.path, contents: nil)
    FileManager.default.createFile(atPath: errURL.path, contents: nil)
    let out = try FileHandle(forWritingTo: outURL)
    let err = merge ? out : try FileHandle(forWritingTo: errURL)
    defer {
        try? out.close()
        if !merge { try? err.close() }
    }

    let process = Process()
    if executable.hasPrefix("/") {
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
    } else {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [executable] + arguments
    }
    process.currentDirectoryURL = cwd
    if let environment { process.environment = environment }
    process.standardOutput = out
    process.standardError = err
    process.standardInput = FileHandle.nullDevice

    let box = ProcessBox(process)
    let timedOut = Flag()
    let started = DispatchTime.now()
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        process.terminationHandler = { _ in continuation.resume() }
        do {
            try process.run()
        } catch {
            process.terminationHandler = nil
            continuation.resume(throwing: error)
            return
        }
        if let timeoutMs {
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(timeoutMs)) {
                guard box.process.isRunning else { return }
                timedOut.set()
                box.process.terminate()
                let pid = box.process.processIdentifier
                DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                    if box.process.isRunning { kill(pid, SIGKILL) }
                }
            }
        }
    }
    let durationMs = Int((DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1_000_000)
    let read = { (url: URL) in (try? String(contentsOf: url, encoding: .utf8)) ?? String(decoding: (try? Data(contentsOf: url)) ?? Data(), as: UTF8.self) }
    return ProcessResult(status: process.terminationStatus, stdout: read(outURL), stderr: merge ? "" : read(errURL), timedOut: timedOut.isSet, durationMs: durationMs)
}

/// Runs `body` over `items` with at most `limit` running at once; results keep the input order.
func concurrentMap<T: Sendable, R: Sendable>(_ items: [T], limit: Int, _ body: @escaping @Sendable (T) async -> R) async -> [R] {
    await withTaskGroup(of: (Int, R).self) { group in
        var results = [R?](repeating: nil, count: items.count)
        var next = 0
        for _ in 0 ..< min(max(limit, 1), items.count) {
            let index = next
            group.addTask { (index, await body(items[index])) }
            next += 1
        }
        while let (index, result) = await group.next() {
            results[index] = result
            if next < items.count {
                let index = next
                group.addTask { (index, await body(items[index])) }
                next += 1
            }
        }
        return results.map { $0! }
    }
}

func log(_ message: String) {
    FileHandle.standardError.write(Data(("swift-mutator: " + message + "\n").utf8))
}
