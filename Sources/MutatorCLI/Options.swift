import Foundation
import MutatorCore

let toolVersion = "0.1.0"

struct Options: Sendable {
    var root = FileManager.default.currentDirectoryPath
    var since: String?
    var scope: SelectMode = .node
    var include: [String] = []
    var exclude: [String] = []
    var concurrency = max(1, ProcessInfo.processInfo.activeProcessorCount / 2)
    var timeoutFactor = 1.5
    var timeoutMs = 5000
    var fullDryRun = false
    var arid = true
    var aridCallees: [String] = []
    var excludedMutators: Set<MutatorName> = []
    var reporters: [String] = []
    var reportDir: String?
    var failOnSurvived = false
    var thresholdBreak: Double?
    var list = false
    var maxBuildRounds = 10
    var help = false
    var showVersion = false

    var analyzeOptions: AnalyzeOptions {
        AnalyzeOptions(excludedMutators: excludedMutators, aridCallees: arid ? defaultAridCallees + aridCallees : nil)
    }
}

let usage = """
usage: swift-mutator [options]

Diff-driven mutation testing for Swift packages (a port of mizchi/mutator).
All mutants are compiled into one build (mutation switching) in a sandbox copy under
.mutator/sandbox; results are cached in .mutator/snapshot.json and reused when unchanged.

options:
  --root <dir>              package root (default: current directory)
  --since <ref>             only run and report mutants in `git diff <ref>` (PR mode)
  --scope node|scope        diff granularity: the mutant itself, or its enclosing function
  --include <glob>          sources to mutate, relative to the root (repeatable; default: all
                            library and executable targets)
  --exclude <glob>          sources not to mutate (repeatable)
  -j, --concurrency <n>     parallel test processes (default: half the CPUs)
  --timeout-factor <f>      mutant timeout = covering tests' time x f + const (default 1.5)
  --timeout-ms <n>          the const above, in milliseconds (default 5000)
  --full-dry-run            measure the coverage of every test, ignoring the cache
  --no-arid                 also run mutants in logging-only code
  --arid-callee <pattern>   another logging call pattern, e.g. `metrics.*` (repeatable)
  --exclude-mutator <name>  skip a mutator, e.g. StringLiteral (repeatable)
  --reporter <name>         text (default), json, html (repeatable)
  --report-dir <dir>        where json/html go (default: <root>/.mutator/report)
  --fail-on-survived        exit 2 when a reported mutant is undetected
  --threshold-break <n>     exit 2 when the score is below n percent
  --max-build-rounds <n>    rebuilds that drop non-compiling mutants (default 10)
  --list                    list the mutants and exit, running nothing
  --version, -h/--help

exit codes: 0 ok, 1 invalid options or failure, 2 quality gate failed, 4 tests fail without mutants
"""

func parseOptions(_ arguments: [String]) throws -> Options {
    var options = Options()
    var i = 0
    func value(_ flag: String) throws -> String {
        i += 1
        guard i < arguments.count else { throw CLIError("\(flag) needs a value") }
        return arguments[i]
    }
    func number<T: LosslessStringConvertible>(_ flag: String) throws -> T {
        let text = try value(flag)
        guard let parsed = T(text) else { throw CLIError("\(flag): not a number: \(text)") }
        return parsed
    }
    while i < arguments.count {
        let arg = arguments[i]
        switch arg {
        case "--root": options.root = try value(arg)
        case "--since": options.since = try value(arg)
        case "--scope":
            let text = try value(arg)
            guard let scope = SelectMode(rawValue: text) else { throw CLIError("--scope must be node or scope, got \(text)") }
            options.scope = scope
        case "--include": options.include.append(try value(arg))
        case "--exclude": options.exclude.append(try value(arg))
        case "-j", "--concurrency": options.concurrency = max(1, try number(arg))
        case "--timeout-factor": options.timeoutFactor = try number(arg)
        case "--timeout-ms": options.timeoutMs = try number(arg)
        case "--full-dry-run": options.fullDryRun = true
        case "--no-arid": options.arid = false
        case "--arid-callee": options.aridCallees.append(try value(arg))
        case "--exclude-mutator":
            let text = try value(arg)
            guard let name = MutatorName(rawValue: text) else {
                throw CLIError("unknown mutator \(text); known: \(MutatorName.allCases.map(\.rawValue).joined(separator: ", "))")
            }
            options.excludedMutators.insert(name)
        case "--reporter":
            let text = try value(arg)
            guard ["text", "json", "html"].contains(text) else { throw CLIError("--reporter must be text, json or html, got \(text)") }
            options.reporters.append(text)
        case "--report-dir": options.reportDir = try value(arg)
        case "--fail-on-survived": options.failOnSurvived = true
        case "--threshold-break": options.thresholdBreak = try number(arg)
        case "--max-build-rounds": options.maxBuildRounds = max(1, try number(arg))
        case "--list": options.list = true
        case "--version": options.showVersion = true
        case "-h", "--help": options.help = true
        default: throw CLIError("unknown option \(arg)\n\n\(usage)")
        }
        i += 1
    }
    if options.reporters.isEmpty { options.reporters = ["text"] }
    return options
}
