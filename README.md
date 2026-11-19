# swift-mutator

[mizchi/mutator](https://github.com/mizchi/mutator) の Swift 用の移植です。

mizchi/mutator は [mizchi](https://github.com/mizchi) さんが作った、TypeScript / JavaScript（Vitest）向けの差分駆動ミューテーションテストツールです。swift-mutator はその設計とロジックを Swift Package 向けに移したもので、アイデアはすべてオリジナルに由来します。考え方の詳細は、オリジナルの [README](https://github.com/mizchi/mutator#readme) と [設計ノート](https://github.com/mizchi/mutator/blob/main/docs/design.md) を参照してください。TypeScript / JavaScript のプロジェクトには、オリジナルの mizchi/mutator を使ってください。

このリポジトリはオリジナルとは別に移植したものです。Swift 版の不具合や要望は、オリジナルではなくこのリポジトリの Issue にお願いします。

## 特徴

オリジナルから受け継いだ仕組みに、Swift のコンパイル言語としての性質に合わせた仕組みを加えています。

- **ミューテーションスイッチング**: すべての変異をソースへ一度に埋め込んでビルドを1回で済ませ、実行時に環境変数で有効な変異を切り替えます。
- **コンパイルできない変異の除外**: 型エラーになる変異（`String - String` など）はコンパイラの診断から特定して除外し、再ビルドします（`CompileError`）。Swift 版で追加した仕組みです。
- **テスト単位のカバレッジ**: ドライランでテストごとに到達した変異を記録し、各変異はそれに到達するテストだけで実行します。
- **結果の再利用**: 変異のキーは位置に依存しません（`file + scope path + AST path + mutator + replacement`）。結果は外側の関数のハッシュとともにキャッシュされ、関数もカバーするテストも変わっていなければ再実行しません。
- **`--since <ref>`**: `git diff <ref>` に含まれる変異だけを実行・報告します（PR モード）。

## 必要環境

- macOS 13 以降、Swift 6.0 以降のツールチェイン（Xcode）
- 対象は SwiftPM パッケージ（XCTest と swift-testing の両方に対応）
- Linux 向けのコード経路（テストバンドルを直接実行）も実装していますが、未検証です。

## 使い方

```bash
git clone https://github.com/noughts/swift-mutator.git
```

```bash
cd swift-mutator && swift build -c release
```

```bash
.build/release/swift-mutator --root path/to/YourPackage
```

`swift-mutator` を PATH に置くと、`swift mutator` としても呼べます（`swift` は `swift-<名前>` の実行ファイルをサブコマンドとして呼び出します）。

主な使い方:

```bash
swift-mutator                          # 全体を実行し .mutator/snapshot.json を書く
swift-mutator                          # 2回目以降は変わっていない結果を再利用する
swift-mutator --since main             # PR モード: main との差分にある変異だけ
swift-mutator --reporter text --reporter html --reporter json
swift-mutator --list                   # 実行せずに変異の一覧だけを出す
swift-mutator --fail-on-survived       # Survived（not detected）の変異があれば exit 2
```

対象パッケージの `.gitignore` に `.mutator/` を追加してください（サンドボックス・スナップショット・レポートの置き場所です）。

`Examples/Pricing` で試すと、次のような出力になります（初回、M シリーズ Mac で数秒）。

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

変更なしで再実行すると、ドライランも変異の実行も 0 件になります。関数を1つ編集すると、その関数をカバーしていたテストだけを再計測し、その関数の変異だけを再実行します。

### 未検出の変異の分類

- **not detected**（`Survived`）: テストは変異に到達しているが、どれも失敗しない。アサーションを強めるか、等価変異として無効化する。
- **not reached**（`NoCoverage`）: どのテストも変異に到達しない。テストケースを追加する。

### 変異の無効化

```swift
// mutator-disable-next-line EqualityOperator: しきい値は別途検証済み
if total >= 5000 { ... }
let x = a + b // mutator-disable-line
// mutator-disable / mutator-enable で範囲指定、StrykerJS の `// Stryker disable` も解釈します
```

ログ出力だけのコード（`print`、`debugPrint`、`NSLog`、`os_log`、`logger.*`、`log.*`、`*.debug`、`*.trace` など）の変異は `Ignored (arid: logging)` として実行しません（Google の arid node ルール）。`--no-arid` で無効化、`--arid-callee <pattern>` でパターンを追加できます。

### 終了コード

| code | 意味 |
|---|---|
| `0` | 正常 |
| `1` | 不正なオプション、その他の失敗 |
| `2` | 品質ゲート失敗（`--threshold-break` 未満、`--fail-on-survived` で Survived あり） |
| `4` | 変異なしでテストが失敗する、またはサンドボックスでビルドできない |

## 仕組み

```
analyze（純粋関数）  swift-syntax でパースし SwiftOperators で演算子を畳み込む → 変異候補・スコープ・配置
emit（純粋関数）     変異をスイッチとして埋め込んだソースと、ファイル単位のランタイムを生成
sandbox             パッケージを .mutator/sandbox に同期（内容が変わったファイルだけ書くので増分ビルドが効く）
build               swift build --build-tests。失敗したら診断を変異に帰属させて除外し、再ビルド
dry run             テストを1件ずつ実行し、到達した変異のキーを記録（変更の影響を受けるテストだけ）
plan（純粋関数）     スナップショットと比べて、再利用・未到達・実行（テストの順序とタイムアウト）を決める
run                 変異ごとにカバーするテストを実行（並列）。失敗したテストを killedBy として記録
report              テキスト要約、mutation-testing-elements 形式の JSON / HTML
```

- **スイッチの形**: 式は `(__mutator_on(1) ? (a - b) : (a + b))`、文は `if __mutator_on(2) { } else { f() }`、ブロックは `{ if __mutator_on(3) { return 0 } else { ... } }`。単一式の暗黙の return は `return` を補います。`__mutator_on` はファイル内 `fileprivate` のランタイムで、`SWIFT_MUTATOR_ACTIVE` を見て有効な変異を決め、ドライラン中（`SWIFT_MUTATOR_COVERAGE`）は到達した変異を記録してプロセス終了時に書き出します。
- **非コンパイル変異の帰属**: 診断位置が変異後のコード内ならその変異、スイッチ内ならそのスイッチの変異、関数内ならその関数の変異、と順に絞り込みます。一度 `CompileError` になった変異は、関数のハッシュが変わるまで最初から除外します（ビルドの往復を減らすため）。
- **テストの実行**: `swift test` は `.build` をロックして並列実行できないため、ビルド済みのテストバンドルを直接起動します。XCTest は `xctest -XCTest <ids>`、swift-testing は SwiftPM の `swiftpm-testing-helper` にイベントストリーム出力を付けて実行し、失敗・クラッシュしたテストを特定します。1回あたり約 0.03〜0.05 秒です（`swift test` 経由は約 0.5 秒）。
- **ドライランの差分化**: 型やグローバルなど宣言レベルのスコープが変わったら全テストを再計測します（メンバーの追加でディスパッチが変わりうるため）。それ以外は、新規・変更されたテストと、ハッシュが変わった（または消えた）関数をカバーしていたテストだけを再計測します。
- **テストのフィンガープリント**: テスト関数自身、そのテストを含む型の残り（`setUp` など）、テストを含まない共有コード（ヘルパ型・関数）、テストモジュールのリソースから計算します。テストやテストクラスを追加しても、他のテストのフィンガープリントは変わりません。

## 変異の種類

| mutator | 例 | 元実装との違い |
|---|---|---|
| ArithmeticOperator | `a + b` → `a - b`、`*`↔`/`、`%`→`*`、`&+`↔`&-` | 文字列・配列リテラルとの `+` は対象外 |
| EqualityOperator | `<` → `<=` / `>=`、`==` ↔ `!=`、`===` ↔ `!==` | 同じ |
| LogicalOperator | `&&` ↔ `\|\|`、`a ?? b` → `b` | `??` は右辺に置換（型が保たれる） |
| ConditionalExpression | `if` / `guard` / 三項演算子の条件 → `true` / `false`、`while` / `repeat` → `false` | カンマ区切りの複数条件は `&&` と同様に扱う |
| BooleanLiteral | `true` ↔ `false`、`!x` → `x` | 同じ |
| UnaryOperator | `-x` → `x`、`~x` → `x` | 削除のみ（cargo-mutants 方式） |
| AssignmentOperator | `+=` ↔ `-=`、`*=` ↔ `/=`、`<<=` ↔ `>>=`、`&=` ↔ `\|=` | 同じ |
| ArrayDeclaration | `[a, b]` → `[]` | 空配列への要素追加はしない（型が決まらないため） |
| DictionaryLiteral | `["a": 1]` → `[:]` | ObjectLiteral に相当 |
| StringLiteral | `"abc"` → `""`、`""` → `"Stryker was here!"` | 同じ |
| BlockStatement | `{ ... }` → `{}` | if / ループ / do / catch / defer と、戻り値のない関数・`set`・`deinit` だけ |
| CallExpression | `cache.clear()`（文）→ 削除 | 中に他の変異がある文、暗黙の return、`fatalError` などは対象外 |
| MethodExpression | `filter` / `sorted` / `reversed` / `trimmingCharacters` の削除、`hasPrefix` ↔ `hasSuffix`、`lowercased` ↔ `uppercased`、`min` ↔ `max`、`first` ↔ `last`、`prefix` ↔ `suffix`、`dropFirst` ↔ `dropLast`、`allSatisfy` ↔ `contains`（後置クロージャのみ） | Swift の API に置き換え |
| OptionalChaining | `a?.b` → `a!.b` | スイッチはチェーン全体を包む（型は Optional に昇格） |
| Regex | `/^a+$/` のアンカー・量指定子・文字クラスなど、`Regex("...")`、`NSRegularExpression(pattern:)` | 拡張構文 `#/.../#` は対象外 |
| FnValue | 戻り値型から値を生成して本体を置換: `Bool` → `true` / `false`、数値 → `0` / `1` / `-1`、`String` → `""` / `"xyzzy"`、`[T]` → `[]`、`[K: V]` → `[:]`、`T?` → `nil` と `T` の値 | 同じ（cargo-mutants 由来） |

元実装の ArrowFunction（`undefined` が存在しない）と UpdateOperator（`++` / `--` が存在しない）は移植していません。

変異を置かない箇所: `@inlinable` / `@_alwaysEmitIntoClient` / `@_transparent` の本体（クライアントにコピーされ、ファイル内ランタイムを参照できないため）、デフォルト引数、enum の raw value、属性・マクロの引数、`#if` の条件、名前を束縛するパターン（`case let x`、`case .some(let x)`）、型、`[Int]()` のように呼び出される型。束縛を含まない式パターン（`case "GET":`、`case a == b:`）は変異させます。

## mizchi/mutator との対応

| mizchi/mutator | swift-mutator |
|---|---|
| `core/src/mutators.ts`、`regex.ts` | `Sources/MutatorCore/Mutators.swift`、`Regex.swift` |
| `core/src/instrument.ts`、`scope.ts`、`ast.ts` | `Analyze.swift`、`Scope.swift`、`SyntaxSupport.swift` |
| `core/src/placement.ts`、`emit.ts`、`runtime.ts` | `Placement.swift`、`Emit.swift` |
| `core/src/arid.ts`、`disable.ts`、`hash.ts`、`text.ts` | `Arid.swift`、`Disable.swift`、`Hash.swift`（同じ cyrb53）、`Text.swift` |
| `core/src/diff.ts`、`cli/src/since.ts`、`git.ts` | `Diff.swift`、`Since.swift`、`Sources/MutatorCLI/Git.swift` |
| `core/src/plan.ts`、`cli/src/coverage-cache.ts` | `Plan.swift`、`DryRun.swift`、`Fingerprint.swift` |
| `cli/src/mte-report.ts`、`report.ts`、`status.ts` | `Report.swift` |
| `@mizchi/mutator-typecheck` | `Diagnostics.swift`（コンパイラ診断から非コンパイル変異を特定） |
| `@mizchi/mutator-vitest`（Vite transform、セッション） | `Sources/MutatorCLI/Sandbox.swift`、`TestRunner.swift`、`TestOutput.swift` |
| `cli/src/run.ts`、`options.ts` | `Sources/MutatorCLI/Run.swift`、`Options.swift` |

`MutatorCore` は純粋関数だけで構成し（ファイル・プロセス・時刻に触れません）、I/O は `MutatorCLI` に寄せています。

### 未移植の機能

weak mutation（感染しない変異を実行せずに判定）、`--kill-matrix`、`--reporter simplify` / `agent`、`select-tests`、`mutator accept`、critical regions、CI シャード、`--watch`、プラグイン、静的コールグラフ（`--experimental-callgraph`）、`--mutants-per-line` / `--time-budget`、設定ファイル。

## 制約

- テストはプロセス単位で並列実行します（`-j`）。ファイルやポートを共有するテストが干渉する場合は `-j 1` にしてください。
- サンドボックスは初回にパッケージ全体をビルドします。2回目以降は計装結果が変わったファイルだけが再コンパイルされます。
- 一度 `CompileError` と判定された変異は、外側の関数が変わるまで再検査しません。
- macOS ではクラッシュした変異ごとにクラッシュレポートが作られることがあります。

## 開発

```bash
swift test
```

- `MutatorCoreTests`: 純粋関数の単体テストです。
- `MutatorCLITests`: 実際に `swift build`・`swiftc` とテストプロセスを通す統合テストで、1分ほどかかります。

テストの多くはオリジナルのテストから移植しています。オリジナルの入力が TypeScript / JavaScript の場合は Swift のコードに書き換えています。

| オリジナルのテスト | 移植先 |
|---|---|
| `core/test/diff.test.ts` | `DiffTests.swift`（全 46 件） |
| `core/test/plan.test.ts` | `PlanTests.swift` |
| `core/test/disable.test.ts`、`arid.test.ts` | `DisableTests.swift`、`AridTests.swift`（全件） |
| `core/test/mutators.test.ts`、`instrument.test.ts` | `MutatorsTests.swift`、`InstrumentTests.swift` |
| 上記のミューテーションスイッチングのオラクルとカバレッジ記録 | `Tests/MutatorCLITests/SwitchingOracleTests.swift` |
| `cli/test/mte-report.test.ts`、`gate.test.ts` | `MutationTestingReportTests.swift` |

移植したのは、swift-mutator にある機能のテストです。移植していない機能のテストは対象外にしており、各テストファイルの冒頭に、何を移植していないかを書いています。

振る舞いオラクルは、計装したコードで変異 k を有効にした実行結果が、変異 k だけを適用したソースの実行結果と一致することを、コーパス内のすべての変異について確かめます。Swift ではこれを、変異ごとに実際にコンパイルして実行することで確かめています。

## クレジットとライセンス

- 設計・アルゴリズム・変異の種類・レポートの分類は、[mizchi](https://github.com/mizchi) さんの [mizchi/mutator](https://github.com/mizchi/mutator)（MIT License）に基づいています。オリジナル自体も StrykerJS、cargo-mutants、PIT、Google の "Practical Mutation Testing at Scale" などの先行研究を土台にしています。
- 変異のキーに使うハッシュ関数（cyrb53）は、オリジナルと同じ実装を移植しており、同じ入力に同じ値を返します。
- 正規表現の変異は、オリジナルと同じく weapon-regex の level 1 の一部に相当します。

ライセンスはオリジナルに合わせて MIT License です。オリジナルの著作権表示を [LICENSE](LICENSE) に残しています。
