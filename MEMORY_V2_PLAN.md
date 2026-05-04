# RPClient — Long-term memory: V2 implementation plan

Self-contained handoff doc. Pick up here in a fresh context to continue building toward the goal: **long-form RP chats that remember significant facts and actions automatically over hundreds of turns**.

Background reading if needed (don't re-read unless something below is unclear): [`PLAN.md`](PLAN.md) for the original architecture, [`MEMORY_RESEARCH.md`](MEMORY_RESEARCH.md) for the §9.x research that drove these decisions.

---

## What ships today

### Prompt assembly

Memory layers cooperate at prompt-build time. They live in `Sources/RPClientCore/PromptBuilder.swift` (assembly), `Sources/RPClientCore/GemmaTemplate.swift` and `QwenTemplate.swift` (template-specific placement), and `Sources/RPClientCore/Memory/TokenBudget.swift` (sizing).

```
PROMPT (top → bottom)

  1. Pinned memory          ← Memory pane (freeform notes; was the primary store pre-Step-C)
  2. Scene summaries        ← "Scene break" button in Summary pane
  3. Rolling summary        ← Auto at 70-85% ctx + "Summarize now" button
  ─── cache boundary ───
  4. Verbatim recent turns
  5. (last user turn body)
       ├ entity block       ← Step C: only entities mentioned in last 6 turns
       ├ retrieval hits     ← Vector store, embed-on-send (kobold --embeddingsmodel)
       └ tail-reinforce     ← Memory bullets re-injected (per-chat toggle)
  6. Author's note
  7. New user message
```

| Layer | Source of truth | Lifetime | Cache impact |
|---|---|---|---|
| Pinned memory | `Chat.memory: String` (newline-separated rows) | Permanent until user edits | Above boundary — invalidates on edit |
| Scene summaries | `Chat.sceneSummaries: [String]` | Frozen on user click; never auto-edited | Above boundary — invalidates on append |
| Rolling summary | `Chat.summary: String` + `summarizedThrough: Int` | Auto-replaced when threshold hit | Above boundary — invalidates on summarise |
| **Entity store** | `Chat.entities: [Entity]` (each with `[Fact]`) | Mutated by suggestion-accept and EntitiesPane edits | **Below boundary** — selective per-turn rendering, free to change |
| Retrieval | `VectorStore` per chat in `~/Library/Application Support/RPClient/vectors/` | Embedded once per chunk; queried per send | Below boundary — recomputed each turn (cheap) |
| Tail reinforce | Derived from `Chat.memory`, last ~1200 chars | Per send | Below boundary — costs ~0.3-1s prefill |
| Author's note | `Chat.authorsNote` | Manual | Depth-dependent placement |

### Fact extraction loop (Steps A + B shipped)

The §9.3 extractor runs **automatically** post-stream and after scene breaks. Output does NOT touch `chat.memory` directly — it lands in a per-chat suggestions queue that the user reviews.

Flow:
1. **Trigger** (`AppState.maybeAutoExtract`):
   - On `streamFinished` for a fresh user-turn stream (skipped on regen/continue).
   - Force-fired by `markSceneBreak` regardless of cadence.
   - Gated on `!isStreaming && !isSummarizing && !isExtracting && !isRetrieving` to avoid double-loading the model.
   - Cadence: `userTurnsNow - chat.lastExtractedTurn >= settings.factExtractionEveryNTurns`. **All counts are user turns (= cycles)**, not total transcript entries.
2. **Run** (`AppState.runExtractor` → `FactExtractor.run`):
   - Scan window: `chat.factExtractionScanTurns` if > 0, else `max(4, unseenUserTurns + 2)`.
   - Slicer walks back N user turns, including all interleaved assistant replies.
   - Per-chat priority topics steer output. Library presets in `Settings.priorityTopicLibrary` are *copied* into chat on add (no live link).
   - GBNF grammar enforces JSON shape; "Already known" block prevents re-emission of pinned/summarised facts.
3. **Queue** (`AppState.addSuggestions`):
   - Maps `ExtractedFact{entityType, entityName, fact}` → `FactSuggestion{category, fact: "name — text", createdTurn}`.
   - Dedupes against pending suggestions AND against memory lines (exact match on `[type] name — text`). Dismissed facts are **not** tracked, so they can resurface — by design.
   - Pending queue capped at 50; oldest evict.
4. **Review** — user clicks ✓ in the Suggestions inspector tab to promote (appends one line to `chat.memory`) or × to drop.

`chat.lastExtractedTurn` advances after every run (success or failure) to prevent loop-on-failure. Stored in user-turn units; pre-fix chats are clamped at read time.

### UI surfaces

- **Inspector tabs** (Memory, Suggestions, Extraction, Summary, Author's Note, Retrieval). The Suggestions tab label shows `Suggestions ● N` when new entries arrive while another tab is active; clears on selection.
- **Extraction tab** ([`Sources/RPClient/UI/Inspector/ExtractionPane.swift`](Sources/RPClient/UI/Inspector/ExtractionPane.swift)): per-chat priority topics editor with checkboxes, scan-turns field (0 = auto), "Add from library…" pull-down, "Save active topics to library…" button.
- **Status bar** (`StatusBar.refreshActivity`): yellow `extracting Xs` badge alongside the existing summarising/retrieving/indexing badges.
- **Input bar** ([`Sources/RPClient/UI/InputBar.swift`](Sources/RPClient/UI/InputBar.swift)): Send/Regen/Continue disabled while `isExtracting`. Stop is enabled and cancels.
- **Settings → Memory section**: enable toggle, cadence stepper, library editor (add/edit/remove presets). Settings window reloads from `AppState` on every show, so changes made elsewhere appear when you reopen.
- **Debug › Fact extraction (eval)…** ([`Sources/RPClient/UI/FactExtractorEvalWindow.swift`](Sources/RPClient/UI/FactExtractorEvalWindow.swift)): pure inspection — Run, Send to suggestions, parsed facts, raw output. Reads topics + scan window from the chat (not from this window).

### Entity store (Step C shipped)

The structured store. `chat.entities: [Entity]` replaces `chat.memory` as the canonical home for long-term facts; `chat.memory` is kept as a freeform notes slot that always injects.

- **Models** ([`Sources/RPClientCore/Models/Entity.swift`](Sources/RPClientCore/Models/Entity.swift), [`Fact.swift`](Sources/RPClientCore/Models/Fact.swift)). `Entity{id, name, aliases, type, facts, pinnedByUser, createdTurn}`. `Fact{id, text, addedTurn, lastReinforcedTurn, mentionCount, supersedesFactId, pinnedByUser}` — the salience-related fields exist now so Step D doesn't reshape the schema.
- **Migration**. `Chat.schemaVersion: Int` decodes to 1 for pre-Step-C chats; on first decode each parsed memory line becomes a one-fact entity (`[type] name — text` shape recognised; falls back to `.event`). Memory is left untouched. Schema version bumps to 2 on first save so it never re-migrates.
- **Selective injection**. [`PromptBuilder.entitiesBlock(chat:)`](Sources/RPClientCore/PromptBuilder.swift) substring-matches names + aliases against the last 6 turns (case-insensitive), emits only matches as `[Type: Name] (a) fact-1 (b) fact-2`, capped at 600 chars (oldest-`createdTurn` matches drop first). Block is attached to the **last user turn**, alongside retrieval — below the cache boundary, so on-stage cast changes don't invalidate prefill.
- **Suggestion-accept routing** ([`AppState.acceptSuggestion`](Sources/RPClientCore/AppState.swift)). Existing-name match (incl. aliases, case-insensitive) → fact appended; no match → new entity. `addSuggestions` dedup also walks the entity store, so promoted facts don't resurface.
- **Extractor "Already known" block** ([`FactExtractor.swift`](Sources/RPClientCore/Memory/FactExtractor.swift)). Now serialises the entity store alongside memory + summaries. The header explicitly says "partial fact list — NEW attributes about these entities SHOULD still be emitted" because small models otherwise read "entity exists" as "everything about it is known."
- **UI** ([`EntitiesPane.swift`](Sources/RPClientCore/UI/Inspector/EntitiesPane.swift)). New inspector tab between Memory and Suggestions. Per-entity cards: type popup, name, aliases (comma-separated), pin checkbox, delete; per-fact rows with text, pin, remove. Search box filters across name/aliases/type/fact text.
- **Token budget**. `entitiesTok` is folded into `BudgetUsage.memory` so the existing blue ctx-bar segment covers it; status bar tooltips name each segment.

### Data model state

`Chat`:
- `pendingFactSuggestions: [FactSuggestion]` — populated by suggestion queue, drained by ✓/×.
- `factExtractionPriorities: [FactExtractionPriority]` — per-chat steering hints.
- `factExtractionScanTurns: Int` — 0 = auto, >0 = explicit scan window in user turns.
- `lastExtractedTurn: Int` — user-turn-count high-water mark for cadence gating.
- `entities: [Entity]` — structured store (Step C).
- `schemaVersion: Int` — gates the one-time `memory → entities` migration.

`Settings`:
- `factExtractionEnabled: Bool`, `factExtractionEveryNTurns: Int` (default 8).
- `priorityTopicLibrary: [LibraryTopic]` — global presets, copied on add.

All new fields use `decodeIfPresent` fallbacks; existing chat files load unchanged.

---

## Goal

Chat for hours; the model never forgets significant facts (names, ages, decisions, relationships, items, locations) regardless of when they were established. The user occasionally curates the suggestion queue but does not babysit memory. Prompt budget stays sustainable because injection is **selective** — only facts about entities currently on-stage get into the prompt.

---

## Step C — Entity store (✅ shipped 2026-05-03)

Shipped as documented in "Entity store (Step C shipped)" above. Departures from the original plan, captured here for reference:

- **Entity block placement: BELOW the cache boundary, not above.** The plan said "above the rolling summary (treat as semi-stable)." First implementation followed that, but selective injection inherently makes the block unstable turn-to-turn (cast on stage shifts), so caching went to ~0% on chats with empty memory. Moved to live alongside retrieval on the last user turn — same cache zone, same per-turn cost profile.
- **Entity merge**: not implemented. User does it manually by editing the entity's aliases, then deleting the redundant entry. Add a one-click merge if this becomes friction.
- **Status bar**: no separate `entities: N` readout; entity tokens fold into `BudgetUsage.memory` so the existing blue ctx-bar segment covers them. Hover tooltips on the bar segments now name each layer.
- **Tail reinforce**: still reads `chat.memory`. Plan said "update to read entity store too or document." Documented: tail reinforce is about Gemma first-turn drift, not selective recall — they don't overlap, no change needed.

Open items noted during the build:
- Extractor under-emits new attributes (age, physical description, clothing) on entities that already exist in the store. First-pass prompt patch landed (rule reordering + relabelling the "Already known" block); needs eval. See "Open questions" below.
- Memory and Entities tabs coexist post-migration, so seeded facts appear in both. User clears Memory by hand for now.

---

## Step D — Salience (✅ shipped 2026-05-03)

Bumped `Fact.lastReinforcedTurn` and `Fact.mentionCount` after every fresh user-turn stream; rewrote `entitiesBlock` to evict by salience instead of `createdTurn`; added hot/stale styling to the EntitiesPane.

### What landed

- **Reinforcement** ([`AppState.reinforceEntitiesForLatestTurn`](Sources/RPClientCore/AppState.swift)). Fires from the `streamFinished` handler when `streamIsFreshUserTurn` is true. Scans the **last two turns** (latest user message + just-finished assistant reply) lower-cased; for every entity whose name or alias substring-matches, sets every owned fact's `lastReinforcedTurn` to the current user-turn count and increments `mentionCount` by 1. Regen/continue leave `streamIsFreshUserTurn = false` so they never double-bump.
- **Eviction** ([`PromptBuilder.entitiesBlock`](Sources/RPClientCore/PromptBuilder.swift)). Two-phase rank: per-entity facts sort by `(pinnedByUser desc, lastReinforcedTurn desc, mentionCount desc, addedTurn asc)` so the freshest details render first. When the rendered block overflows `maxChars`, **whole entities** drop in ascending order of `entitySalience(ent) = (max lastReinforcedTurn, max mentionCount, min addedTurn)` across the entity's facts. Pinned entities (`Entity.pinnedByUser`) are excluded from the drop list — they never evict, even when the cap is exceeded.
- **Visualisation** ([`EntitiesPane.makeFactRow`](Sources/RPClientCore/UI/Inspector/EntitiesPane.swift)). Each fact row carries a salience triplet: bullet (orange `●` hot / grey `•` normal / faint stale), text weight (semibold hot / normal / dimmed stale via `tertiaryLabelColor`), and a mono meta label `×N · Δlag` (mention count and turns since last reinforced; `—` for never-reinforced, `now` for this turn). Pinned facts ignore the dim and stay full-color. Hot threshold = lag ≤ 1 user turn; stale = never-reinforced *and* added > 15 turns ago, OR lag > 15.
- **Signature update**. `entitiesSignature` now includes `lastReinforcedTurn`, `mentionCount`, `pinnedByUser`, plus the current user-turn count, so the pane redraws as heat decays — not just on edits.

### Departures from the plan

- Reinforcement scans the **user→assistant pair** (suffix(2)), not just the user turn. Both halves of the exchange count as "this turn"; matches what `entitiesBlock` treats as on-stage. If this proves too generous (e.g. the assistant gratuitously name-checks a character the user never raised), tighten to `suffix(1)` — that field is already isolated.
- Match logic was *not* factored out into a shared helper: `Entity.mentioned(in:)` already existed and is called from both sites. No new abstraction needed.
- No sort menu in the pane. Salience drives the prompt; the pane shows entities in storage order so the user sees what they edited last. If an explicit sort dropdown becomes useful, it's a one-control add.

### Open during the build

- Reinforcement ignores stretches without sends (e.g. user reads a long reply, comes back days later). `mentionCount` only goes up; there's no half-life. Acceptable for now — eviction is by recency first, and `lastReinforcedTurn` already lags naturally with idle time.
- Heat doesn't visibly decay on opening the pane in a chat that hasn't streamed since launch unless an edit happens; the signature includes `currentUserTurn`, but that only changes on send. Fine in practice — heat is most useful right after a send.
- Tail reinforce remains untouched. Step D doesn't change the layer interaction docs in "Open questions" — that still wants a holistic pass.

---

## How the layers interact (post-Step-D snapshot)

Six places "long-term memory" can live, layered top-to-bottom in the prompt:

| # | Layer | Source | Where in prompt | When written | When evicted |
|---|---|---|---|---|---|
| 1 | **Pinned memory** | `Chat.memory: String` (Memory tab) | Top, above cache boundary | User edits in Memory tab; never auto-written | Never; user clears by hand |
| 2 | **Scene summaries** | `Chat.sceneSummaries: [String]` | Above boundary, after pinned | "Scene break" button freezes current rolling summary | Never; user prunes by hand |
| 3 | **Rolling summary** | `Chat.summary` + `summarizedThrough` | Above boundary, after scene summaries | Auto at 70-85% ctx, "Summarize now" button | Replaced wholesale by next summarizer run |
| 4 | **Entity store** | `Chat.entities: [Entity]` (Entities tab) | **Below boundary**, attached to last user turn (selective) | Suggestion-accept routes here; user edits in Entities tab | Per-fact: salience-ranked eviction when block > 600 chars (Step D); Pinned entities/facts immune |
| 5 | **Retrieval hits** | `VectorStore` per chat | Below boundary, last user turn | Background re-embed on stream-finish | Per-send: top-K above threshold, recency-excluded |
| 6 | **Tail reinforce** | Derived from `Chat.memory` (toggle per chat) | Below boundary, last user turn | Per-send if `tailReinforceMemory` true | Truncated to last ~1200 chars |

**What each layer is *for*:**

- **Pinned memory (1)** — always-on instructions, scene state, OOC rules, narrator persona, world constants. Anything that needs to be in front of the model regardless of who's on stage. Editing it invalidates the prefix cache, so it's expensive to fiddle with mid-session.
- **Scene summaries (2)** — frozen recaps of completed arcs. Append-only by design: the user clicks "Scene break" when an arc closes and the live rolling summary becomes a permanent block.
- **Rolling summary (3)** — moving recap of unsummarised history. Auto-triggers at budget pressure; replaced wholesale on each run.
- **Entity store (4)** — structured per-character/location/item/relationship/event facts. **Selective**: only emitted when the entity is mentioned in the last 6 turns. Lives below the cache boundary so it can change every turn without invalidating prefill. Salience-ranked since Step D.
- **Retrieval (5)** — semantic recall of older turns by embedding. Cheap, recomputed each send.
- **Tail reinforce (6)** — opt-in re-injection of pinned memory near the latest user turn to fight Gemma's first-turn-fold drift.

### Memory tab vs Entities tab

These two are the user's primary editing surfaces and the source of the most confusion post-migration. Concrete differences:

| | Memory tab (`chat.memory`) | Entities tab (`chat.entities`) |
|---|---|---|
| **Schema** | Free text, one fact per line | `Entity{name, aliases, type, facts[]}` with salience metadata |
| **Prompt position** | Top, always-on | Selective, attached to last user turn |
| **Cache impact** | Above boundary — edits invalidate prefill | Below boundary — edits are free |
| **Token cost** | All-or-nothing — every fact costs every send | Pay-per-mention — off-stage entities are zero |
| **Auto-populated?** | No, user-only | Yes, via suggestion-accept routing |
| **Per-fact telemetry?** | None | `mentionCount`, `lastReinforcedTurn`, `pinnedByUser` |
| **Tail reinforce reads it?** | Yes (per-chat toggle) | No |
| **Extractor "Already known" reads it?** | Yes | Yes |

**Migration overlap.** A chat that existed before Step C had every memory line copied into a one-fact entity. Memory was deliberately left untouched so the user could review the seeded entities before clearing. Today both tabs still show the duplicated content; the user clears Memory by hand once they're happy. **No automated dedup runs**, so promoting a fresh suggestion does not remove an equivalent line from `chat.memory` if one happens to exist there — they are independent stores.

### Is the Memory tab still needed?

Yes — **it serves a different role from Entities**, even after Step C/D. Keep it. Reasons:

1. **Always-on injection.** Some content needs to be in front of the model regardless of who's on stage: world rules ("magic costs HP"), narrator persona ("describe in second person, present tense"), GM directives ("never break character"), scene-level state ("it's raining; the village is under curfew"). None of these fit `Entity{name, type, facts}` cleanly, and gating them on substring match would silently drop them when the relevant noun isn't said out loud.
2. **OOC / instruction surface.** It's the natural slot for prompt-engineering tweaks the user wants to land high in the prompt without inventing a fake entity.
3. **Tail-reinforce backing store.** The §9.6 tail-reinforce digest reads `chat.memory` only. Killing the Memory tab without re-pointing tail-reinforce would silently break that feature.
4. **User-authored notes.** Sometimes the user just wants a freeform scratchpad that ships with the chat and the model can read. Forcing structure here is the wrong shape.

**Refinements worth making (not now, but track):**

- Rename to "Pinned memory" or "Always-on notes" so users stop assuming it's the same as Entities.
- After the user has interacted with the Entities tab, offer a one-click "this looks good — clear migrated lines from Memory" to dispatch the post-migration overlap. Detect by comparing memory lines to seeded entities by `[type] name — text` shape.
- Add a small explainer in the pane: "This block is always injected. For per-character facts, use Entities."

---

## Open questions / things to watch

- **Cadence default.** 8 user turns is a guess; test long-form vs action-heavy. Per-chat overrides for cadence (in addition to scan window) might be worth adding.
- **Suggestion fatigue.** Exact-string dedup catches the obvious case but the model sometimes paraphrases. Embedding-based similarity could help (we already have embeddings via retrieval) — only worth wiring if duplicates become a real annoyance.
- **Cross-chat memory** (research §9.9): same character across chats. Out of scope here; revisit after Step C ships and we have an entity model to work with.
- **Multi-character voice / style block** (research §9.8): independent of the entity work. Could land any time.
- **Tail reinforce + entity store interaction**: once the entity store is selective, tail reinforce becomes redundant for on-stage characters. Keep the toggle but rename to "Reinforce off-stage facts" if needed.
- **Failed extractions advance the cadence pointer.** A network blip silently skips that window. If this gets noisy, add a retry-once-on-failure path.
- **Holistic tuning pass — deferred.** Step C shipped working but several rough edges deserve a focused tuning session, not piecemeal fixes:
  - **Extractor attribute-on-known-entity blindness.** Small models read "entity exists in Already Known" as "everything about it is known" and skip new attributes (age, physical description, clothing). A first-pass mitigation landed 2026-05-03 (rule reordering + relabelling the entity-store block as partial); needs eval to confirm it actually moves the needle, and may need stronger framing — e.g. an explicit example pair, or splitting the "known" block into "facts to skip" vs "entities to enrich."
  - **Layer interaction is unmodelled.** The pinned-memory tab, entity store, scene summaries, rolling summary, retrieval, and tail-reinforce digest all coexist but were designed in isolation. Likely overlap (same fact lands in 2–3 places) and likely gaps (a fact mentioned 50 turns ago, never promoted, falls out of every layer). Worth a survey: for each layer, what does it own, what does it duplicate, what triggers eviction, and which layer is canonical when they disagree?
  - **Memory tab post-migration.** After Step C migration the user has facts duplicated in Memory (untouched) and Entities (seeded copies). Plan was "user clears Memory by hand" — fine for now, but if it lingers we should add a one-click "this migration looks good, clear Memory" button or quietly empty `chat.memory` once the user has interacted with the entities pane.
  - **Selective-injection signal quality.** Substring match on entity name + aliases is the floor. False positives (e.g. "Sage" the herb), false negatives (pronoun-only references). When this matters, consider: per-entity `injectionMode` (always / keyword / never), better tokenisation (word-boundary match), or a tiny scoring pass over recent turns.

---

## Order of operations recap

| Step | State | Effort | Unlocks |
|---|---|---|---|
| A — Suggestion queue | ✅ shipped | ½ day | Trust layer; eval becomes safe-by-default |
| B — Auto-trigger + per-chat config + library | ✅ shipped | ~1 day | Hands-off extraction loop |
| C — Entity store | ✅ shipped 2026-05-03 | 3-5 days | Selective injection; memory stops being budget-bound |
| D — Salience | ✅ shipped 2026-05-03 | ½ day | Smart eviction; hot/stale visualisation |

A–D shipped. The next memory-system work is the **holistic tuning pass** captured under "Open questions" — not a new piecemeal feature. See [`NEXT_STAGES.md`](NEXT_STAGES.md) for the broader app roadmap and which item the user should pick up first.

### Working on this codebase — operational notes

- **Build**: `./build.sh` (release build + ad-hoc codesign into `RPClient.app`).
- **Launch**: `./run.sh` — runs the binary in-place via terminal so it inherits Local Network permission. **Do not** use `open RPClient.app`; ad-hoc re-signing on every rebuild revokes TCC permission, and the model/context probes silently fall back to a 4 K default.
- **Tests**: `swift run RPClientCoreTests` (homegrown TestKit, not XCTest — Xcode isn't installed on this machine).
- **Source layout**: `Sources/RPClientCore/` (library: models, prompt, memory, UI panes), `Sources/RPClient/` (executable shim).

Recommended next session opening prompt:
> Open [`NEXT_STAGES.md`](NEXT_STAGES.md) and pick up whichever item is flagged as the user's choice. The memory subsystem (Steps A–D) is shipped; the holistic tuning pass it depends on is captured under "Open questions / things to watch" in [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md). Build with `./build.sh && ./run.sh`. Tests are `swift run RPClientCoreTests` (homegrown TestKit; Xcode isn't installed).
