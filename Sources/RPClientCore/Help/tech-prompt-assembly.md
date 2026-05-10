# Prompt assembly

This page is the contract between the memory subsystem and the model. If the layout drifts, the symptoms are subtle: replies feel "right" but cost twice the tokens-to-first-token, or memory fights with verbatim history and the model forgets things it shouldn't.

The contract has three load-bearing pieces:

1. A **cache-aware layout** that lets KoboldCpp's SmartCache reuse prefilled KV state.
2. A **per-template assembly** ([PromptBuilder.build](Sources/RPClientCore/PromptBuilder.swift) → `Templates.byId(...).assemble(...)`) that writes role markers correctly.
3. A **token-budget allocator** ([Memory/TokenBudget.swift](Sources/RPClientCore/Memory/TokenBudget.swift)) that resolves overcommit by truncating leading verbatim turns, never memory blocks.

## Cache-aware layout

Top-to-bottom — exactly the order [PromptBuilder.swift:5](Sources/RPClientCore/PromptBuilder.swift) specifies:

```
[stable above the boundary — invalidate sparingly]
  1. system prompt (immutable per session)
  2. style block            (V2 — reserved)
  3. pinned-fact memory     (rare edits)
  4. rolling summary        (between-turn updates only)
  5. scene summaries        (append-only via "Scene break")
  6. older verbatim turns
─── cache boundary ───────────────────────────────────
[recomputed each turn — anything below this point is cheap to change]
  7. vector retrieval block (V2)
  8. entity block           (selective, on-stage entities only)
  9. recent verbatim turns
 10. author's note(s) at depth ≥ 1
 11. tail memory reinforcement
 12. new user turn
```

The contract: **anything that changes per turn lives below the cache boundary**. Everything above it changes only when the user edits memory or the rolling summarizer fires. KoboldCpp can reuse the prefill prefix as long as the bytes above the boundary match — moving even one stable block below the boundary, or one volatile block above, cuts cache reuse to zero and TTFT goes from ~50ms to several seconds on long chats.

This is why pinned facts, rolling summary, and scene summaries are placed near the top — even though intuition says "important things last." The "important last" intuition is correct *within* the cache-volatile region (slots 7–12); it is incorrect *across* the boundary, where the cost of moving an important block above is much higher than the benefit of reciting it last.

## Per-template assembly

`PromptBuilder.build` ([PromptBuilder.swift:153](Sources/RPClientCore/PromptBuilder.swift)) is the single entry point. It resolves all the layered blocks (memory, summary, world info hits, entities, etc.) and forwards them to the active template's `assemble`:

- [GemmaTemplate.swift](Sources/RPClientCore/GemmaTemplate.swift) — no system role; folds memory and summary into the *first* user turn. Place markers `<start_of_turn>user`, `<start_of_turn>model`, `<end_of_turn>`.
- [QwenTemplate.swift](Sources/RPClientCore/QwenTemplate.swift) — ChatML format with `<|im_start|>system`, `<|im_start|>user`, `<|im_start|>assistant`. Memory and summary go in the system role. Optional `<think>…</think>` passthrough controlled by `Settings.qwenThinkingEnabled`.

The template protocol ([Templates.swift:3](Sources/RPClientCore/Templates.swift)) is intentionally wide: every memory layer is a named parameter to `assemble`. Adding a new layer means a new parameter, which forces every template to opt in or explicitly drop it. There is no implicit "all blocks merged" path.

## Last-user-turn extras

There are blocks that attach to the **latest user turn** rather than living globally above the cache boundary. These are computed in `PromptBuilder` but rendered into the last `<start_of_turn>user` segment by the template:

- **Entity block** ([PromptBuilder.entitiesBlock](Sources/RPClientCore/PromptBuilder.swift)) — only entities mentioned in the last few turns; supersedes stale facts within topic buckets.
- **Retrieval block** — `relevantMemories` formatted by `PromptBuilder.formatRelevantMemories`. Placed *before* the user's actual message text — the load-bearing fix for "model starts replying before my message."
- **Tail memory digest** ([PromptBuilder.tailMemoryDigest](Sources/RPClientCore/PromptBuilder.swift)) — opt-in pinned-fact reinforcement after the user's message.
- **Author's note** at the configured depth.
- **Current-scene anchor** ([PromptBuilder.currentSceneAnchor](Sources/RPClientCore/PromptBuilder.swift)) — present only when scene summaries exist; suppressed in continuation mode.

## Continuation mode

When the user clicks **continue** on a partial assistant turn, `PromptBuilder.build` is called with `continuation: true`. This:

- Suppresses the current-scene anchor (the model is mid-reply; no need to re-orient).
- Skips the tail memory digest.
- Leaves the assembly otherwise identical so cache reuse is preserved.

The flag is set once in [AppState.continueGeneration](Sources/RPClientCore/AppState.swift) and threaded through. Test coverage in `MemoryAuditRegressionTests.anchor is suppressed in continuation mode`.

## Token-budget overflow

When the assembled prompt would exceed `effectiveCtx − replyReserve`, the budget allocator drops verbatim turns from the **front** (oldest first), never trimming memory blocks. The number of dropped turns surfaces as `PromptAssembly.truncatedTurns` ([Memory/TokenBudget.swift:51](Sources/RPClientCore/Memory/TokenBudget.swift)).

The chat view's **context divider** is the visible representation of where this cut would land for the next send. Drag the divider to override.

## Where each block is computed

| Block | Source |
|---|---|
| Memory (pinned + card prefix + system_prompt) | `PromptBuilder.composeMemoryBlock` |
| Persona | `PromptBuilder.renderPersonaBlock` |
| Rolling summary | `Chat.summary` (string), set by [Memory/Summarizer.swift](Sources/RPClientCore/Memory/Summarizer.swift) |
| Scene summaries | `Chat.sceneSummaries`, frozen on Scene-break action; rendered by `PromptBuilder.SceneSummaryFormatter` with stale-age compression |
| World info hits | `PromptBuilder.worldInfoHits` → `WorldInfoInjector.matchingEntries` |
| Entity block | `PromptBuilder.entitiesBlock` |
| Retrieval | `RetrievalEngine.retrieve` → `PromptBuilder.formatRelevantMemories` |
| Tail digest | `PromptBuilder.tailMemoryDigest` |
| Current-scene anchor | `PromptBuilder.currentSceneAnchor` |

For the *why* behind the layout — especially the scene-staleness compression and current-scene anchor — see `MEMORY_AUDIT.md` and `MEMORY_HANDOFF.md` in the repo root. Those documents are the design record; this page is a navigation aid.
