# Memory pipeline

The memory subsystem is six layers feeding the prompt at every send. The contract is short enough to fit in one paragraph:

> Pinned memory and the entity store carry timeless facts; verbatim turns are authoritative for "now"; the rolling summary is authoritative for the immediate prior period; scene summaries are authoritative for completed prior arcs only — they must be framed as such and decoupled from "where are we now"; retrieval and the tail digest are reinforcement aids, not sources of truth.

Each layer's job is to surface what isn't already visible. When two layers fight (e.g. a vivid scene summary vs. recent verbatim narration of a *different* scene), the symptoms read like model hallucination but are actually layer-overlap. The current contract is the result of an iterative tuning pass documented in `MEMORY_AUDIT.md`.

## The layers

| Layer | Source of truth for | Lives in |
|---|---|---|
| **Pinned facts** | Timeless statements about the world / characters | `Chat.memory` (newline-joined string) |
| **Card prefix** | Imported character description, personality, scenario | `Character` model, injected by `PromptBuilder.renderCardPrefix` |
| **Rolling summary** | The immediate prior period (post-cache, pre-verbatim) | `Chat.summary`, written by [Summarizer](Sources/RPClientCore/Memory/Summarizer.swift) |
| **Scene summaries** | Completed prior arcs (frozen, past-tense framed) | `Chat.sceneSummaries` ([SceneSummary](Sources/RPClientCore/Models/SceneSummary.swift)) |
| **World info** | Lore that should appear contextually | `Chat.worldInfo` ([WorldInfoEntry](Sources/RPClientCore/Models/WorldInfoEntry.swift)) |
| **Entity store** | Structured per-entity facts, on-stage only | `Chat.entities` ([Entity](Sources/RPClientCore/Models/Entity.swift)) |
| **Retrieval** | Specific snippets the summary glossed over | [VectorStore](Sources/RPClientCore/Memory/VectorStore.swift) per chat |
| **Author's note** | How to write the next reply | `Chat.authorsNote` |

## Side-calls

Three side-calls run on background queues and never block the main reply path. They are gated behind explicit triggers, not run on every turn.

### Summarizer

[Memory/Summarizer.swift](Sources/RPClientCore/Memory/Summarizer.swift). Triggered by `AppState.maybeAutoSummarize` ([AppState.swift:1011](Sources/RPClientCore/AppState.swift)) when the verbatim window grows past an internal threshold relative to the context budget, or by the user via **File → Summarize Now** (⇧⌘S → `AppState.runSummarizer`).

The call assembles the *previous* summary plus the oldest verbatim turns that no longer fit, asks the model to produce a new summary, and writes it back to `Chat.summary`. The user-facing `summarizing…` activity label comes from `AppState.isSummarizing`.

### Fact extractor

[Memory/FactExtractor.swift](Sources/RPClientCore/Memory/FactExtractor.swift). Triggered every N user turns (configurable per chat from the Extraction pane, default 4). The call asks the model to identify facts worth remembering from the recent turns; results land in `Chat.pendingFactSuggestions` for the user to approve or dismiss in the Suggestions pane.

The extractor never writes directly to memory. Promotion is always user-driven — this is the trust layer that prevents auto-extraction from polluting the pinned facts.

### Context blurber

[Memory/ContextBlurber.swift](Sources/RPClientCore/Memory/ContextBlurber.swift). Side-call that synthesises a short blurb describing each retrievable chunk's content, used by the retrieval block to give the model *something readable* attached to a vector hit (rather than a raw embedding score).

## Rolling vs. scene summaries

These two are the most easily confused. The split:

- **Rolling summary.** One per chat. Continuously rewritten as the conversation advances. Authoritative for the *recent past* not in the verbatim window.
- **Scene summaries.** Append-only list. Created by **Scene break** in the Summary pane. Each scene summary freezes the rolling summary at the moment the scene ends, so the rolling summary can be cleared and start fresh for the next arc.

