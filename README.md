# RPClient

A native macOS chat client for interactive roleplay and long-form collaborative fiction against a local [KoboldCpp](https://github.com/LostRuins/koboldcpp) LLM server. Built with AppKit (not SwiftUI), zero third-party dependencies, and a layered memory system designed to keep narratives coherent across long sessions.

---

## Features

### Core
- **SSE streaming** — tokens appear as they generate, with abort and regenerate support
- **Chat history** — multiple named chats, persisted atomically to disk (no data loss on crash)
- **Sampler presets** — temperature, top-p, top-k, min-p, rep-pen, sampler order; selectable per chat
- **Per-reply token cap** — override the preset's max-length on a per-reply basis
- **Model status bar** — shows active model name, tokens/s, and context fill percentage
- **Editable turns** — click any message to edit and regenerate from that point
- **Markdown rendering** — bold, italic, code blocks rendered in the chat view

### Templates
Two prompt formats are supported, selectable globally or per-chat:

| Template | For | Notes |
|----------|-----|-------|
| **Gemma** | Gemma 2/3 models | No system role; inlines memory into the first human turn |
| **Qwen3** | Qwen3 models | ChatML format with optional thinking-block passthrough |

### Memory System
RPClient implements a multi-tier memory pipeline to keep context meaningful across long chats:

| Layer | Description | Token cap |
|-------|-------------|-----------|
| **Pinned facts** | User-curated notes always injected near the top | ~800 tokens |
| **Rolling summary** | Auto-compressed summary of older history | ~350 tokens |
| **World info** | Keyword-triggered lore entries (e.g. place names, factions) | Per-entry |
| **Author's note** | Free-text injection at a configurable depth before the last turn | Configurable |
| **Fact extraction** | Model side-call every N turns to suggest relationship/entity facts | — |
| **Semantic retrieval** *(V2)* | Vector-embedded chunks retrieved by cosine similarity to the current message | Configurable |
| **Entity store** *(V2)* | Structured character/location/faction facts with selective injection | — |
| **Scene summaries** *(V2)* | Hierarchical frozen snapshots of completed scenes | — |

The prompt is assembled with a **cache-aware layout**: stable content (facts, summary, world info) is placed above a cache boundary, and changing content (recent turns, author's note) below it. This lets KoboldCpp's SmartCache reuse the KV cache across turns, significantly reducing time-to-first-token on long chats.

### Inspector Panel
A collapsible right-side panel provides live access to all memory layers:

- **Memory** — view and edit pinned facts
- **Summary** — view the current rolling summary
- **Author's Note** — edit the injected note and insertion depth
- **Suggestions** — review and approve facts extracted by the model
- **Entities** — browse the structured entity store *(V2)*
- **Retrieval** — see which past chunks were semantically retrieved *(V2)*

---

## Requirements

- macOS 13.0 or later
- Swift (command-line tools; Xcode IDE is not required)
- A running [KoboldCpp](https://github.com/LostRuins/koboldcpp) server on your local network (default: `http://localhost:5001`)

No internet connection is required at runtime. All generation happens locally via KoboldCpp.

---

## Build

```bash
./build.sh
```

This runs `swift build -c release`, assembles `RPClient.app`, and ad-hoc codesigns it.

---

## Run

**Via run script** (recommended for development — bypasses macOS Local Network privacy re-prompts caused by ad-hoc signing):

```bash
./run.sh
```

**Via Finder / Dock** — double-click `RPClient.app` as normal. You may be prompted to allow Local Network access on first launch.

---

## Test

Tests use a homegrown `TestKit` harness (not XCTest) so they run without Xcode:

```bash
./test.sh
# or equivalently:
swift run RPClientCoreTests
```

| Test file | Coverage |
|-----------|----------|
| `TemplateTests.swift` | Prompt assembly for Gemma and Qwen3; scene blocks; author's note depth |
| `PromptBuilderTests.swift` | Token budgeting; context truncation; memory cap enforcement |
| `VectorStoreTests.swift` | Embedding storage and cosine-similarity retrieval |
| `ChunkerTests.swift` | Text chunking for semantic search |
| `ChatCodableTests.swift` | Chat JSON serialization round-trips |
| `MemoryAuditRegressionTests.swift` | Regression suite from MEMORY_AUDIT.md findings |

---

## Configuration

Settings are stored in `~/Library/Application Support/RPClient/settings.json` and edited via the **Settings** window inside the app.

| Setting | Description | Default |
|---------|-------------|---------|
| Server URL | KoboldCpp endpoint | `http://localhost:5001` |
| Template | Prompt format (`gemma` / `qwen`) | `gemma` |
| Default sampler preset | Starting sampler for new chats | — |
| Max context override | Cap context below the server's reported max (0 = use server value) | 0 |
| Reply tokens override | Per-reply token cap (0 = use preset value) | 0 |
| Fact extraction | Enable/disable auto fact extraction | On |
| Extraction cadence | Runs every N turns | 4 |
| Qwen3 thinking blocks | Pass through `<think>` blocks in Qwen3 responses | Off |

Chat files and per-chat vector stores are saved under:
```
~/Library/Application Support/RPClient/
  settings.json
  chats/<uuid>.json
  vectors/<uuid>.vec.json
```

---

## Project Structure

```
Sources/
  RPClient/
    main.swift                  — NSApplication entry point
  RPClientCore/
    AppDelegate.swift           — Window lifecycle, menu bar
    AppState.swift              — Centralized state; server health polling
    KoboldClient.swift          — URLSession SSE streaming, API calls
    PromptBuilder.swift         — Multi-tier prompt assembly with token budgeting
    Storage.swift               — Atomic JSON I/O
    Templates.swift             — PromptTemplate protocol
    GemmaTemplate.swift
    QwenTemplate.swift
    ThinkBlockFilter.swift      — Strips/passes Qwen3 <think> blocks
    DebugLog.swift
    Memory/
      TokenBudget.swift         — Token counting and budget enforcement
      Summarizer.swift          — Auto-compression side-calls
      FactExtractor.swift       — Entity/relationship extraction via model side-call
      Chunker.swift             — Text chunking for semantic search
      VectorStore.swift         — In-process vector store with cosine similarity
      RetrievalEngine.swift     — Semantic retrieval orchestration (V2)
      ContextBlurber.swift      — Context blending utilities
    Models/
      Chat.swift                — Chat data model (memory, turns, entities, summaries)
      Turn.swift                — Individual message with metadata
      Settings.swift            — App-wide settings model
      Entity.swift, Fact.swift, SceneSummary.swift
      AuthorsNote.swift, WorldInfoEntry.swift
      SamplerPreset.swift, Chunk.swift
    UI/
      ChatViewController.swift  — Main chat view with streaming display
      SidebarViewController.swift
      InputBar.swift            — User input + Send / Stop / Regenerate
      SettingsWindowController.swift
      StatusBar.swift           — Model name, tokens/s, context bar
      TurnView.swift
      Markdown.swift
      Theme.swift
      ContextDivider.swift
      EmptyStateView.swift
      FactExtractorEvalWindow.swift
      Inspector/
        InspectorViewController.swift
        MemoryPane.swift
        SummaryPane.swift
        AuthorsNotePane.swift
        SuggestionsPane.swift
        EntitiesPane.swift
        ExtractionPane.swift
        RetrievalPane.swift

Tests/
  RPClientCoreTests/
    main.swift                  — Test runner entry point
    TestKit.swift               — Custom test harness
    TemplateTests.swift
    PromptBuilderTests.swift
    VectorStoreTests.swift
    ChunkerTests.swift
    ChatCodableTests.swift
    MemoryAuditRegressionTests.swift
```

---

## Architecture Notes

- **No SwiftUI** — all UI is programmatic AppKit (`NSView` / `NSViewController` subclasses). This keeps build times fast and avoids SwiftUI state-management complexity in a streaming context.
- **No third-party dependencies** — stdlib + AppKit only. `Package.swift` has no external package declarations.
- **Concurrency model** — URLSession background queues for networking; all UI updates dispatched to main thread. No async/await (avoids minimum deployment version pressure).
- **Atomic writes** — `Storage.swift` writes to a temp file then renames, so a crash mid-write never corrupts a chat file.
- **Ad-hoc signing** — `build.sh` signs with `-` (ad-hoc). For distribution or stable Local Network privacy grants across rebuilds, replace with a real Developer ID certificate.

---

## Network Security

RPClient connects to KoboldCpp over plain HTTP (no TLS). This is intentional: KoboldCpp runs locally or on a trusted LAN, and adding TLS to a localhost server is not standard practice for local inference tools. `Info.plist` sets `NSAllowsArbitraryLoads: true` to permit this.

If you expose your KoboldCpp server beyond a trusted network, you should add TLS and authentication at the network layer (e.g. via a reverse proxy) rather than inside this client.

---

## License

MIT
