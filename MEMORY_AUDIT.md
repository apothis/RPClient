# Memory subsystem audit — Phase 1 deliverable

Read-only audit of how the six memory layers interact today, with a written
contract to govern future behaviour. Pairs with [`MEMORY_TUNING_PLAN.md`](MEMORY_TUNING_PLAN.md).

Scope of this document:
1. Lifecycle map per layer (origin → propagation → mutation → expiration).
2. The "current scene / location" precedence problem — concrete rule.
3. Diagnosis of the 2026-05-03 regression under the proposed rule.
4. Code touchpoints needed to enforce the contract.

No code is changed in Phase 1. Phase 2 will be driven by section 4.

---

## 0. Canonical regression case (snapshot 2026-05-03)

Chat: `5D2AB609-C6C3-4914-851F-38E0F537C6EA.json`
(turns=60, summarizedThrough=47 — verified against current file)

| Layer | Content (head) | Implied "where are they?" |
|---|---|---|
| `memory` (pinned) | empty | — |
| `entities` (11) | `Sarah`, `Emily`, `Stadium`, `Apartment`, several migrated dupes | both stadium & apartment exist as locations |
| `sceneSummaries[0]` (552c) | "Sarah and her boyfriend arrived outside a Metallica stadium… loaded fries and beers… kiss… seats… Dominum…" | **Concert venue (vivid)** |
| `summary` (rolling, 453c) | "Sarah and Emily joined the user at his car… The group is now at the car, intending to return to the user's residence…" | **At the car / in transit** |
| `turns[47..56]` verbatim | apartment threshold → stripping → "We are now in my apartment, the 2 girls are naked apart from their lace panties" | **Home (apartment)** |
| `turns[57..59]` (post-failure) | three-way scene continuation | **Home** |

The model's regen reply placed the action back at the concert. ~3K of 8K+ ctx
used; no truncation; all layers reached the model intact.

This is the regression test the contract has to explain.

---

## 1. Lifecycle map (per layer, current behaviour)

Backed by file:line references to current code. "Current behaviour" not
aspirational.

### 1.1 Pinned memory — `Chat.memory: String`

