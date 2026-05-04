# RPClient — Memory subsystem tuning pass

Self-contained handoff doc. Open this in a fresh context to run the dedicated memory tuning pass that has been elevated to top priority after a real failure on 2026-05-03.

The user has explicitly asked: do *not* patch memory issues piecemeal. Run this as a single focused pass.

---

## Why this pass exists

Through the V2 build (Steps A–D, shipped 2026-05-03) the six memory layers — **pinned memory**, **entity store**, **scene summaries**, **rolling summary**, **vector retrieval**, **tail-reinforce digest** — accreted as separate features without a documented contract for how they interact. On 2026-05-03 the resulting ambiguity produced a clear, user-visible regression:

### The canonical failure case

Chat: `~/Library/Application Support/RPClient/chats/5D2AB609-C6C3-4914-851F-38E0F537C6EA.json` (title: "Lets do a roleplay, you're my girlfriend"). Snapshot the file as it stood at the failure for repeatable testing.

State at the moment of failure (turn count = 58, `summarizedThrough = 47`):

| Layer | Content | "Where are they now?" implied |
|---|---|---|
| `sceneSummaries[0]` | "Sarah and her boyfriend arrived outside a Metallica stadium…" (rich, detailed concert account) | **Concert venue** |
| `summary` (rolling) | "Sarah and Emily joined the user at his car after attending a concert… The group is now at the car, intending to return to the user's residence…" | **At the car / in transit** |
| `turns[47..56]` (verbatim) | Full home/intimate scene — apartment threshold, stripping, three-way buildup | **Home** |
| `entities` (11) | Character cards | (no scene info) |
| pinned `memory` | empty | — |

Token math: ~3K used in an 8K+ context. **No truncation.** All three layers were sent to the model.

The model's next reply placed the scene back at the concert ("their slower stuff", "the songs", "tension", "your seats" — all music-venue references) even though the recent verbatim turns explicitly placed the characters naked at home. The vivid concert description in the scene summary out-weighed the recent verbatim turns as a "where are we" signal.

**This is the regression test for the entire pass.** Any proposed fix must demonstrably produce a home-scene continuation when run against a snapshot of this chat.

### Other open questions (from `MEMORY_V2_PLAN.md`)

- **Extractor under-emits new attributes** for entities already in the store (age, clothing, physical description). First-pass prompt patch shipped but is unevaluated.
- **Selective injection signal quality**: substring match catches "Sage" the herb when entity is "Sage" the character; misses pronoun-only references.
- **Post-migration UX**: pre-Step-C chats have facts duplicated in Memory + Entities tabs.
- **Suggestion fatigue**: exact-string dedup misses paraphrased re-emissions.

These are real but **secondary** to the layer-interaction problem — they describe content quality within a layer, not the structural conflict between layers. Park them; address them only if Phase 2 fixes naturally subsume them.

---

## State of the codebase

### Memory subsystem layout (`Sources/RPClientCore/Memory/`)

| File | Role |
|---|---|
| `MemoryManager.swift` | Coordinates pinned, summary, suggestions |
| `Summarizer.swift` | Side-call to model for rolling-summary compression |
| `SceneSummarizer.swift` | Side-call for scene summaries |
| `FactExtractor.swift` | Side-call for entity/fact extraction; cadence + priority topics |
| `TokenBudget.swift` | Assembles within-budget; drops oldest verbatim pair when over |
| `VectorStore.swift` | Embedding store for retrieval over chunked history |
| `Chunker.swift` | Sliding-window chunking for retrieval |

### Prompt assembly (`Sources/RPClientCore/`)

- `PromptBuilder.swift` — orchestrates the layer assembly. The function `verbatimTurns(_:)` returns `chat.turns[summarizedThrough...]`. The function `entitiesBlock(chat:)` does selective entity injection by substring matching against the last K turns. `tailMemoryDigest(chat:continuation:)` is the trailing reinforcement nudge.
- `GemmaTemplate.swift`, `QwenTemplate.swift` — layer-to-text glue per template.

### Chat data model (`Sources/RPClientCore/Models/Chat.swift`)

Relevant fields for this pass:
- `memory: String` (pinned)
- `summary: String` (rolling)
- `summarizedThrough: Int` (last index folded into rolling summary)
- `sceneSummaries: [String]` (ordered, oldest first, no per-summary metadata yet)
- `entities: [Entity]` (each has aliases, facts with salience, optional injectionMode — see Step C/D)
- `pendingFactSuggestions: [FactSuggestion]`

