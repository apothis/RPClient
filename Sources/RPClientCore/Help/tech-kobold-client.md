# KoboldClient & SSE

The network layer is two cooperating pieces:

- **[KoboldClientRegistry.swift](Sources/RPClientCore/KoboldClientRegistry.swift)** — registry of `KoboldClient` instances, one per `ServerProfile`. Owns the role-routing logic.
- **[KoboldClient.swift](Sources/RPClientCore/KoboldClient.swift)** — the per-server transport. One URLSession, three categories of endpoint: streaming generation, side-call generation, and metadata probes.

`AppState` never instantiates a client directly any more; it asks the registry for the right one via `registry.client(for: role, chatOverride:)`. The registry resolves the profile id, returns a cached client (or mints one), and the call site uses it like any other `KoboldClient`.

## KoboldClientRegistry

[KoboldClientRegistry.swift](Sources/RPClientCore/KoboldClientRegistry.swift). Two responsibilities:

1. **Cache one client per profile.** Identity matters — keeping the same `KoboldClient` instance across lookups preserves URLSession state and the per-client token-count cache. Side-call dispatch and chat generation may resolve to the same client many times per turn; minting fresh clients each time would lose every cache hit.
2. **Resolve roles to profile ids.** `client(for: ServerRole, chatOverride: UUID?)` walks a small priority chain depending on the role.

### Role routing

```swift
enum ServerRole: String, Codable, CaseIterable, Equatable {
    case general
    case summarizer
    case extractor
    case embeddings
}
```

Resolution rules ([KoboldClientRegistry.swift:47](Sources/RPClientCore/KoboldClientRegistry.swift)):

- **`.general`** — `chatOverride` (per-chat server pin) ?? `defaultServerId`.
- **`.summarizer`** — `summarizerServerId` ?? `defaultServerId`.
- **`.extractor`** — `extractorServerId` ?? `defaultServerId`.
- **`.embeddings`** — `embeddingsServerId` ?? `defaultServerId`.

Each step is gated on **liveness**: if a referenced id is no longer in `settings.servers`, the resolver treats it as `nil` and continues down the chain. This is the recovery path when a profile gets deleted while a role still references it.

