# Phase 10 §10.0 — Model-interaction smoke harness suite

**Status: plan, not yet started.**
**Phase context:** this is the empirical-probe-pass deliverable for Phase 10 (chat tuning) per [`V2_PHASE10_CHAT_TUNING_SCOPING.md`](V2_PHASE10_CHAT_TUNING_SCOPING.md) §10.0. Building these smoke harnesses produces the raw data that feeds the eventual `V2_PHASE10_CHAT_TUNING_RESEARCH.md` empirical findings and informs the `ServerCapabilities` data model in §10.a.

The harnesses are **independently useful** before §10.a / §10.b / §10.c land — they let any developer (or the user) run a one-shot model-swap regression sweep and see which subsystems still behave correctly against a new server. Auto-apply of detected fixes is explicitly **out of scope here** and gated behind §10.c.

---

## Why

The app talks to LLM servers from a half-dozen different code paths. Today the only smoke coverage is `CardGenSmoke` (Card Creator AI assist, all three modes). The rest — chat generation, summariser, fact extractor, context blurber, group-chat director, embedder — has no CLI smoke surface, so:

- A model-family quirk in one subsystem (say, the summariser emits thinking traces under Gemma but not Qwen) is invisible until a user notices it during normal chat.
- The user's stated goal of "have the whole probe process automated and built into the app" requires a foundation: a known-good harness that exercises every model-facing surface deterministically. That foundation is missing.
- When a quirk is found and fixed, there's no regression test for it — Mode-3-style live smoke surfaces issues but doesn't lock them down across future model swaps.

CardGenSmoke is the existence proof. This plan generalises that pattern across every other model-facing surface and adds an aggregate runner that ties it all together.

---

## Architecture (4 layers)

### Layer 1 — Shared fixtures library

New target `SmokeFixtures` in `Package.swift`. **Library, not executable** — depended on by every smoke binary so canned chats and characters don't get duplicated.

- `SyntheticChats.swift` — pre-built `Chat` objects covering a representative surface area:
  - Cold-start (turn 0 only).
  - Casual SFW short (~5 turns, no card).
  - Casual SFW long (~50 turns) for summariser stress.
  - NSFW soft (innuendo, flirtation, no explicit anatomy).
  - NSFW explicit — multiple variants (anatomical prose, kink-specific, group scene). NSFW coverage should be wide enough to catch model refusal patterns reliably; one fixture isn't enough.
  - Group chat (3-cast, mixed user + assistant turns).
  - Character with full Intimacy + creator notes — exercises card extension data flow.
  - Post-conflict scene (emotional rather than physical) — verifies the model doesn't default-flatten everything to one tone.
  - Refusal-bait edge cases (request shapes that trigger known-pattern refusals on weakly-tuned models).
- `SyntheticCharacters.swift` — pre-built `Character` objects covering archetypes from `CardGenExemplars` (mira / monstergirl / modern / spacer / biopunk / companion / domestic). Smokes that need upstream context grab these instead of inventing their own.
- `RealChatLoader.swift` — `loadChat(id:)` reads from `~/Library/Application Support/RPClient/chats/<id>.json`. Opt-in via `--chat <id>` in any smoke. Default is synthetic.

### Layer 2 — Per-surface smoke executables

Six new `executableTarget`s, each ~150–300 LOC and each modeled on `CardGenSmoke/main.swift`:

| Smoke | Drives | Notes |
|---|---|---|
| `ChatSmoke` | `KoboldClient.generate` / `generateStream` from `ChatViewController`'s send path, with prompt assembled via `PromptBuilder`. | Most load-bearing — exercises template selection, stop sequences, system prompt, persona, world-info injection, memory prefix. |
| `SummariserSmoke` | `Summarizer.run` (Memory subsystem). | Drives long-history fixtures; checks for thinking-trace leaks and drift. |
| `ExtractorSmoke` | `FactExtractor.run` (Memory subsystem). | JSON-mode side call; checks parse path. |
| `BlurberSmoke` | `ContextBlurber.run` (Memory subsystem). | Rolling-context blurb generation. |
| `DirectorSmoke` | `DirectorPicker.next` against a group-chat fixture. | Picks next speaker; checks parse path for the picked-UUID convention. |
| `EmbedSmoke` | `KoboldClient.embed` against fixture strings. | Smallest harness; confirms `/api/extra/embeddings` availability + vector dimensionality. |

Each accepts:
```
[--server URL] [--template ID] [--fixture NAME|all] [--chat ID] [--verbose]
```

Default behavior: server = `http://192.168.1.201:5001`, template = `qwen`, fixture = `all`, no real chat.

Output is human-readable text on stdout per fixture: `--- fixture name ---` header, then prompt preview, response, refusal flag, timing. CardGenSmoke is the formatting reference.

### Layer 3 — Aggregate runner

New executable `SmokeAll`. Runs each Layer-2 smoke in sequence (sub-process or in-process), captures stdout + stderr, and produces:

- A **terminal summary**: PASS/FAIL per surface, total time, refusal rate, list of detected quirks with the fixture name + symptom.
- A **JSON report** at `~/Library/Application Support/RPClient/smoke-reports/<model-name>-<timestamp>.json` with structured findings per smoke. Schema picks up later in §10.a as the input to `ServerCapabilities` — this report is the empirical observation layer.
- Optional `--diff <prior-report>` flag to compare two reports across a model swap. Highlights regressions specifically.