Note `sceneSummaries` is a flat `[String]` — no `firstTurn`/`lastTurn` markers, no scene-active flag. **This is part of the diagnosis: scene summaries have no expressed lifetime.**

### Reading the existing plan

- [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md) — the V2 design and "Open questions / things to watch" backlog.
- [`MEMORY_RESEARCH.md`](MEMORY_RESEARCH.md) — §9.x research that drove the V2 layer choices. Section 9.2 (hierarchical / tiered summarization) and 9.7 (salience / decay scoring) are particularly relevant to the audit.

---

## Phase 1 — audit (read-only, no code changes)

**Goal**: a written contract that explains how facts move between layers and what wins when layers disagree. Output is appended to `MEMORY_V2_PLAN.md` (or a new `MEMORY_AUDIT.md` if it grows large).

### Map every fact's lifecycle

For each fact category — character attribute, location, current scene, decision made, item acquired, relationship state — answer:

1. **Origin**: which layer first records it? (extractor → entity? side-call → summary? user → pinned?)
2. **Propagation**: under what conditions does it copy/move into another layer?
3. **Mutation**: what causes the value to change once recorded?
4. **Expiration / decay**: when does a fact stop being injected, and on what signal?
5. **Promotion / demotion**: can a fact in one layer be moved to another (e.g., a recurring extracted fact promoted to pinned)?

Walk the codebase to back each answer with file/line references — current behaviour, not aspirational.

### The precedence problem

For each kind of fact that can appear in multiple layers, define the precedence rule. Concretely, for **"current scene / location"**:

- Recent verbatim turns (the home scene) — strongest signal of *now*, but only if recent enough.
- Rolling summary — describes the immediately-prior summarised period; can be stale relative to recent turns.
- Scene summaries — describes a self-contained completed arc; can be very stale.
- Entities — should be scene-agnostic mostly, but per-entity location attributes can drift.
- Tail digest — a reinforcement nudge, not a source of truth.

For each pair of layers that can disagree, state the rule: "X wins when Y." If no rule exists yet, that's the gap to close.

### Identify duplication and orphan paths