If even the default is corrupt, `client(for:)` returns a `cachedFallback()` pointing at `localhost:5001` so the network layer fails gracefully (an HTTP error to a localhost that isn't there) rather than crashing the resolver.

### Settings updates

`updateSettings(_:)` re-points existing cached clients in place rather than minting new ones:

```swift
for profile in s.servers {
    if let existing = cache[profile.id], existing.baseURL != profile.baseURL {
        existing.setBaseURL(profile.baseURL)
    }
}
```

The point of preserving identity: a token-count cache built up over the chat's lifetime survives a URL edit. Mint-on-update would invalidate the cache and produce a slow turn after every settings change.

Removed profiles get evicted from the cache.

### Thread model

Settings updates and client lookups both happen on the main thread today (every AppState callsite). If lookups ever move off the main thread, add a lock around `cache` and `current`.

## Per-server KoboldClient

Each profile gets its own `KoboldClient` once it's first looked up. The class itself is unchanged from the pre-V8 single-client world — it doesn't know about the registry. From its perspective it's still one URLSession against one base URL.

### Endpoint map

| Method | Path | Purpose |
|---|---|---|
| `generateStream` | `POST /api/extra/generate/stream` | Streaming reply (SSE). |
| `generate` | `POST /api/v1/generate` | Side-call reply (summarizer / extractor / blurber). |
| `embed` | `POST /api/extra/embeddings` | Vector embeddings for retrieval. |
| `tokenCount` | `POST /api/extra/tokencount` | Per-block token counts for the budget allocator. |
| `fetchModel` | `GET /api/v1/model` | Model name (for status bar + template detect). |
| `fetchTrueMaxContext` | `GET /api/extra/true_max_context_length` | Server-reported context window. |
| `fetchEmbeddingInfo` | derived | Embedding model probe (vector retrieval prerequisite check). |
| `fetchPerf` | `GET /api/extra/perf` | tokens-per-second after the latest reply. |
| `cancel` | `POST /api/extra/abort` + `URLSessionTask.cancel` | Best-effort abort. |

## Streaming (SSE)

`generateStream` builds the JSON body from the request's `SamplerPreset` plus the `prompt` and `stopSequences`, sets `stream_sse: true`, and starts a `URLSessionDataTask`. The `KoboldClient` itself is the `URLSessionDataDelegate`:

- `didReceive data:` appends to `streamBuffer` and calls `processBuffer()`.
- `processBuffer` slices on SSE frame boundaries (`\n\n`) and forwards complete frames to `handleFrame`.
- `handleFrame` parses the `data: {...}` line, extracts the `token` field, and invokes `onToken`.
- `didCompleteWithError:` invokes `onFinish(error)` once, then clears the active task.

The buffer is `Data`, not `String` — partial UTF-8 sequences can land at chunk boundaries; converting on-buffer would corrupt them. We slice on `\n\n` byte boundaries first, only converting complete frames.

`onToken` is dispatched to whichever queue `URLSession`'s delegate queue lands on — *not* the main queue. The chat view's [AppState.appendStreamToken](Sources/RPClientCore/AppState.swift) is the immediate handler; it dispatches to `.main` before mutating the chat.

## Side-call generation

`generate(...)` is the synchronous-style sibling. Same shape as the body in `generateStream` minus `stream_sse`. The result is buffered in full and delivered to `completion` once. Used by:

- [Summarizer](Sources/RPClientCore/Memory/Summarizer.swift)
- [FactExtractor](Sources/RPClientCore/Memory/FactExtractor.swift)
- [ContextBlurber](Sources/RPClientCore/Memory/ContextBlurber.swift)

The `activeSideCallTask` is held separately from `activeTask` so a side-call doesn't get cancelled when a stream starts (and vice versa). A user-initiated **stop** cancels both.

## Abort semantics

`cancel()` does two things in sequence:

1. **Client-side** — `task.cancel()` on the active `URLSessionDataTask`. This stops the client from reading more bytes; the server may still produce more.
2. **Server-side** — fire-and-forget `POST /api/extra/abort`. KoboldCpp stops generating. We don't wait for the response.

This double-action is necessary because cancelling the URLSession task only stops the local read; without the server-side abort, KoboldCpp keeps generating for a while (and is unavailable to start the next request until it's done). The order matters too — cancel locally first, *then* tell the server, so we don't race a fresh request against a still-generating server.

## Token counting

`tokenCount` is what [TokenBudget.assemble](Sources/RPClientCore/Memory/TokenBudget.swift) calls for every memory block. There's a `TokenCounter.shared` ([Memory/TokenBudget.swift:4](Sources/RPClientCore/Memory/TokenBudget.swift)) that wraps `KoboldClient.tokenCount` so the rest of the code calls a stable interface. Each block is one call; calls are batched with a `DispatchGroup` so the budget assembles in roughly the time of one round-trip rather than N.

The result is fed into `BudgetUsage` and surfaced as the status-bar context-fill bar.

## Embeddings

`embed(text:)` returns a `[Float]` for retrieval. The retrieval engine batches calls in `embedBatched` ([Memory/RetrievalEngine.swift:176](Sources/RPClientCore/Memory/RetrievalEngine.swift)) — one batch is sent at a time, with the next batch fired from the previous batch's completion. Sequential-not-parallel is deliberate: KoboldCpp's embedding endpoint serialises requests anyway and the latency-vs-throughput tradeoff isn't worth the parallelism complexity.

## Errors

`KoboldError` has three cases:

- `.badURL` — the configured server URL is malformed.
- `.http(Int, String)` — non-2xx response with status + body snippet.
- `.transport(Error)` — wrapped `URLSession` error (timeout, host unreachable, etc.).

The transport-error classifier `AppState.isTransportError` ([AppState.swift:457](Sources/RPClientCore/AppState.swift)) is what the health-check loop uses to flip the status bar's reachable indicator.

## Health checks

`AppState.startHealthChecks(intervalSeconds:)` ([AppState.swift:443](Sources/RPClientCore/AppState.swift)) starts a periodic probe (default every 30s) that calls `fetchModel`. On the reachable→unreachable edge, `serverReachableChanged` fires and the status bar pops a one-shot warning sheet.

This is independent of generation — even an idle app keeps its reachable-indicator current.
