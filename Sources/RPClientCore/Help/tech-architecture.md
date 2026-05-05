# Architecture overview

RPClient is a native macOS AppKit application written in Swift, with zero third-party dependencies. There is no SwiftUI, no CoreData, no Combine — the codebase is intentionally small and explicit so it stays approachable.

## Targets

The package has three targets:

- **`RPClient`** — the executable. A 7-line entry point that builds an `NSApplication`, sets an `AppDelegate`, and runs the event loop. See [Sources/RPClient/main.swift](Sources/RPClient/main.swift).
- **`RPClientCore`** — the library. Everything else: models, storage, network, prompt assembly, memory subsystem, all UI code. The `Core` split exists so `@testable import RPClientCore` can run against internal types from a separate test executable.
- **`RPClientCoreTests`** — a homegrown TestKit runner. No XCTest; no Xcode required. Covered in the testing page (Slice 3b).

## High-level dataflow

```
                           ┌──────────────────────┐
                           │     AppDelegate      │
                           │ (window, menus, WCs) │
                           └──────────┬───────────┘
                                      │
                  ┌───────────────────┼───────────────────┐
                  │                   │                   │
            ┌─────▼─────┐       ┌─────▼─────┐       ┌─────▼─────┐
            │  Sidebar  │       │   Chat    │       │ Inspector │
            │  (chats)  │       │   view    │       │  (8 tabs) │
            └─────┬─────┘       └─────┬─────┘       └─────┬─────┘
                  │                   │                   │
                  └───────────────────┼───────────────────┘
                                      │ reads / mutates
                              ┌───────▼────────┐
                              │   AppState     │  ← single source of truth
                              │   (singleton)  │     for everything in-flight
                              └───────┬────────┘
                                      │
            ┌─────────────────────────┼─────────────────────────┐
            │                         │                         │
      ┌─────▼─────┐            ┌──────▼──────┐           ┌──────▼──────────────┐
      │  Storage  │            │PromptBuilder│           │KoboldClientRegistry │
      │  (atomic  │            │  (cache-    │           │  (one client per    │
      │   JSON)   │            │   aware)    │           │   ServerProfile,    │
      └───────────┘            └──────┬──────┘           │   role-routed)      │
                                      │                  └──────┬──────────────┘
                                      └─────────┬───────────────┘
                                                ▼
                                       one or more koboldcpp HTTP endpoints
```

`AppState` is the centre. Every UI surface reads from it and mutates it through one of two helpers:

- `AppState.updateCurrent { c in … }` — mutate the currently-selected chat.
- `AppState.updateChat(id:) { c in … }` — mutate any specific chat.

Both persist atomically and emit a `chatUpdated` notification for the UI to refresh against.

## Notification model

Cross-component refresh goes through `NotificationCenter`. The notification names are gathered as static properties on `AppNotification` ([AppState.swift:4](Sources/RPClientCore/AppState.swift)):

| Notification | Fires when | Listeners |
|---|---|---|
| `chatListChanged` | A chat is created or deleted. | Sidebar. |
| `currentChatChanged` | The selected chat changes. | All UI. |
| `chatUpdated` | The current chat's contents change. | Chat view, status bar, inspector panes. |
| `streamFinished` | An SSE stream ends (either complete or aborted). | Input bar, chat view. |
| `statusChanged` | Server probe / model info / token totals updated. | Status bar, sidebar. |
| `serverReachableChanged` | Reachable → unreachable transition. | Status bar warning sheet. |

Panes register on `viewDidLoad` and unregister in `deinit`. There's no Combine or Observation — `addObserver(self, selector:)` everywhere, deliberately.

## On-disk layout

Everything persisted lives under `~/Library/Application Support/RPClient/`:

```
RPClient/
├── settings.json
├── chats/
│   └── <uuid>.json          ← one file per chat
├── vectors/
│   └── <uuid>.json          ← per-chat vector store
├── characters/
│   ├── <uuid>.json
│   └── avatars/
│       └── <uuid>.png
└── personas/
    ├── <uuid>.json
    └── avatars/
        └── <uuid>.png
```

Writes go through `Storage.shared` ([Storage.swift](Sources/RPClientCore/Storage.swift)). Every save is **atomic** — write to a temp path, then `replaceItem(at:)`. A crash mid-write can never leave a half-written file.

## Templates

Two prompt templates are shipped: Gemma and Qwen3, both implementing the `PromptTemplate` protocol ([Templates.swift](Sources/RPClientCore/Templates.swift)). Selection is per-chat via `Chat.templateId`. The full `assemble(...)` signature is intentionally wide — adding a new memory layer means adding a parameter, not a side-channel.

## Network

The network layer is **two pieces**:

- **[KoboldClientRegistry.swift](Sources/RPClientCore/KoboldClientRegistry.swift)** — owns one `KoboldClient` per `ServerProfile` and routes lookups by `ServerRole` (`.general`, `.summarizer`, `.extractor`, `.embeddings`). Settings updates re-point existing clients in place so URLSession state and the per-client token-count cache survive.
- **[KoboldClient.swift](Sources/RPClientCore/KoboldClient.swift)** — the per-server transport. Wraps two endpoint families:
  - **Generation** — POST to `/api/extra/generate/stream`, parsed as Server-Sent Events. Tokens dispatched to `AppState.appendStreamToken`.
  - **Side-calls** — synchronous-style `generate` for the summarizer, fact extractor, and context blurber. They run on background queues and never go through SSE.

The registry is what makes per-chat server pinning and per-role side-call routing possible. The chat reply uses `client(for: .general, chatOverride: chat.serverId)`; each side-call uses its own role and falls back to the default when the role-specific server is unset or missing. Full details in [tech-kobold-client](tech-kobold-client).

Aborting a generation is a transport-level cancel of the inflight `URLSessionDataTask` on the right client, plus a fire-and-forget `POST /api/extra/abort` against the same server.

## Where things live (file map)

| Concern | File |
|---|---|
| App entry | [Sources/RPClient/main.swift](Sources/RPClient/main.swift) |
| Window + menus + window controller cache | [AppDelegate.swift](Sources/RPClientCore/AppDelegate.swift) |
| Central state singleton | [AppState.swift](Sources/RPClientCore/AppState.swift) |
| Storage / atomic JSON | [Storage.swift](Sources/RPClientCore/Storage.swift) |
| Network — registry / role routing | [KoboldClientRegistry.swift](Sources/RPClientCore/KoboldClientRegistry.swift) |
| Network — per-server transport | [KoboldClient.swift](Sources/RPClientCore/KoboldClient.swift) |
| Server profile model + roles | [Models/ServerProfile.swift](Sources/RPClientCore/Models/ServerProfile.swift) |
| Server URL probe | [ServerProbe.swift](Sources/RPClientCore/ServerProbe.swift) |
| Prompt assembly | [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) |
| Token-budget allocation | [Memory/TokenBudget.swift](Sources/RPClientCore/Memory/TokenBudget.swift) |
| Memory pipeline | [Memory/](Sources/RPClientCore/Memory) |
| Template implementations | [GemmaTemplate.swift](Sources/RPClientCore/GemmaTemplate.swift), [QwenTemplate.swift](Sources/RPClientCore/QwenTemplate.swift) |
| UI | [UI/](Sources/RPClientCore/UI) |

For the ground-truth design rationale behind the memory layout in particular, the in-repo docs (`MEMORY_AUDIT.md`, `MEMORY_V2_PLAN.md`, `MEMORY_HANDOFF.md`, `MEMORY_RESEARCH.md`) are the source of truth — these technical pages summarise; those documents derive.