- **Harmful duplication**: same fact in two layers with different content (the failure case).
- **Harmless duplication**: cheap reinforcement (e.g., a name in pinned memory and entities — costs tokens but doesn't conflict).
- **Orphan paths**: a layer being populated but never read (or read but never updated). Look especially at `tailMemoryDigest` and the scene summary lifecycle.

### Deliverable for Phase 1

A document section that includes:

1. **Lifecycle map** (table or diagram) — fact category → origin layer → propagation rules → expiration.
2. **Precedence table** — for each "kind of fact" + "pair of layers", what wins.
3. **Diagnosis of the 2026-05-03 failure** — which contract violation caused it, *under the rules just written*. If the proposed rules don't explain the failure, the rules are wrong; iterate.
4. **List of code touchpoints** that would need to change to enforce the proposed contract.

**Stop before writing code.** Show the user the audit document and get approval before Phase 2.

---

## Phase 2 — targeted fixes (driven by the audit)

Implement the smallest set of changes that would have prevented the canonical failure. Likely candidates — but **the audit drives this list, not these guesses**:

- **Scene summary lifecycle**: a way for a scene summary to be marked superseded when a new scene clearly supplants it (location change, time jump, model-detected scene boundary). Either a per-summary "active" flag, a `lastTurn` marker that excludes summaries whose covered period is too far behind the verbatim head, or replace-rather-than-append behaviour.
- **Per-summary metadata**: change `sceneSummaries: [String]` to `[SceneSummary]` with `firstTurn`, `lastTurn`, optional `location`/`active` fields. Migration path needed.
- **Precedence-aware prompt assembly**: when scene summary and rolling summary disagree, prefer the more recent. When recent verbatim contradicts both, signal that to the model (e.g., "Current scene is in the recent turns below" anchor).
- **"Most recent state" anchor block**: a small explicitly-current-state block at the prompt tail, distinct from tail digest, derived from the most recent N user+assistant turns.

**Constraint**: prefer the change that touches the fewest layers. The user's strong preference is "documented contract over more layers."

After the change lands, re-run Phase 3 against the canonical chat snapshot.

---

## Phase 3 — verify against the canonical chat

1. Capture a snapshot of `5D2AB609-C6C3-4914-851F-38E0F537C6EA.json` *before* this pass starts (so the failure state is preserved even if the user keeps using the chat).
2. Build a small harness — a CLI flag, a test, or a Sources/RPClientCoreTests case — that loads the snapshot and prints the prompt that *would* be sent at the moment of failure.
3. Confirm the post-fix prompt differs in a way that should produce a home-scene response (recent home-scene turns prominent, concert scene summary suppressed or marked stale).
4. Optionally: invoke the actual server and verify the model's reply lands in the home scene. Live verification is gold, but the prompt-diff alone is enough to prove the contract is honoured.
5. Add a regression test in `Tests/RPClientCoreTests/` that fixes the contract for future changes — even if it only checks the prompt structure, not the model output.

---

## Out of scope for this pass

These are real but should *not* expand the pass scope unless they fall out naturally:

- Cross-chat persistent memory (research §9.9).
- Multi-character voice/style block (research §9.8).
- Embedding-similarity dedup for suggestions (NEXT_STAGES A6).
- Entity merge UI (NEXT_STAGES A5).
- UI work (E phase is complete; no further chat-view changes in this pass).

If any of these surface as obvious fixes during Phase 2, log them in `MEMORY_V2_PLAN.md` and keep moving.

---

## Operational notes for a fresh context

- **Build**: `./build.sh` (release + ad-hoc codesign into `RPClient.app`).
- **Launch**: `./run.sh` — runs in-place via terminal so it inherits Local Network permission. Do not `open RPClient.app` (re-signing revokes TCC; model probes silently fall back to 4 K).
- **Tests**: `swift run RPClientCoreTests` (homegrown TestKit, not XCTest — Xcode isn't installed).
- **Source layout**: `Sources/RPClientCore/` (library), `Sources/RPClient/` (executable shim).
- **Chat data**: `~/Library/Application Support/RPClient/chats/<uuid>.json`. Atomic writes; safe to inspect with `jq`/`python3 -c "import json; …"`.
- **Settings**: `~/Library/Application Support/RPClient/settings.json`.

### Docs to read first (in priority order)

1. **This file.**
2. [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md) — current memory subsystem design + open questions.
3. [`MEMORY_RESEARCH.md`](MEMORY_RESEARCH.md) — the §9.x research that drove memory decisions.
4. [`PLAN.md`](PLAN.md) — original architecture; non-goals are now V2 candidates.
5. [`NEXT_STAGES.md`](NEXT_STAGES.md) — backlog (memory items in section A; everything else parked while this pass runs).

### Recommended opening prompt for the new context

> Open `MEMORY_TUNING_PLAN.md`. The UI overhaul (section E in NEXT_STAGES) is complete; the user wants to start the memory tuning pass. Do **Phase 1 only** — the read-only audit producing a documented contract for layer interactions. Use the 2026-05-03 chat at `~/Library/Application Support/RPClient/chats/5D2AB609-C6C3-4914-851F-38E0F537C6EA.json` as the canonical regression case. **Do not write code yet** — show the audit document for review before moving to Phase 2.

---

## Memory layer reference (so the audit doesn't have to re-derive this)

For convenience, a compact summary of the six layers as they ship today. Verify against current code before relying on any of these.

| Layer | Storage | Update trigger | Read site |
|---|---|---|---|
| Pinned memory | `Chat.memory: String` (max ~800 tok) | User-edited in Memory tab; never auto | Top of prompt, every turn |
| Entity store | `Chat.entities: [Entity]` (per-entity facts with salience, aliases, optional `injectionMode`) | `FactExtractor` side-call every N turns; user accepts in Suggestions tab | Selective injection — entities mentioned in last K verbatim turns; `entitiesBlock` |
| Scene summaries | `Chat.sceneSummaries: [String]` (flat list) | `SceneSummarizer` side-call on detected scene boundary | Always injected, in order, currently |
| Rolling summary | `Chat.summary: String`, `Chat.summarizedThrough: Int` | `Summarizer` when verbatim tokens exceed `summaryTriggerRatio * ctx` | Always injected when non-empty |
| Vector retrieval | `VectorStore` (per-chat, sqlite/file) | Background re-embed on new turns | Top-K relevant chunks per current user message; injected as "Relevant earlier moments" |
| Tail digest | `tailMemoryDigest(chat:continuation:)` (PromptBuilder.swift, ~line 179) | Computed at assembly time from recent state | Injected near prompt tail as a reinforcement nudge |

Verbatim turns (`turns[summarizedThrough...]`) are not a "memory layer" but are the ground truth the layers are *summarising* — and per the failure case, they should outrank stale summaries when they conflict.