Scene summaries are framed as *completed prior arcs* — `[Earlier in the story — completed arc 2, turns 14–32]` — by [PromptBuilder.SceneSummaryFormatter](Sources/RPClientCore/PromptBuilder.swift). Stale scenes (whose `lastTurn` is more than 8 verbatim turns behind the head) get **compressed** at render time to a one-clause headline, so that a vivid 500-character description from 30 turns ago doesn't out-pull recent narration. This compression was the load-bearing fix for the 2026-05-03 regression — see `MEMORY_AUDIT.md §4` for the failure case.

## Entity store and topic supersession

Entities are typed records (`character`, `location`, `faction`, …) carrying a list of facts. Only entities mentioned in the recent turns ("on stage") have their facts injected — the budget cost of an entity not currently in play is zero.

Within a fact list, **render-time topic supersession** ([PromptBuilder.supersedeStaleFactsByTopic](Sources/RPClientCore/PromptBuilder.swift)) ensures only the most recent fact in a topic bucket reaches the prompt. Currently only the `clothing` bucket is implemented — added because a character was being described as *topless and naked simultaneously* when both states had been narrated. The supersession is render-time-only: storage keeps the full fact history.

Pinned facts and topicless facts (timeless attributes) bypass supersession.

## Retrieval

[Memory/RetrievalEngine.swift](Sources/RPClientCore/Memory/RetrievalEngine.swift). Off by default. Requires KoboldCpp running with `--embeddingsmodel`.

Pipeline:

1. [Chunker.chunks(for:)](Sources/RPClientCore/Memory/Chunker.swift) — splits the chat into chunks by turn boundary.
2. `RetrievalEngine.index` — embeds each chunk's blurb (annotated by the Context blurber) and upserts it into the per-chat [VectorStore](Sources/RPClientCore/Memory/VectorStore.swift).
3. `RetrievalEngine.excludePredicate` — gates which chunks are eligible. A chunk is eligible iff its `lastTurnIdx` is below **both** the recency cutoff (`head − exclude-last-N`) and the rolling-summary cutoff (`summarizedThrough`). Translated: only chunks that are old enough *and* already summarized away are eligible. This is the single most common reason a fresh chat shows `0 indexed`.
4. `RetrievalEngine.retrieve` — embeds the user's query and runs cosine search against the eligible chunks; returns top-K hits above the threshold.

Retrieval is a *reinforcement aid*. Pin facts you really need always present; tune the cosine threshold for facts you only sometimes need surfaced.

## World info matching

[Memory/WorldInfoInjector.swift](Sources/RPClientCore/Memory/WorldInfoInjector.swift). Per-turn keyword match, not vector. The matcher walks each enabled entry and decides whether it fires based on:

- **Injection mode** — `keyword` (match keys), `always` (fire every turn), or `vectorized` (reserved; a no-op today).
- **Match scope** — `recentTurns(N)`, `lastUserTurn`, or `entireChat`. The text scoped from the chat is what gets searched.
- **Keys** match case-insensitively on **word boundaries**. Substrings inside a longer word do not match.
- **Secondary keys** — optional AND-gate. If non-empty, the entry fires only if a primary key *and* a secondary key both appear in scope.

When the total token cost of all firing entries would exceed budget, entries are sorted by **priority desc, then name asc**, and packed greedily.

## Token-budget allocator

[Memory/TokenBudget.swift](Sources/RPClientCore/Memory/TokenBudget.swift). Computes per-block token counts via `KoboldClient` `count` endpoint (one call per block, batched with a `DispatchGroup`), then assembles the prompt and produces a `BudgetUsage` for the status-bar fill bar.

When the prompt would exceed `effectiveCtx − replyReserve`, the allocator drops leading verbatim turns until the budget fits. Memory blocks are never trimmed — the contract assumes pinned facts and the rolling summary are tighter than the verbatim history.

`BudgetUsage` is what the status bar's coloured segments are reading; the colour-to-block mapping lives in the [Status bar](status-bar) page.

## What the panes are surfacing

For the user-facing description of each layer, see the memory pages in the User Guide: [Pinned facts](memory-pinned-facts), [Rolling summary](memory-summary), [Author's note](memory-authors-note), [World info](memory-world-info), [Suggestions & extraction](memory-suggestions), [Entities](memory-entities), [Retrieval](memory-retrieval).
