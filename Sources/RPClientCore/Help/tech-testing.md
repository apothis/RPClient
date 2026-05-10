# Testing (TestKit)

RPClient ships its own minimal test framework rather than using XCTest. The reason is environmental: Xcode isn't required to build or test this codebase — only the Swift command-line tools — and XCTest is awkward to invoke from a plain `swift run`. TestKit is ~100 lines of Swift, lives in [Tests/RPClientCoreTests/TestKit.swift](Tests/RPClientCoreTests/TestKit.swift), and runs as a normal executable target.

## Running tests

```sh
./test.sh
```

…which is just `swift run RPClientCoreTests`. The runner prints `PASS`/`FAIL` per case and an `N/M passed in Ts` summary, then exits with `0` if everything passed and `1` otherwise.

## Anatomy

```swift
struct TestFailure: Error { … }

final class TestSuite {
    let name: String
    func test(_ name: String, _ body: @escaping () throws -> Void) { … }
}

func expect(_ condition: @autoclosure () -> Bool, _ msg: …) throws { … }
func expectEqual<T: Equatable>(_ a: T, _ b: T, …) throws { … }
func expectGreaterThan / expectLessThan / expectNil / expectNotNil / expectTrue / expectFalse
```

Cases throw `TestFailure` when an `expect…` fires. The runner catches both `TestFailure` and any other error, prints the message and `file:line`, and continues to the next case.

## Authoring a suite

```swift
func myThingTests() -> TestSuite {
    let s = TestSuite("MyThing")
    s.test("does the obvious") {
        try expectEqual(MyThing.foo(1), 2)
    }
    return s
}
```

Register the suite in [Tests/RPClientCoreTests/main.swift](Tests/RPClientCoreTests/main.swift) by adding it to the `suites` array. That's the entire wiring story — no scheme, no Info.plist, no `@testable` macro magic.

## What's covered

| Suite | What |
|---|---|
| `PromptBuilder` | Cache-aware ordering, memory-block composition, scene-summary framing, persona injection. |
| `Template` | Gemma + Qwen3 marker placement, `<think>` handling, stop sequences. |
| `Chunker` | Window/overlap/stride boundary cases. |
| `VectorStore` | Upsert, remove, invalidate, clamp, cosine search. |
| `ChatCodable` | Schema migration paths (v1→v3). |
| `CharacterPersona` | Character + persona codable round-trips and merge semantics. |
| `CharacterCardImporter` | SillyTavern v2 PNG/JSON ingest, including the `chara` text-chunk path. |
| `TurnVariant` | Swipes data model: legacy upgrades, stale-variant fingerprinting. |
| `WorldInfoEntryCodable` | Legacy three-field migration, scope/mode round-trips. |
| `WorldInfoInjector` | Match algorithm contract — case, word boundaries, scopes, secondary keys, priority sort. |
| `MemoryAuditRegression` | Per-incident regressions: scene-vs-recent compression, framing, anchor placement. |
| `HelpIndex` | Every help page resolves; ids unique; renderer emits anchors; pane refs all resolve. |

The MemoryAuditRegression suite is worth calling out. Each case maps to a specific past failure documented in `MEMORY_AUDIT.md`. Don't delete those tests when the underlying behaviour changes — port the case to the new behaviour.

## Conventions

- **One `func nameTests() -> TestSuite` per file.** Filename matches: `NameTests.swift`.
- **`@testable import RPClientCore`** in the test files; the package's `unsafeFlags(["-enable-testing"], .when(configuration: .debug))` makes internal types visible.
- **No mocks for the network or filesystem.** Tests construct in-memory model objects (`Chat`, `Character`, etc.) and exercise pure functions. The two exceptions: vector store tests use a temp directory; importer tests load fixture PNGs from the test bundle.

## What's deliberately not tested

- **UI behaviour.** No NSView snapshot tests, no event-loop tests. The pattern is: make UI code thin, push logic into testable functions that the UI calls.
- **The model itself.** We don't test KoboldCpp. We test our integration with it (request shapes, SSE parsing).
- **End-to-end flows.** No "send a turn → assert reply" tests. The cost-to-value of actually running KoboldCpp inside CI isn't there for a single-user local app.

## Performance

The full suite runs in around **0.1 seconds** on a recent Mac. Keep it that way — cases that need a real KoboldCpp instance, or that synthesise large chat histories, belong in the `Debug → Fact extraction (eval)…` window or in scratch scripts, not in the suite.

## Adding a regression test

When you fix a bug worth not regressing:

1. Find the suite the bug touches (or add a new suite).
2. Add a `test("<one-line description of the symptom>") { … }` case.
3. The case should fail on the *unfixed* code and pass on the fix. If the case passes either way, it isn't testing the right thing.
4. Reference the incident in a one-line comment if context helps.

The MemoryAuditRegression suite is the model — every case there names the incident.
