# Summarizer

[Memory/Summarizer.swift](Sources/RPClientCore/Memory/Summarizer.swift). The rolling summarizer is a one- or two-call side-call to the model that compresses the oldest *unsummarized* verbatim turns into the chat's `summary` string.

It runs as a background side-call — never on the main reply path, never blocking generation.

## Trigger

Two paths:

1. **Auto** — `AppState.maybeAutoSummarize` ([AppState.swift:1011](Sources/RPClientCore/AppState.swift)) checks after every assistant reply whether the verbatim window has grown enough to be worth compressing. If yes, fires `Summarizer.run`.
2. **Manual** — `File → Summarize Now (⇧⌘S)` calls `AppState.runSummarizer` directly.

While running, `AppState.isSummarizing = true` drives the input bar's stop button and the status-bar `summarizing…` activity label.

## What it does

1. **Slice selection.** Starting from `chat.summarizedThrough`, walk forward summing per-turn token counts until ~25% of the effective context budget is hit. Always leave at least 4 trailing turns verbatim — never compress the immediate present.
2. **First-pass summary.** Format the selected slice as `User: …\n\nAssistant: …` and ask the model to write a concise paragraph preserving names, decisions, locations, items, relationship state. Instruction lives in `summarizeInstruction` ([Summarizer.swift:14](Sources/RPClientCore/Memory/Summarizer.swift)).
3. **Merge.** If `chat.summary` is non-empty, run a second call that combines `existing summary + new summary` into one cohesive summary, deduplicating overlap and keeping the latest state. Instruction in `mergeInstruction`.
4. **Persist.** `chat.summary` becomes the merged text; `chat.summarizedThrough` advances to the slice's end index.

## Two-call structure

The split-then-merge approach (rather than asking the model to "extend the existing summary with these new turns") is deliberate. Direct extension tends to either:

- **Drift** — the existing summary is treated as immutable scaffolding, and new facts are appended without dedupe; it grows unboundedly.
- **Lose state** — the model rewrites everything and discards facts from the existing summary it doesn't understand the context of.

The split-then-merge gives the merge call a clean comparison: two paragraphs of the same shape, asked to combine. Empirically this preserves more state than either alternative.

## Slice size tuning

The 25%-of-context target is heuristic. Larger slices give the model more material to summarise but cost more tokens per call; smaller slices fire more often. The chosen value was empirically the sweet spot at the time the pipeline was tuned (~late-Apr 2026); it lives as a magic number in `run` and has not been parameterised.

The 4-turn trailing floor is harder constraint: even if the budget would allow compressing into the recent turns, we don't, because verbatim recency is the model's primary cue for "where are we now."

## What it does *not* do

- **No turn deletion.** `summarizedThrough` is just an index — the original turns remain on disk and in `chat.turns`, just below the cache boundary in [PromptBuilder](tech-prompt-assembly).
- **No retrieval interaction.** Retrieval reads `summarizedThrough` to gate eligibility (see [tech-memory-pipeline](tech-memory-pipeline)) but the summarizer doesn't itself read retrieval results.
- **No fact extraction.** Suggestions come from a separate side-call ([FactExtractor](tech-fact-extractor)) and never share a prompt with the summarizer.

## Scene break vs. summarize

`File → Summarize Now (⇧⌘S)` advances the rolling summary in place. **Scene break** (Inspector → Summary pane → "Scene break") freezes the current rolling summary as a `SceneSummary` entry, then clears the rolling summary so the next arc starts from scratch.

Scene breaks are append-only (the freeze is permanent); summarize is the continuous compression that runs between breaks.

## Failure modes

- `SummarizerError.nothingToSummarize` — `summarizedThrough` is already at `turns.count`, or only the trailing floor turns remain. No-op; the user can keep going.
- `SummarizerError.generationFailed(_)` — the side-call to the model failed. The error is logged; `summarizedThrough` does not advance, so the next attempt starts from the same place.

If the side-call returns garbage (e.g. the model produced empty output or hit a stop sequence too early), the trimmed result becomes the new summary verbatim. The user can edit it in the Summary pane.
