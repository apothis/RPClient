# Retrieval pipeline

Vector search over chat history. Off by default. Built from four pieces:

| Component | Role |
|---|---|
| [Chunker](Sources/RPClientCore/Memory/Chunker.swift) | Slices chat history into rolling windows. |
| [ContextBlurber](Sources/RPClientCore/Memory/ContextBlurber.swift) | Side-call that produces a "place this in the story" blurb per chunk. |
| [VectorStore](Sources/RPClientCore/Memory/VectorStore.swift) | Per-chat persistent embedding index. |
| [RetrievalEngine](Sources/RPClientCore/Memory/RetrievalEngine.swift) | Glue: indexes new chunks, runs cosine search at prompt-build time. |

User-facing description in [Memory: retrieval](memory-retrieval).

## Chunking

[Chunker.swift](Sources/RPClientCore/Memory/Chunker.swift). Rolling windows over the chat:

- **Window size** — 4 turns.
- **Overlap** — 1 turn (so neighbouring chunks share one turn).
- **Stride** — `windowSize − overlap = 3`.
- **Trailing partial** — emitted as long as it covers at least 2 turns.

```
Turns:  [0][1][2][3][4][5][6][7][8][9]
Chunks: [────w────]
                 [────w────]
                          [────w────]
                                   [─w*─]   ← trailing partial (≥2)
```

Tuned per `MEMORY_RESEARCH.md §9.1`. Per-turn chunks are too small (match on filler words); per-scene chunks are too fuzzy without explicit boundaries. 4-with-overlap is the empirical sweet spot.

A `Chunk` carries its `firstTurnIdx`, `lastTurnIdx`, and the formatted body (`User: …\n\nAssistant: …`). The id is derived from the chat id + turn range, so re-chunking the same range produces the same id and the embedding cache hits.

## Contextual blurbs

When `RetrievalSettings.contextual = true` (default), [ContextBlurber.run](Sources/RPClientCore/Memory/ContextBlurber.swift) is called per new chunk to produce a 1–2 sentence "place this snippet in the story" preamble. The blurb is concatenated with the chunk body before embedding.

This is the Anthropic contextual-retrieval recipe — reported ~49% reduction in retrieval failures vs. naked-chunk embeddings. The cost is one short side-call per new chunk during indexing; recurring per-turn cost is zero (existing embeddings are reused).

The blurber assembles a "background" string from `chat.memory + chat.summary` and asks the model to situate the snippet within it. The output is *not* the prompt-injected text — it's only used to guide the embedding.

## Vector store

[VectorStore.swift](Sources/RPClientCore/Memory/VectorStore.swift). One per chat, persisted to `~/Library/Application Support/RPClient/vectors/<chat-uuid>.vec.json`.

- `upsert(_:)` — add or replace a chunk.
- `remove(id:)` — drop by id.
- `invalidate(turnIndices:)` — drop any chunk whose turn range overlaps the given indices. Used when a turn is edited.
- `clampToTurnCount(_:)` — drop any chunk whose `lastTurnIdx` is at or beyond the count. Used when the chat shrinks.
- `search(query:topK:exclude:)` — cosine similarity over normalised vectors, returns top-K with scores.

Search is naive O(N) — fine at the scale of a per-chat index (hundreds to low thousands of chunks). No HNSW, no IVF; the simplicity is the point.

The `Hit` struct carries the chunk + cosine score. Hits below `RetrievalSettings.threshold` (default 0.70) are filtered before return.

## RetrievalEngine

[RetrievalEngine.swift](Sources/RPClientCore/Memory/RetrievalEngine.swift). Owns the per-chat store registry and runs both indexing and retrieval.

### Indexing

`index(chat:kobold:contextual:effectiveCtx:completion:)`:

1. Generate the desired chunk set via `Chunker.chunks(for: chat)`.
2. Diff against the store: drop stale ids, identify chunks needing embedding (new or text-changed).
3. If `contextual`, run `ContextBlurber.run` on each new chunk to produce a blurb.
4. Embed in batches via `embedBatched` ([RetrievalEngine.swift:176](Sources/RPClientCore/Memory/RetrievalEngine.swift)) — sequential, not parallel, because KoboldCpp's embedding endpoint serialises requests anyway.
5. Upsert the embedded chunks back into the store and `save()`.

Indexing is triggered by `AppState.kickIndexing`, which fires after every assistant reply (debounced).

### Retrieval

`retrieve(query:chat:settings:completion:)`:

1. Embed the user's current query.
2. Build `excludePredicate` ([RetrievalEngine.swift:227](Sources/RPClientCore/Memory/RetrievalEngine.swift)) — see below.
3. `store.search(query:topK:exclude:)` returns hits.
4. Pass back to `PromptBuilder.formatRelevantMemories` for prompt formatting.

### Eligibility

The `excludePredicate` is the load-bearing rule. A chunk is eligible iff its `lastTurnIdx` is below **both**:

- The recency cutoff: `head − settings.recencyExclusion`.
- The rolling-summary cutoff: `chat.summarizedThrough`.

Translated: only chunks that are old enough *and* already summarised away are eligible. Until both cutoffs cross a chunk, the chunk is still in the verbatim window — there's no point retrieving it because the model is reading the source already.

This is the most common reason a fresh chat shows `0 chunks indexed`: the rolling summary hasn't advanced far enough yet.

## Embeddings server requirement

KoboldCpp must be running with `--embeddingsmodel` for any of this to work. `KoboldClient.fetchEmbeddingInfo` ([KoboldClient.swift:199](Sources/RPClientCore/KoboldClient.swift)) probes for an embeddings model and surfaces the result; the Retrieval pane uses this to render "no embeddings model configured on the server" instead of silently doing nothing.

## Persistence ordering

Chunks save **immediately after embedding** (within `RetrievalEngine.index`'s completion). A crash mid-indexing leaves a vector store with N chunks embedded and the rest still pending — the next indexing run picks up where it left off, because the diff in step 2 above identifies what's still missing.

Safe to delete `vectors/<uuid>.vec.json` by hand; RPClient re-indexes from scratch on the next save.
