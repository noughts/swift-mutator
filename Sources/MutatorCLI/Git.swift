import Foundation
import MutatorCore

// --since: the changed lines of the working tree against the merge base of a ref and HEAD.

private func git(_ root: URL, _ arguments: [String]) async throws -> String {
    let result = try await runProcess("git", arguments, cwd: root)
    guard result.status == 0 else { throw CLIError("git \(arguments.joined(separator: " ")) failed:\n\(result.stderr)") }
    return result.stdout
}

/// Changed files (relative to `root`) -> changed new-side lines, and the new untracked files.
func gitChanges(_ root: URL, since: String) async throws -> (lines: [String: [Int]], newFiles: Set<String>) {
    let base = (try? await git(root, ["merge-base", since, "HEAD"]).trimmingCharacters(in: .whitespacesAndNewlines)) ?? since
    // Explicit prefixes (whatever `diff.noprefix` says): without them a top-level directory
    // named `a/`, `b/`, ... would look like one and lose its name.
    let diff = try await git(root, ["diff", "--relative", "--src-prefix=a/", "--dst-prefix=b/", "--no-ext-diff", "--no-color", "-M", "--unified=0", base, "--", "."])
    var lines: [String: [Int]] = [:]
    for file in parseUnifiedDiff(diff) {
        if let path = file.newPath { lines[path] = changedLines(file) }
    }
    let untracked = try await git(root, ["ls-files", "--others", "--exclude-standard", "--", "."])
    return (lines, Set(untracked.split(separator: "\n").map(String.init)))
}
