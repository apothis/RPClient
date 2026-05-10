# AppState & UI wiring

[AppState.swift](Sources/RPClientCore/AppState.swift) is the central singleton every UI surface reads from and mutates through. There is no MVC, no MVVM, no Combine — just one shared object plus `NotificationCenter` for fan-out.

## What AppState owns

In rough order:

- **`chats: [Chat]`** — every loaded chat. Sorted by `modified` desc.
- **`currentChatId: UUID?`** — which chat the UI is showing.
- **`characters: [Character]`, `personas: [Persona]`** — the library.
- **`settings: Settings`** — global settings.
- **`registry: KoboldClientRegistry`** — owns one `KoboldClient` per `ServerProfile`, routes lookups by `ServerRole`. AppState never holds a single client instance any more; it asks the registry for the right one at every call site (chat reply, summarizer, extractor, embeddings). See [tech-kobold-client](tech-kobold-client) for the resolution rules.
- **`retrieval: RetrievalEngine`** — the per-chat vector store registry.
- **`isStreaming`, `isSummarizing`, `isExtracting`** — global flags driving the input-bar stop button + activity spinner.
- **`modelName`, `serverReachable`, `lastUsage`, `tokensPerSecond`** — status bar inputs.

## Mutation funnels

Every chat mutation goes through one of two helpers:

```swift
AppState.shared.updateCurrent { chat in chat.memory = "…" }
AppState.shared.updateChat(id: id) { chat in chat.title = "…" }
```

Both:

1. Find the chat in the array.
2. Pass it inout to the closure.
3. Persist via `Storage.saveChat`.
4. Fire `chatUpdated` (and `currentChatChanged` on first load).

This funnel is the single load-bearing invariant: **all chat mutations persist and notify**. The codebase doesn't have a "save" button anywhere because the funnel makes saves implicit.

## Notifications

`AppNotification` ([AppState.swift:4](Sources/RPClientCore/AppState.swift)) collects every notification name as a static. Listeners use the standard `addObserver(self, selector:)` pattern, and unregister in `deinit`.

| Notification | Meaning |
|---|---|
| `chatListChanged` | A chat was created, deleted, or reordered. |
| `currentChatChanged` | `currentChatId` changed. |
| `chatUpdated` | The current chat's contents changed. |
| `streamFinished` | An SSE stream ended (complete or aborted). |
| `streamToken` | A token arrived during streaming. (Used internally, but observable.) |
| `statusChanged` | Server probe / model info / usage updated. |
| `serverReachableChanged` | Reachable transitioned. |
| `fontChanged` | UI font offset changed. |
| `charactersChanged`, `personasChanged` | Library mutations. |
| `thinkingStateChanged` | Qwen3 `<think>` block opened or closed during stream. |

There is intentionally no observation hierarchy. If you mutate `chat.memory`, fire `chatUpdated` and the world updates. The cost is that every observer recomputes from scratch; the benefit is no "stale derived state" bugs.

## Generation entry points

The user-facing actions:

| Action | Method | Notes |
|---|---|---|
| Send message | `sendUserMessage(_:)` | Appends user turn, fires the stream. |
| Regenerate | `regenerate()` | Drops the trailing assistant turn or its variants and re-fires. Enforces variant cap. |
| Continue | `continueGeneration()` | Re-fires with `continuation: true` so PromptBuilder suppresses the scene anchor + tail digest. |
| Stop | `stop()` | Cancels both the active stream and any side-call. |
| Replace variant | `replaceCurrentVariant()` | Used by edit-then-regenerate. |
| Pick variant | `selectPrev/NextVariant(turnId:)` | Driven by ⌘← / ⌘→. |

All four of "send / regenerate / continue / replace" funnel into `assembleAndStream(...)` ([AppState.swift:763](Sources/RPClientCore/AppState.swift)), which:

1. Reads the chat snapshot.
2. Resolves the chat client via `registry.client(for: .general, chatOverride: chat.serverId)` — the per-chat pin wins, otherwise the global default.
3. Calls `TokenBudget.assemble(...)` to build the prompt + usage breakdown.
4. Calls `client.generateStream(...)` with `appendStreamToken` as the per-token handler.
5. On finish, persists the chat, fires `streamFinished`, and triggers the per-turn maintenance: `maybeAutoSummarize`, fact-extractor cadence check, retrieval re-index. Each of those resolves *its own* role through the registry, so a side-call can land on a different server than the chat reply did.

## Per-turn maintenance

After every assistant turn completes:

1. **Compute cache ratio** — `computeCacheRatio(newPrompt:)` ([AppState.swift:948](Sources/RPClientCore/AppState.swift)) compares the new prompt's prefix bytes against the previous one to estimate cache reuse. The result is informational; it doesn't change anything, but it's logged for diagnostic use.
2. **Maybe-summarize** — `maybeAutoSummarize` checks whether verbatim tokens have grown past the threshold; if so, fires the [Summarizer](tech-memory-pipeline) side-call.
3. **Maybe-extract** — if `factExtractionEnabled` and `userTurnCount % cadence == 0`, fires the [FactExtractor](tech-memory-pipeline) side-call.
4. **Re-index** — `kickIndexing` queues a retrieval re-chunk if vector retrieval is enabled.

Each of these can run independently and concurrently; they coordinate through their respective `is*` flags so the input bar's stop button still works while any of them is in flight.

## UI thread discipline

Most callbacks (`onToken`, side-call completions, health-check ticks) come back on URLSession's delegate queue, **not** the main queue. The pattern in `AppState` is to dispatch back to `.main` *before* mutating any published state:

```swift
DispatchQueue.main.async { [weak self] in
    self?.updateCurrent { c in c.turns[…].text += token }
}
```

The UI surfaces all assume they're being notified on the main queue. Don't observe from a background thread.

## Where each surface reads from

| Surface | Reads | Refresh trigger |
|---|---|---|
| Sidebar | `chats`, `currentChatId`, `detectedTemplateId` | `chatListChanged`, `chatUpdated`, `currentChatChanged`, `statusChanged` |
| Chat view | `currentChat`, `isStreaming`, `thinkingState` | `chatUpdated`, `streamToken`, `streamFinished`, `thinkingStateChanged` |
| Input bar | `isStreaming`, `isSummarizing`, `isExtracting` | `statusChanged`, `streamFinished` |
| Status bar | `modelName`, `effectiveContext`, `lastUsage`, `tokensPerSecond`, `serverReachable` | `statusChanged`, `chatUpdated`, `currentChatChanged`, `serverReachableChanged` |
| Inspector panes | `currentChat` (each pane reads what it needs) | `currentChatChanged`, `chatUpdated`, `fontChanged` |

That's the whole model. It's small, and that's the point.
