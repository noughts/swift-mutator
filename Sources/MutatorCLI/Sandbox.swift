import Foundation
import MutatorCore

// The sandbox is a copy of the package under `.mutator/sandbox` where instrumented sources
// replace the originals. It is kept between runs so `swift build` only recompiles what changed:
// files are written only when their content differs.

private let skippedDirectories: Set<String> = [".build", ".git", ".mutator", ".swiftpm", ".index-build", "DerivedData"]

/// Mirrors `root` into `sandbox`, with `overrides` (relative path -> content) replacing files.
func syncSandbox(root: URL, sandbox: URL, overrides: [String: String]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    var wanted = Set<String>()
    for rel in try listFiles(root) {
        wanted.insert(rel)
        let source = root.appendingPathComponent(rel)
        let target = sandbox.appendingPathComponent(rel)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text = overrides[rel] {
            try writeIfChanged(Data(text.utf8), to: target)
        } else if try needsCopy(source, target) {
            try writeIfChanged(try Data(contentsOf: source), to: target)
        }
    }
    for rel in try listFiles(sandbox) where !wanted.contains(rel) {
        try fm.removeItem(at: sandbox.appendingPathComponent(rel))
    }
}

/// Regular files under `directory`, relative, skipping build products and VCS metadata.
private func listFiles(_ directory: URL) throws -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey]) else { return [] }
    let base = directory.standardizedFileURL.path
    var out: [String] = []
    for case let url as URL in enumerator {
        let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
        if values.isDirectory == true {
            if skippedDirectories.contains(url.lastPathComponent) { enumerator.skipDescendants() }
            continue
        }
        guard values.isRegularFile == true else { continue }
        let path = url.standardizedFileURL.path
        out.append(String(path.dropFirst(base.count + 1)))
    }
    return out
}

private func needsCopy(_ source: URL, _ target: URL) throws -> Bool {
    let fm = FileManager.default
    guard fm.fileExists(atPath: target.path) else { return true }
    let a = try fm.attributesOfItem(atPath: source.path)
    let b = try fm.attributesOfItem(atPath: target.path)
    if (a[.size] as? Int) != (b[.size] as? Int) { return true }
    let sourceDate = a[.modificationDate] as? Date ?? .distantFuture
    let targetDate = b[.modificationDate] as? Date ?? .distantPast
    return sourceDate > targetDate
}

private func writeIfChanged(_ data: Data, to url: URL) throws {
    if let existing = try? Data(contentsOf: url), existing == data { return }
    try data.write(to: url, options: .atomic)
}

/// The canonical path (`/tmp` -> `/private/tmp`), as the compiler prints it.
func realPath(_ url: URL) -> String {
    guard let resolved = realpath(url.path, nil) else { return url.path }
    defer { free(resolved) }
    return String(cString: resolved)
}

/// Relative path of a compiler diagnostic path inside the sandbox, or nil.
func sandboxRelative(_ path: String, sandbox: URL) -> String? {
    for prefix in Set([sandbox.path, realPath(sandbox)]) where path.hasPrefix(prefix + "/") {
        return String(path.dropFirst(prefix.count + 1))
    }
    return nil
}
