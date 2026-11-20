import Foundation
import MutatorCore

// The sandbox is a copy of the package under `.mutator/sandbox` where instrumented sources
// replace the originals. It is kept between runs so `swift build` only recompiles what changed:
// files are written only when their content differs. Symbolic links are copied as the files they
// point to: a relative link would point elsewhere from the sandbox, and writing an instrumented
// source through a link would change the original.

private let skippedDirectories: Set<String> = [".build", ".git", ".mutator", ".swiftpm", ".index-build", "DerivedData"]

/// Mirrors `root` into `sandbox`, with `overrides` (relative path -> content) replacing files.
func syncSandbox(root: URL, sandbox: URL, overrides: [String: String]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: sandbox, withIntermediateDirectories: true)
    let files = try listFiles(root)
    for (rel, source) in files {
        let target = sandbox.appendingPathComponent(rel)
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let text = overrides[rel] {
            try writeIfChanged(Data(text.utf8), to: target)
        } else if try needsCopy(source, target) {
            try writeIfChanged(try Data(contentsOf: source), to: target)
        }
    }
    for rel in try listFiles(sandbox).keys where files[rel] == nil {
        try fm.removeItem(at: sandbox.appendingPathComponent(rel))
    }
}

/// Files under `directory`: relative path -> the regular file it is (symbolic links resolved),
/// skipping build products and VCS metadata. A directory reached twice through links is walked once.
private func listFiles(_ directory: URL) throws -> [String: URL] {
    var out: [String: URL] = [:]
    var visited = Set<String>()
    func visit(_ dir: URL, prefix: String) throws {
        guard visited.insert(realPath(dir)).inserted else { return }
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let target = dir.appendingPathComponent(name).resolvingSymlinksInPath()
            let values = try? target.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values?.isDirectory == true {
                if !skippedDirectories.contains(name) { try visit(target, prefix: prefix + name + "/") }
            } else if values?.isRegularFile == true {
                out[prefix + name] = target
            }
        }
    }
    try visit(directory, prefix: "")
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

/// Relative path of a compiler diagnostic path inside the sandbox, or of a source compiled at its
/// original path under `root` (see `atOriginalPath`), or nil.
func sandboxRelative(_ path: String, sandbox: URL, root: URL) -> String? {
    for prefix in Set([sandbox.path, realPath(sandbox), root.path]) where path.hasPrefix(prefix + "/") {
        return String(path.dropFirst(prefix.count + 1))
    }
    return nil
}