**Quirk detection** is rule-based:
- Response shape mismatches schema (JSON expected, plaintext or YAML returned).
- Refusal-shaped output (uses `CardGenRefusalDetector` patterns).
- Thinking-trace leak in non-Qwen output (`<think>…</think>` where the template doesn't expect it).
- Off-topic response (response semantically unrelated to prompt — best-effort heuristic).
- Length anomalies (response far below `expectedLengthChars` or far above `maxTokens`).

Each detected quirk gets a `RemediationSuggestion` string in the report — text only, not auto-applied.

### Layer 4 — Auto-apply (deferred to Phase 10 §10.a–§10.c)

Smoke findings feed `ServerCapabilities` (per `V2_PHASE10_CHAT_TUNING_SCOPING.md` §3). When a quirk is detected and the runner has a known fix, it can be applied — but only via the `ServerProbe` subsystem, which §10.a builds. This plan **does not implement auto-apply** — it produces the data shape that §10.a consumes.

The smoke runner stays useful indefinitely: even after §10.a/§10.c land, smoke runs remain the empirical regression suite that validates ServerCapabilities decisions and catches drift on new model releases.

---

## Sub-step staging

### §10.0.a — `SmokeFixtures` library (~½ day, TDD)

- Add target to `Package.swift`.
- `SyntheticChats.swift` — at least 8 chat fixtures spanning the table above. NSFW fixtures get explicit prose since the goal is to catch refusal/sanitisation behavior.
- `SyntheticCharacters.swift` — 7 characters mirroring `CardGenExemplars`.
- `RealChatLoader.swift` with one happy-path test (round-trip a known on-disk chat).
- Tests: each fixture decodes/encodes cleanly; cast linkage holds for group chats; character extensions parse.

### §10.0.b — `ChatSmoke` (~½ day)

Most exercised surface; build first because it stresses `PromptBuilder` + `KoboldClient.generateStream`. Output prints chunk-by-chunk for streaming visibility. Default fixture set hits sfw + nsfw + cold-start + group.

### §10.0.c — `SummariserSmoke`, `DirectorSmoke` (~½ day)

Heaviest side-calls. Summariser exercises long-history compression; Director exercises group-chat speaker selection. Both are JSON-mode-adjacent.

### §10.0.d — `ExtractorSmoke`, `BlurberSmoke`, `EmbedSmoke` (~½ day)

Smaller surfaces. Extractor + Blurber are Memory side-calls; Embed is a pure-vector check.

### §10.0.e — `SmokeAll` runner + JSON report (~½ day)

Ties everything together. Spawns each smoke (sub-process is simpler, in-process is faster — go with sub-process for isolation). Quirk-detection rules live in `SmokeAll`'s own source, not duplicated per smoke. JSON report schema is documented in this plan (TBD during implementation, but matches the eventual `ServerCapabilities` shape).

### §10.0.f — Run-and-document baseline (~½ day, no code)

Run `SmokeAll` against the user's configured Qwen3.6 server. Document the baseline findings in `V2_PHASE10_CHAT_TUNING_RESEARCH.md` (which §10.0 produces per the scoping doc). Then ask the user to swap to Gemma; run again; document model-family deltas.

This is the data that informs §10.a's `ServerCapabilities` field set.

---

## Out of scope

- **Auto-apply of detected fixes.** Phase 10 §10.a + §10.c. The smoke runner emits remediation text only.
- **A "ServerProbe → smoke harness" wiring.** Phase 10 §10.a will replace the rule-based quirk detector with `ServerProbe`-derived expectations, but until §10.a exists, smoke checks live in source and update by code edit.
- **Continuous-integration runs.** These smokes drive a real KoboldCPP server; they're developer-tools, not unit tests. The existing `RPClientCoreTests` target remains the unit-test harness.
- **Voice / TTS smoke.** `KokoroSmoke` already exists; no expansion needed under this plan.
- **UI smoke (NSAccessibility-driven).** Out of scope; this plan is model-interaction only.

---

## Effort estimate

~2.5 days for §10.0.a → §10.0.e. The §10.0.f baseline-documentation pass is dependent on user model-swap availability and adds another ~½ day of real-time but minimal hands-on-keyboard.

After this plan lands, the natural next pickup is Phase 10 §10.a — `ServerProbe` data model + probe runner — which consumes the smoke output as its input.

---

## References

- [`V2_PHASE10_CHAT_TUNING_SCOPING.md`](V2_PHASE10_CHAT_TUNING_SCOPING.md) — parent scoping doc for Phase 10 (this plan implements §10.0).
- [`Sources/CardGenSmoke/main.swift`](Sources/CardGenSmoke/main.swift) — pattern reference for per-surface smoke executables.
- [`Sources/KokoroSmoke/main.swift`](Sources/KokoroSmoke/main.swift) — second reference for a self-contained CLI smoke.
- [`Sources/RPClientCore/Memory/Summarizer.swift`](Sources/RPClientCore/Memory/Summarizer.swift), [`FactExtractor.swift`](Sources/RPClientCore/Memory/FactExtractor.swift), [`ContextBlurber.swift`](Sources/RPClientCore/Memory/ContextBlurber.swift) — Memory subsystem entry points.
- [`Sources/RPClientCore/DirectorPicker.swift`](Sources/RPClientCore/DirectorPicker.swift) — group-chat speaker picker.
- [`Sources/RPClientCore/AI/CardGenRefusalDetector.swift`](Sources/RPClientCore/AI/CardGenRefusalDetector.swift) — pattern set the smoke runner reuses for refusal detection.
