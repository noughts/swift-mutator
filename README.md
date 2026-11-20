# swift-mutator

A Swift port of [mizchi/mutator](https://github.com/mizchi/mutator).

mizchi/mutator is a diff-driven mutation testing tool for TypeScript / JavaScript (Vitest), created by [mizchi](https://github.com/mizchi). swift-mutator carries its design and logic over to Swift packages, and all of its ideas come from the original. For details on the approach, see the original [README](https://github.com/mizchi/mutator#readme) and [design notes](https://github.com/mizchi/mutator/blob/main/docs/design.md). For TypeScript / JavaScript projects, use the original mizchi/mutator.

This repository is a port maintained separately from the original. Please report bugs and feature requests for the Swift version in this repository's issues, not in the original's.

## Features

On top of the mechanisms inherited from the original, swift-mutator adds mechanisms suited to Swift being a compiled language.

- **Mutation switching**: Embeds every mutant into the source at once so that a single build suffices, and selects the active mutant at runtime through an environment variable.
- **Excluding mutants that don't compile**: Mutants that cause type errors (such as `String - String`) are identified from compiler diagnostics, excluded, and the package is rebuilt (`CompileError`). This mechanism is specific to the Swift version.
- **Per-test coverage**: A dry run records which mutants each test reaches, and each mutant is run only against the tests that reach it.
- **Result reuse**: Mutant keys don't depend on position (`file + scope path + AST path + mutator + replacement`). Results are cached together with the hash of the enclosing function and are not rerun if neither the function nor the tests covering it have changed.
- **`--since <ref>`**: Runs and reports only the mutants within `git diff <ref>` (PR mode).

## Requirements

- macOS 13 or later, with a Swift 6.0 or later toolchain (Xcode)
- Targets SwiftPM packages (both XCTest and swift-testing are supported)
- A code path for Linux (running test bundles directly) is also implemented, but untested.

## Usage

```bash
git clone https://github.com/noughts/swift-mutator.git
```

```bash
cd swift-mutator && swift build -c release
```

```bash
.build/release/swift-mutator --root path/to/YourPackage
```

If you put `swift-mutator` on your PATH, you can also invoke it as `swift mutator` (`swift` runs executables named `swift-<name>` as subcommands).

Common usage:

```bash
swift-mutator                          # run everything and write .mutator/snapshot.json
swift-mutator                          # later runs reuse results that haven't changed
swift-mutator --since main             # PR mode: only mutants in the diff against main
swift-mutator --reporter text --reporter html --reporter json
swift-mutator --list                   # list mutants without running them
swift-mutator --fail-on-survived       # exit 2 if any mutant Survived (not detected)
```

Add `.mutator/` to the target package's `.gitignore` (it holds the sandbox, snapshot, and reports).

Trying it on `Examples/Pricing` produces output like this (first run, a few seconds on an M-series Mac).

```
swift-mutator: 42 mutants (42 in 2 files)
  killed 32 · survived 2 · no coverage 7 · timeout 0 · compile error 0 · ignored 1 · pending 0
  score 78.0% [low] · ran 34, reused 0 · dry run 7/7 tests · 1 build round(s) · 3.0s

not detected (tests run the mutant, but none fails: strengthen an assertion, or it is equivalent):
  Sources/Pricing/Shipping.swift:3:8  EqualityOperator  subtotal >= 5000 → subtotal > 5000  [1s7x8xr1z3e]
  Sources/Pricing/Shipping.swift:12:21  ConditionalExpression  !code.isEmpty → true  [gh04rezkw6]

not reached (no test runs the mutant: add a test):
  Sources/Pricing/Shipping.swift:7:47  FnValue  { fee == 0 ? "Free shipping" : ... } → { return "" }  [1dtylk0k2fi]
  ...
```

Rerunning without changes performs no dry runs and runs no mutants. Editing a single function re-measures only the tests that covered that function and reruns only that function's mutants.

### Categories of undetected mutants

- **not detected** (`Survived`): Tests reach the mutant, but none of them fails. Strengthen an assertion, or disable it as an equivalent mutant.
- **not reached** (`NoCoverage`): No test reaches the mutant. Add a test case.

### Disabling mutants

```swift
// mutator-disable-next-line EqualityOperator: the threshold is verified separately
if total >= 5000 { ... }
let x = a + b // mutator-disable-line
// Use mutator-disable / mutator-enable for ranges; StrykerJS's `// Stryker disable` is also recognized
```

Mutants in code that only does logging (`print`, `debugPrint`, `NSLog`, `os_log`, `logger.*`, `log.*`, `*.debug`, `*.trace`, and so on) are marked `Ignored (arid: logging)` and not run (Google's arid node rule). Turn this off with `--no-arid`, or add patterns with `--arid-callee <pattern>`.

### Exit codes

| code | meaning |
|---|---|
| `0` | Success |
| `1` | Invalid option, or another failure |
| `2` | Quality gate failed (score below `--threshold-break`, or a Survived mutant with `--fail-on-survived`) |
| `4` | Tests fail without any mutant, or the sandbox fails to build |

## How it works

```
analyze (pure)  parse with swift-syntax and fold operators with SwiftOperators → mutant candidates, scopes, placement
emit (pure)     generate source with mutants embedded as switches, plus a per-file runtime
sandbox         sync the package into .mutator/sandbox (only files whose content changed are written, so builds stay incremental)
build           swift build --build-tests --build-system native; on failure, attribute the diagnostics to mutants, exclude them, and rebuild
dry run         run tests one at a time and record the keys of the mutants reached (only the tests affected by changes)
plan (pure)     compare with the snapshot and decide what to reuse, what is unreached, and what to run (test order and timeouts)
run             run the covering tests for each mutant (in parallel); record the failing tests as killedBy
report          text summary, plus JSON / HTML in the mutation-testing-elements format
```

- **Switch shapes**: An expression becomes `(__mutator_on(1) ? (a - b) : (a + b))`, a statement `if __mutator_on(2) { } else { f() }`, and a block `{ if __mutator_on(3) { return 0 } else { ... } }`. Implicit returns of single-expression bodies get an explicit `return`. `__mutator_on` is a per-file `fileprivate` runtime that reads `SWIFT_MUTATOR_ACTIVE` to determine the active mutant; during a dry run (`SWIFT_MUTATOR_COVERAGE`) it records the mutants reached and writes them out when the process exits.
- **The sandbox as the package in place**: Every Swift source is compiled at its original path (`#sourceLocation(file:line:)`), so `#filePath` and diagnostics name the original file: tests that look for fixtures next to them, or for an app's resources up the tree, find them. Symbolic links are copied as the files they point to (a test target may share a file of the app outside the package).
- **Attributing non-compiling mutants**: If the diagnostic is inside mutated code, that mutant; otherwise the mutants of the smallest statement around it (a type error shows anywhere in the expression a mutant broke), else the file's. Blamed mutants are left out of the next build, so an error that stays is blamed on the next statement out. The native build system is used because Swift Build stops starting compiles at the first failure, so a round would find only a few files' errors. Found mutants are written to `.mutator/compile-errors.json` after each round, and are excluded up front until their function's hash changes (to reduce build round trips). Blocks whose emptying cannot compile (a `let` initialized in each branch, an `if`/`else` whose branches all return) are not emptied, since Swift reports those only after type checking succeeds, a round of their own.
- **Running tests**: `swift test` locks `.build` and can't run in parallel, so the built test bundles are launched directly, each process with a home and temporary directory of its own (`HOME`, `CFFIXED_USER_HOME`, `TMPDIR`): tests of a `.serialized` suite run in parallel processes, and a mutant must not leave files in the user's home. XCTest is run with `xctest -XCTest <ids>`, and swift-testing is run through SwiftPM's `swiftpm-testing-helper` with event stream output, which identifies the tests that failed or crashed. Each run takes about 0.03–0.05 seconds (about 0.5 seconds through `swift test`).
- **Incremental dry runs**: If a declaration-level scope such as a type, an extension, or a global changes or disappears, or an extension appears, all tests are re-measured (members and conformances can change dispatch). Otherwise, only new or changed tests, and the tests that covered functions whose hash changed (or that disappeared), are re-measured; a new function, type, or global is reached only through edited code.
- **Test fingerprints**: Computed from the test function itself, the rest of the type that contains the test (`setUp` and so on), the `private` declarations of its file, shared code that contains no tests (other helper types and functions), and the test module's resources. Adding or editing a test (in a type or at the top level) doesn't change the fingerprints of other tests.

## Mutators

| mutator | example | difference from the original |
|---|---|---|
| ArithmeticOperator | `a + b` → `a - b`, `*`↔`/`, `%`→`*`, `&+`↔`&-` | `+` with string or array literals is skipped |
| EqualityOperator | `<` → `<=` / `>=`, `==` ↔ `!=`, `===` ↔ `!==` | Same |
| LogicalOperator | `&&` ↔ `\|\|`, `a ?? b` → `b` | `??` is replaced with its right-hand side (keeps the type) |
| ConditionalExpression | `if` / `guard` / ternary conditions → `true` / `false`, `while` / `repeat` → `false` | Comma-separated conditions are treated like `&&` |
| BooleanLiteral | `true` ↔ `false`, `!x` → `x` | Same |
| UnaryOperator | `-x` → `x`, `~x` → `x` | Removal only (as in cargo-mutants) |
| AssignmentOperator | `+=` ↔ `-=`, `*=` ↔ `/=`, `<<=` ↔ `>>=`, `&=` ↔ `\|=` | Same |
| ArrayDeclaration | `[a, b]` → `[]` | Doesn't add elements to empty arrays (the element type can't be determined) |
| DictionaryLiteral | `["a": 1]` → `[:]` | Counterpart of ObjectLiteral |
| StringLiteral | `"abc"` → `""`, `""` → `"Stryker was here!"` | Same |
| BlockStatement | `{ ... }` → `{}` | Only if / loops / do / catch / defer, and functions, `set`, and `deinit` that return no value; not blocks whose emptying cannot compile |
| CallExpression | `cache.clear()` (statement) → removed | Skips statements that contain other mutants, implicit returns, `fatalError`, and so on |
| MethodExpression | Removes `filter` / `sorted` / `reversed` / `trimmingCharacters`; `hasPrefix` ↔ `hasSuffix`, `lowercased` ↔ `uppercased`, `min` ↔ `max`, `first` ↔ `last`, `prefix` ↔ `suffix`, `dropFirst` ↔ `dropLast`, `allSatisfy` ↔ `contains` (trailing closures only) | Adapted to Swift APIs |
| OptionalChaining | `a?.b` → `a!.b` | The switch wraps the whole chain (the type is promoted to Optional) |
| Regex | Anchors, quantifiers, character classes, etc. in `/^a+$/`, `Regex("...")`, and `NSRegularExpression(pattern:)` | Extended syntax `#/.../#` is skipped |
| FnValue | Replaces the body with a value generated from the return type: `Bool` → `true` / `false`, numbers → `0` / `1` / `-1`, `String` → `""` / `"xyzzy"`, `[T]` → `[]`, `[K: V]` → `[:]`, `T?` → `nil` and values of `T` | Same (from cargo-mutants) |

The original's ArrowFunction (Swift has no `undefined`) and UpdateOperator (Swift has no `++` / `--`) are not ported.

No mutants are placed in: the bodies of `@inlinable` / `@_alwaysEmitIntoClient` / `@_transparent` declarations (they are copied into clients and can't reference the per-file runtime), default arguments, enum raw values, attribute and macro arguments, `#if` conditions, name-binding patterns (`case let x`, `case .some(let x)`), types, and types that are called, such as `[Int]()`. Expression patterns without bindings (`case "GET":`, `case a == b:`) are mutated.

## Mapping to mizchi/mutator

| mizchi/mutator | swift-mutator |
|---|---|
| `core/src/mutators.ts`, `regex.ts` | `Sources/MutatorCore/Mutators.swift`, `Regex.swift` |
| `core/src/instrument.ts`, `scope.ts`, `ast.ts` | `Analyze.swift`, `Scope.swift`, `SyntaxSupport.swift` |
| `core/src/placement.ts`, `emit.ts`, `runtime.ts` | `Placement.swift`, `Emit.swift` |
| `core/src/arid.ts`, `disable.ts`, `hash.ts`, `text.ts` | `Arid.swift`, `Disable.swift`, `Hash.swift` (the same cyrb53), `Text.swift` |
| `core/src/diff.ts`, `cli/src/since.ts`, `git.ts` | `Diff.swift`, `Since.swift`, `Sources/MutatorCLI/Git.swift` |
| `core/src/plan.ts`, `cli/src/coverage-cache.ts` | `Plan.swift`, `DryRun.swift`, `Fingerprint.swift` |
| `cli/src/mte-report.ts`, `report.ts`, `status.ts` | `Report.swift` |
| `@mizchi/mutator-typecheck` | `Diagnostics.swift` (identifies non-compiling mutants from compiler diagnostics) |
| `@mizchi/mutator-vitest` (Vite transform, sessions) | `Sources/MutatorCLI/Sandbox.swift`, `TestRunner.swift`, `TestOutput.swift` |
| `cli/src/run.ts`, `options.ts` | `Sources/MutatorCLI/Run.swift`, `Options.swift` |

`MutatorCore` consists only of pure functions (it doesn't touch files, processes, or the clock), and I/O is kept in `MutatorCLI`.

### Features not ported

Weak mutation (classifying mutants that don't infect program state without running them), `--kill-matrix`, `--reporter simplify` / `agent`, `select-tests`, `mutator accept`, critical regions, CI sharding, `--watch`, plugins, the static call graph (`--experimental-callgraph`), `--mutants-per-line` / `--time-budget`, and configuration files.

## Limitations

- Tests run in parallel, one process each (`-j`), each with its own home directory. If tests that share other resources (files elsewhere, ports) interfere with each other, use `-j 1`.
- The sandbox builds the whole package on the first run. After that, only files whose instrumented output changed are recompiled.
- A mutant once judged `CompileError` isn't rechecked until its enclosing function changes.
- Sources are compiled at their original path, so a test that writes files next to `#filePath` (a snapshot-testing library recording) writes them into the package, not the sandbox.
- On macOS, a crash report may be generated for each mutant that crashes.

## Development

```bash
swift test
```

- `MutatorCoreTests`: unit tests for the pure functions.
- `MutatorCLITests`: integration tests that actually go through `swift build`, `swiftc`, and test processes; they take about a minute.

Most of the tests are ported from the original's tests. Where the original's input is TypeScript / JavaScript, it has been rewritten as Swift code.

| Original test | Ported to |
|---|---|
| `core/test/diff.test.ts` | `DiffTests.swift` (all 46 cases) |
| `core/test/plan.test.ts` | `PlanTests.swift` |
| `core/test/disable.test.ts`, `arid.test.ts` | `DisableTests.swift`, `AridTests.swift` (all cases) |
| `core/test/mutators.test.ts`, `instrument.test.ts` | `MutatorsTests.swift`, `InstrumentTests.swift` |
| The mutation-switching oracle and coverage recording from the above | `Tests/MutatorCLITests/SwitchingOracleTests.swift` |
| `cli/test/mte-report.test.ts`, `gate.test.ts` | `MutationTestingReportTests.swift` |

Only the tests for features that swift-mutator has were ported. Tests for features that weren't ported are left out, and the top of each test file notes what wasn't ported.

For every mutant in the corpus, the behavioral oracle checks that running the instrumented code with mutant k enabled gives the same result as running the source with only mutant k applied. In Swift, this is checked by actually compiling and running each mutant.

## Credits and license

- The design, algorithms, mutators, and report categories are based on [mizchi/mutator](https://github.com/mizchi/mutator) (MIT License) by [mizchi](https://github.com/mizchi). The original itself builds on prior work such as StrykerJS, cargo-mutants, PIT, and Google's "Practical Mutation Testing at Scale".
- The hash function used for mutant keys (cyrb53) is a port of the same implementation as the original and returns the same values for the same input.
- As in the original, the regex mutations correspond to part of weapon-regex level 1.

Licensed under the MIT License, matching the original. The original's copyright notice is kept in [LICENSE](LICENSE).