| Aspect | Behaviour |
|---|---|
| Origin | User-edited in Memory tab. Never auto-populated. |
| Propagation | Tail digest re-injects last ~1200 chars at prompt tail when `chat.tailReinforceMemory=true` ([PromptBuilder.swift:183](Sources/RPClientCore/PromptBuilder.swift#L183)). No promotion to/from any other layer. |
| Mutation | User only. (Pre-Step-C this was the primary fact home; Step C migration seeded entities from it but didn't clear it — see 1.2.) |
| Expiration / decay | Never. |
| Read | Top of preamble every turn ([GemmaTemplate.swift:21](Sources/RPClientCore/GemmaTemplate.swift#L21)) — above cache boundary. |
| Position weight | Stable, system-prompt-adjacent. Strong global priors. |

### 1.2 Entity store — `Chat.entities: [Entity]`

| Aspect | Behaviour |
|---|---|
| Origin | `FactExtractor` side-call ([FactExtractor.swift](Sources/RPClientCore/Memory/FactExtractor.swift)) emits `ExtractedFact{type,name,fact}` → queued as `pendingFactSuggestions` ([AppState.swift:718](Sources/RPClientCore/AppState.swift#L718)) → user clicks Accept → `acceptSuggestion` ([AppState.swift:777](Sources/RPClientCore/AppState.swift#L777)) appends fact to existing matching entity (case-insensitive name+alias), else creates new entity. Plus a one-time migration from `memory` lines on schemaVersion<2 ([Chat.swift:148](Sources/RPClientCore/Models/Chat.swift#L148)). |
| Propagation | Per-fact `addedTurn`, `lastReinforcedTurn`, `mentionCount` bumped by `reinforceEntitiesForLatestTurn` after each finished assistant turn when the entity is mentioned in the last 2 turns ([AppState.swift:594](Sources/RPClientCore/AppState.swift#L594)). No cross-layer promotion (entity facts never become pinned memory or scene content). |
| Mutation | User-edited in EntitiesPane; auto-merge on accept by name match. No automatic supersession; `Fact.supersedesFactId` exists but is unused. |
| Expiration / decay | None. Facts never deleted automatically. **Eviction at render time only**: `entitiesBlock` drops non-pinned entities when the rendered block exceeds 600 chars, ranked by `(lastReinforcedTurn, mentionCount, -addedTurn)` ([PromptBuilder.swift:107](Sources/RPClientCore/PromptBuilder.swift#L107)). |
| Read | Selective: `Entity.mentioned(in:)` substring-matches name+aliases against last 6 turns lowercased ([PromptBuilder.swift:76](Sources/RPClientCore/PromptBuilder.swift#L76)). Rendered as `[type: Name] (a) fact (b) fact …` and attached to the **last user turn** — below cache boundary. |
| Position weight | Late in prompt, near generation marker. Strong local priors. |

Notes drawn from the canonical chat:
- 11 entities including duplicates: legacy migrated rows (`type=event`, `name="[character] Sarah"`) coexist with modern rows (`type=character`, `name="Sarah"`). Both a Stadium and an Apartment location entity exist; both can be selected if either is mentioned.
- "location" entities carry residue facts like "Sarah is at the stadium" — these were appropriate at extraction time but are now stale. Nothing decays them.

### 1.3 Scene summaries — `Chat.sceneSummaries: [String]`

| Aspect | Behaviour |
|---|---|
| Origin | User clicks **Scene break** → `AppState.markSceneBreak` ([AppState.swift:512](Sources/RPClientCore/AppState.swift#L512)) appends `chat.summary` (rolling) to `sceneSummaries` and clears rolling. Force-fires extractor afterward. No model side-call dedicated to scenes. |
| Propagation | None. The frozen string is a copy of whatever the rolling summary contained at that instant. |
| Mutation | None per-entry. Whole-array editing in `SummaryPane` (raw text). No scene-level metadata exists — `[String]` only. |
| Expiration / decay | **None whatsoever.** No `firstTurn`/`lastTurn` markers, no active flag, no superseded relationship. Once written, always injected, in full. |
| Read | **Always injected, all entries, in order**, as part of preamble ([GemmaTemplate.swift:23](Sources/RPClientCore/GemmaTemplate.swift#L23) / [QwenTemplate.swift:23](Sources/RPClientCore/QwenTemplate.swift#L23)) — labelled `[Scene 1]…[Scene N]` with no recency framing. |
| Position weight | Above cache boundary. Stable across turns. The most "scene-setting" position in the prompt — and exactly the one a vivid stale description should not occupy. |

This is the **only memory layer with no expressed lifetime.** Section 2 turns
on this.

### 1.4 Rolling summary — `Chat.summary: String` + `Chat.summarizedThrough: Int`

| Aspect | Behaviour |
|---|---|
| Origin | `Summarizer.run` ([Summarizer.swift:27](Sources/RPClientCore/Memory/Summarizer.swift#L27)) — side-call invoked by `maybeAutoSummarize` when `prompt/ctx ≥ summaryTriggerRatio` (default 0.85) and ≥6 unsummarized turns ([AppState.swift:497](Sources/RPClientCore/AppState.swift#L497)). |
| Propagation | New summary covers turns `[summarizedThrough .. endIdx)`; if a previous summary exists, the model is asked to merge them. Always leaves ≥4 trailing turns verbatim. |
| Mutation | Each cycle replaces the string and advances `summarizedThrough`. Cleared (string→"", index untouched) by `markSceneBreak`. |
| Expiration / decay | Implicit: cleared on scene break; otherwise persists. Rejected if the side-call returns <20 chars (`summarizedThrough` not advanced — [AppState.swift:550](Sources/RPClientCore/AppState.swift#L550)). |
| Read | Always injected when non-empty, after scene summaries in preamble. |
| Position weight | Above cache boundary. Authoritative for "the last summarised period". |

### 1.5 Vector retrieval — `RetrievalEngine` + `VectorStore`

| Aspect | Behaviour |
|---|---|
| Origin | `Chunker.chunks(for:)` builds 4-turn / stride-3 windows ([Chunker.swift:14](Sources/RPClientCore/Memory/Chunker.swift#L14)). Embedded in batches by `RetrievalEngine.index` ([RetrievalEngine.swift:43](Sources/RPClientCore/Memory/RetrievalEngine.swift#L43)). |
| Propagation | Re-chunked on turn changes; missing/changed embeddings re-fetched. |
| Mutation | Drops chunks whose IDs disappear (range shifted, turns deleted). |
| Expiration / decay | `recencyExclusion=10` — excludes chunks whose `lastTurnIdx ≥ turns.count - 10` to avoid echoing what's already verbatim. No salience decay. |
| Read | Top-K cosine match against last-4-turns query at `threshold=0.70`, only if `RetrievalSettings.enabled=true` (default off). Injected on the last user turn. |
| Position weight | Late in prompt, but only when explicitly enabled. |

### 1.6 Tail digest — `PromptBuilder.tailMemoryDigest`

| Aspect | Behaviour |
|---|---|
| Origin | Derived at assembly time from `chat.memory`, last ~1200 chars. |
| Propagation | None — pure function of pinned memory. |
| Mutation | Derived. |
| Expiration / decay | Suppressed in continuation mode; suppressed when `tailReinforceMemory=false` (default). |
| Read | Appended to last user turn, after retrieval, before author's note ([GemmaTemplate.swift:62](Sources/RPClientCore/GemmaTemplate.swift#L62)). |
| Position weight | Latest position any "memory layer" reaches. Strong nudge. |

### 1.7 Verbatim turns (ground truth, not a "memory layer")

`PromptBuilder.verbatimTurns` returns `chat.turns[summarizedThrough...]` if
`summary` is non-empty, else all turns ([PromptBuilder.swift:37](Sources/RPClientCore/PromptBuilder.swift#L37)). When the assembled prompt is over budget, `TokenBudget` drops the **oldest** verbatim pair ([TokenBudget.swift:138](Sources/RPClientCore/Memory/TokenBudget.swift#L138)) — note this loses information silently (turns are not folded into summary first; they stay in `chat.turns` but vanish from the prompt until the next summarize cycle). Below cache boundary.

---

## 2. The precedence contract

For each fact category that can appear in multiple layers, the rule names which layer wins when they disagree. **Today: no rule exists in code or docs. This is the gap.**

### 2.1 "Current scene / location" — the failure category

**Layers that can answer this question:**

| Layer | Strength of "now" signal | Why |
|---|---|---|
| Recent verbatim turns | **Strongest** | Literally what the characters just did. |
| Rolling summary | Strong | Covers the most recent summarised period. |
| Scene summaries | **Misleading** | Describes a *completed prior arc*; the very name "Scene break" implies the scene ended. Yet today they're injected as if current. |
| Entity location facts | Weak / scene-agnostic | "X is a tall woman" is timeless; "X is at the stadium" is a snapshot that decayed. Mixed. |
| Tail digest | None for scene | Pinned memory only; user-curated. |

**Proposed rule for "current scene / location":**

> The most recent N verbatim turns are authoritative for *where the
> characters are now*. Scene summaries describe **prior, completed arcs** and
> must be framed and weighted accordingly. The rolling summary describes the
> immediate prior period; if it disagrees with recent verbatim, recent verbatim
> wins. Entity facts describing transient state (location-of-character,
> currently-wearing) decay — they are not authoritative once superseded by
> later turns.

Operationally, this implies:
1. **Scene summaries lose their lifetime ambiguity.** They must carry a `lastTurn` marker or equivalent. They are presented to the model as "earlier in the story" with explicit framing — never as current state.
2. **A "current scene anchor" is added** at the prompt tail, derived from the last K verbatim turns. This is the single source of truth the model is told to follow. (Distinct from the existing tail digest, which only echoes pinned memory.)
3. **Location-typed entity facts get optional decay**: a `lastReinforcedTurn` already exists; we just don't gate injection on it. A character-at-location fact unmentioned for >M turns can be soft-suppressed.

### 2.2 Other fact categories

The other categories don't currently produce conflicts of the same severity, but the contract should still be explicit:

| Fact category | Authoritative layer | Notes |
|---|---|---|
| Persistent character attributes (name, age, appearance, occupation) | **Entity store** | Pinned memory may duplicate by user choice; harmless reinforcement. Scene summaries shouldn't redefine these. |
| Persistent location attributes (description, owner) | **Entity store** | Distinct from "currently at" (a transient state — not authoritative anywhere; lives only in verbatim/rolling summary). |
| Items held / state of dress | Verbatim turns + rolling summary; entity facts as backup | Decays with verbatim. Avoid pinning unless user explicitly does. |
| Relationship state | Entity store | Relationship-typed entities are the home; rolling summary echoes for short-term context. |
| Long-arc plot facts (decisions made, knowledge gained) | Rolling summary + scene summaries | Cross-arc memory is exactly what scene summaries are for — once we restrict them to prior-arc framing. |
| User-curated must-remember | Pinned memory | Always wins; tail digest reinforces. |

### 2.3 Cross-layer rules in one paragraph

> Pinned memory and entity store carry **timeless** facts (attributes,
> identities, relationships) and are always authoritative for those. Verbatim
> turns are authoritative for **current state**. Rolling summary is
> authoritative for **the immediate prior period**. Scene summaries are
> authoritative for **completed prior arcs only** — they must be framed as
> such and decoupled from "where are we now". Retrieval and tail digest are
> reinforcement aids, not sources of truth.

---

## 3. Diagnosing the 2026-05-03 failure under this contract

State at failure (verified):

```
preamble (above cache boundary):
  [Scene 1]  ← 552c vivid concert prose
  rolling summary  ← "now at the car…"
verbatim turns 47..59:  ← apartment / stripping / naked
last user turn extras:
  entitiesBlock         ← whichever entities are mentioned in last 6 turns
  (no retrieval, no tail digest)
```

**Contract violations active simultaneously:**

| Violation | Layer | Effect |
|---|---|---|
| Scene summary describes a completed arc but is framed as `[Scene 1]` (neutral) and placed in scene-setting position | sceneSummaries | Model reads it as part of the active world rather than backstory. |
| Scene summary has no lifetime marker | sceneSummaries | Cannot be auto-suppressed even when summary + verbatim have clearly moved past it. |
| No "current scene" anchor near the generation marker | (missing) | Model has to infer current-state precedence from prompt position alone. |
| Vivid prose density imbalance | sceneSummaries vs verbatim | 552c rich concert description outweighs short, abrupt verbatim turns ("we are now in my apartment") — *position* says verbatim wins, *prose weight* says scene wins. |
| Possible: stadium-location entity fact | entities | If a Stadium entity gets selected (e.g. via alias substring hit on something benign), it adds another concert-venue signal in the strongest position. Less likely the dominant cause given the recent-mentions filter. |

The dominant cause under the proposed rule is the **scene-summaries violation**:
they're injected with full weight, in scene-setting position, with no marker
saying "this arc is done, see the recent turns for now."

The proposed rule produces a different prompt: `[Scene 1]` becomes
`[Earlier in the story — completed arc]`, optionally compressed once it falls
N turns behind the verbatim head, plus a "current scene" anchor near the tail
saying *use the recent turns below for where the characters are right now*.
A model fed that prompt should continue the home scene.

**Sanity check on the rule itself:** if recent verbatim is the canonical "now"
signal, would that ever be wrong?
- Mid-stream regen / retry: yes, recent verbatim is still the right anchor — that's the same story.
- Long pause where the user types "we left off at the concert, jump back": the user's *new* turn is the most recent verbatim and would override. Correct behaviour.
- Brand-new chat with seed prompt only: no scene summaries yet, no conflict.
The rule holds.

---

## 4. Code touchpoints to enforce the contract

The smallest set of changes that would have produced a home-scene continuation. Phase 2 picks from this list — it is not a commitment to do all of them.

> **Status as of 2026-05-03 (post-implementation):** A, B, C, D, F shipped.
> Path E partially shipped (clothing-only). The empirical verification ran the
> canonical chat through the live model after the changes landed; the
> regression continued the home/intimate scene correctly. Path D (compression
> of stale arcs) was the load-bearing fix — A+B+C alone weren't enough on
> their own because the 552-char vivid concert prose still out-pulled recent
> verbatim by sheer prose density.

### 4.1 Required (directly addresses the failure)

**A. Scene summary metadata** — `Chat.sceneSummaries: [String]` →
`[SceneSummary]` with optional `firstTurn`/`lastTurn`. Legacy `[String]`
shape decoded transparently with nil markers. **Shipped 2026-05-03**.
- [Models/SceneSummary.swift](Sources/RPClientCore/Models/SceneSummary.swift) — type.
- [Models/Chat.swift](Sources/RPClientCore/Models/Chat.swift) `init(from:)` — Codable migration; both `[SceneSummary]` and legacy `[String]` paths.
- [AppState.swift](Sources/RPClientCore/AppState.swift) `markSceneBreak` — populates markers from prior scene + `summarizedThrough`.

**B. Scene summary framing in templates** — `[Scene N]` →
`[Earlier in the story — completed arc N, turns X–Y]` (range omitted when
markers nil). Centralised in `PromptBuilder.SceneSummaryFormatter` rather
than duplicated across templates. **Shipped 2026-05-03**.
- [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) `SceneSummaryFormatter`.
- Both [GemmaTemplate.swift](Sources/RPClientCore/GemmaTemplate.swift) and [QwenTemplate.swift](Sources/RPClientCore/QwenTemplate.swift) call into the formatter.

**C. "Current scene" anchor at the prompt tail** — `[Current scene — read
this as the source of truth]` block telling the model recent verbatim is
authoritative and to not relocate the scene back to earlier-arc settings.
Injected as the *very last* thing in the last user turn (after digest +
author's note). Suppressed in continuation mode and when there are no
scene summaries to disambiguate. **Shipped 2026-05-03**.
- [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) `currentSceneAnchor`.
- Wired in both templates.

### 4.2 Required additions (post-audit decision, 2026-05-03)

**F. Entity-store dedup pass for migrated dupes** — collapses
`name="[type] X" / type=event` legacy rows into their typed twins by
parsing the bracket prefix and re-keying on `(type, name.lowercased())`.
Runs once per chat on decode for `schemaVersion < 3`; bumps to v3.
Brackets that don't name a real `EntityType` are left alone.
**Shipped 2026-05-03**.
- [Models/Chat.swift](Sources/RPClientCore/Models/Chat.swift) `dedupeMigratedEntities`.

### 4.3 Shipped follow-ups (post-Phase-2 empirical fixes)

**D. Scene-summary staleness compression** — promoted to required after
A+B+C alone failed live verification. Scenes whose `lastTurn` is more than
8 verbatim turns behind the head — or whose markers are nil (legacy) —
have their `text` compressed at render time to a clause-level headline
(cut at first comma/sentence terminator within an 80-char cap), with
"[…earlier scene compressed; refer back only for continuity.]" suffix.
Storage untouched; compression happens in
`PromptBuilder.renderableScenes(chat:)`. **Shipped 2026-05-03 — this was
the load-bearing fix**.
- [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) `SceneSummaryFormatter.compact` + `renderableScenes`.
- [TokenBudget.swift](Sources/RPClientCore/Memory/TokenBudget.swift) routes through `renderableScenes` so token math reflects compressed reality.

**E (clothing only). Render-time topic supersession on entity facts** —
state-of-dress facts ("Sarah is topless" vs "Sarah is naked") were both
landing in the entities block and contradicting each other. New
`PromptBuilder.factTopic` classifier buckets known transient categories
(currently just `clothing`); `supersedeStaleFactsByTopic` keeps the most-
recent fact per non-nil bucket per entity, preserving topicless facts
(timeless attributes) and user-pinned facts unconditionally. Storage
untouched — full history visible in the Entities pane.
**Shipped 2026-05-03 (clothing bucket only)**.
- [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) `factTopic` + `supersedeStaleFactsByTopic`, applied inside `entitiesBlock`.

### 4.4 Still parked — buckets / levers not yet bitten

**E (other buckets).** Extend `factTopic` with additional transient-state
buckets when they show up as failures: current location ("X is at Y"),
mood ("X is happy/sad/angry"), activity ("X is doing Y"). Each carries
more false-positive risk than clothing — defer until empirically needed.

**Stale rolling-summary suppression.** When `summarizedThrough` is far
behind `turns.count` *and* the rolling summary's content disagrees with
recent verbatim, the rolling summary can also pull. Did not need
addressing for the canonical failure but is the next likely lever if a
similar regression surfaces.

**Cadence default.** `factExtractionEveryNTurns` lowered from 8 → 4 for
fresh installs (2026-05-03). Existing users keep their persisted value.

**Extractor cadence visibility.** ExtractionPane now shows
`auto-extract: last user turn X · now Y · every Z · next in N user turns`
plus a "Run now" button. Surfaces what was already persisted in
`chat.lastExtractedTurn`.

### 4.5 Out of scope for Phase 2

- Embedding-similarity dedup for suggestions.
- Pronoun-aware selective injection.
- Cross-chat persistent memory.
- Multi-character voice/style block.
- Entity merge UI.

---

## 5. Phase 3 verification — what shipped

Regression coverage in [Tests/RPClientCoreTests/](Tests/RPClientCoreTests/):

- `MemoryAuditRegressionTests.swift` — 8 tests mirroring the canonical chat
  shape (60 turns, summarizedThrough=47, concert scene + at-car summary +
  apartment-set recent verbatim). Asserts: past-tense framing, anchor
  placement after scene block, recent verbatim outranks concert prose by
  position, anchor suppressed in continuation, anchor absent without
  scenes, marker synthesis on scene break, stale-scene compression hides
  interior detail, recent-scene full body preserved.
- `ChatCodableTests.swift` — 3 new tests: legacy `[String]` decode,
  `dedupeMigratedEntities` in isolation, dedup wiring through Codable.
- `PromptBuilderTests.swift` — 5 new tests: clothing-bucket supersession,
  pinned-fact override, input-order preservation, `factTopic` direct
  classification, `entitiesBlock` end-to-end with Sarah's
  topless→naked progression.
- `TemplateTests.swift` — 1 new test: scene block omits range when markers
  nil.

In-memory synthetic fixture rather than on-disk JSON. The audit originally
called for committing `5D2AB609-…json` to `fixtures/` — switched to code-
based reproduction so the test stays portable. Deferred: real-fixture loading
via `Bundle.module` if structural drift in the persisted shape becomes a
concern.

**Live verification:** ran the canonical chat through the actual model after
the fix landed. Initial round (A+B+C only) still regressed to the concert.
Second round (A+B+C + D compression + strengthened anchor) continued the
home/intimate scene correctly. **Empirical pass.**

---

## 6. Open questions parked for Phase 2 conversation

These came up during the audit but don't need answering before Phase 2 starts.
Logged so they're not lost.

1. **Where does the "current scene" anchor live in the cache layout?** Below
   the cache boundary (turn-by-turn) or above (rare invalidation, big TTFT
   win)? Above is preferable but requires a slowly-changing source — perhaps
   the rolling summary's last sentence rather than recent verbatim text.
2. **Should rolling summary clear when a new scene starts mid-summarisation
   cycle?** Today `markSceneBreak` clears it but a fresh auto-summarize will
   re-derive it from the next batch. Probably fine.
3. **Do we need per-scene metadata beyond firstTurn/lastTurn?** A
   `location` field would let suppression be smarter (don't suppress the
   active scene's "shape" if the model is doing a flashback). YAGNI for now.
4. **How does the entity store interact with scene boundaries?** Today the
   force-fired extractor at `markSceneBreak` is meant to capture state — but
   transient location facts can leak. Tied to 4.2/E.

---

## 7. Summary

The six layers shipped pre-audit with no documented contract for "what wins
when they disagree about current state". The 2026-05-03 failure was the
contract gap manifesting visibly: a vivid completed-arc scene summary
out-weighed recent verbatim turns because nothing in the system told the
model to read verbatim as the source of truth.

The proposed rule — *recent verbatim wins for "now"; scene summaries are
prior-arc only* — explained the failure and was enforced via paths
A+B+C+D+F (and clothing-bucket E) over a single 2026-05-03 session.
Live verification against the canonical chat passed. **Path D
(compression of stale arcs) was the load-bearing fix** — the structural
changes (typed metadata, past-tense framing, tail anchor) were necessary
groundwork but not sufficient on their own; the model still followed the
prose-density signal until the stale arc's body was stripped down to a
clause-level headline.

Future drift, if any, will most likely surface in the parked levers in
§4.4 — additional transient-state buckets (location, mood, activity) or
stale rolling-summary suppression. Defer until empirically needed.
