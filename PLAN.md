# RPClient — Native macOS roleplay client for koboldcpp

A lightweight native macOS chat client for roleplay against a koboldcpp server running on another local machine. Same build philosophy as ImageViewer: Swift + AppKit, programmatic UI, compiled directly with `swiftc`, no Xcode IDE.

---

## 1. Goals & non-goals

### Goals (MVP)
- Connect to a single koboldcpp server at a user-configured URL.
- SSE-streamed chat with stop and regenerate.
- Editable turns, persistent on disk.
- Two prompt templates: **Gemma** (primary) and **Qwen 3** (secondary).
- Sampler controls (presets + manual).
- **Memory system** as a first-class feature — pinned facts + rolling summary + suggested-fact extraction.
- Markdown rendering of assistant replies.
- Simple TTS via `AVSpeechSynthesizer`.

### Non-goals (MVP)
- SillyTavern character cards (V2).
- Branching / swipes (V2).
- Multiple servers.
- Lorebook / world info (data model only — no UI).
- Per-character voices.
- Image/avatar rendering.

---

## 2. KoboldCpp API surface

Native API (preferred over OpenAI-compatible — gives us memory, author's note, world info, full sampler control).

| Method | Path | Purpose |
|---|---|---|
| POST | `/api/extra/generate/stream` | SSE streaming generation. **Primary endpoint.** |
| POST | `/api/extra/abort` | Cancel in-flight generation. |
| POST | `/api/extra/tokencount` | Count tokens for a string. Used for budgeting. |
| GET  | `/api/v1/model` | Model name. |
| GET  | `/api/extra/version` | Kobold version + capability flags. |
| GET  | `/api/extra/perf` | Tok/s, queue depth — status bar. |
| GET  | `/api/extra/true_max_context_length` | Server's launch-time ctx ceiling. |
| GET  | `/api/v1/config/max_context_length` | Current effective ctx. |

### Generate request body (key fields)
```json
{
  "prompt": "<full assembled prompt>",
  "memory": "<always-injected text — Kobold puts at top>",
  "authors_note": "<late-injection text>",
  "max_length": 512,
  "max_context_length": 32768,
  "temperature": 0.9,
  "top_p": 0.95, "top_k": 40, "min_p": 0.05,
  "rep_pen": 1.07, "rep_pen_range": 1024,
  "sampler_order": [6,0,1,3,4,2,5],
  "stop_sequence": ["<end_of_turn>", "<start_of_turn>user"],
  "trim_stop": true,
  "stream_sse": true
}
```

**Important:** we will **not rely on Kobold's `memory` and `authors_note` fields exclusively**. Reason: we want template-aware placement (Gemma has no system role), and we want our rolling summary + world-info hits to live alongside pinned memory in a single coherent block. So `PromptBuilder` assembles everything into `prompt` itself, and we leave `memory` / `authors_note` empty. This keeps placement deterministic across templates.

### SSE format
Frames look like:
```
event: message
data: {"token": "Hello"}

event: message
data: {"token": " world"}
```
Parse line-by-line, accumulate until blank line, JSON-decode payload, append `token` to the live message. End on connection close or on a frame with `finish_reason`.

---

## 3. Templates

### Gemma (primary)

No system role. Memory/summary/author's note get folded into the **first user turn**:

```
<start_of_turn>user
{MEMORY_BLOCK}

{WORLD_INFO_HITS}

{ROLLING_SUMMARY}

{first user message}<end_of_turn>
<start_of_turn>model
{assistant reply}<end_of_turn>
<start_of_turn>user
{next user message}

{AUTHORS_NOTE if depth-from-end matches}<end_of_turn>
<start_of_turn>model
```

Stop sequences: `<end_of_turn>`, `<start_of_turn>user`.

### Qwen 3 (secondary)

ChatML. Has a system role. Thinking mode is **disabled** for RP via the empty-`<think>` trick.

```
<|im_start|>system
{MEMORY_BLOCK}

{ROLLING_SUMMARY}<|im_end|>
<|im_start|>user
{turn}<|im_end|>
<|im_start|>assistant
<think>

</think>

{reply}<|im_end|>
```

When sending a fresh generation, the prefix ends with:
```
<|im_start|>assistant
<think>

</think>

```
so the model continues past the closed think-block.

Stop sequences: `<|im_end|>`, `<|im_start|>user`.

### Template protocol

```swift
protocol PromptTemplate {
    var name: String { get }
    var stopSequences: [String] { get }
    func assemble(
        memoryBlock: String?,
        summary: String?,
        worldInfoHits: [String],
        authorsNote: AuthorsNote?,
        turns: [Turn]
    ) -> String
}
```

`GemmaTemplate` and `QwenTemplate` conform. Adding Llama-3 / Mistral later = one new file.

---

## 4. Memory architecture

The single most important design area. Three injection tiers + token budgeting + extraction loop.

### Layout in the assembled prompt

```
[system / template prefix]
[MEMORY]              — pinned, always-on facts. User-curated.
[WORLD INFO hits]     — keyword-triggered lore. (V2 UI; data model in MVP.)
[ROLLING SUMMARY]     — auto-compressed older turns.
[RECENT TURNS]        — verbatim history.
[AUTHOR'S NOTE]       — injected ~N turns from end.
[current user turn]
```

### Memory tiers

**1. Pinned facts (Memory).** User-edited in inspector. Hard cap (default 800 tokens, configurable per chat). Warn on overflow. Never truncated.

**2. Rolling summary.** Auto-maintained. When recent-history tokens exceed `summaryTriggerRatio * effectiveCtx` (default 0.70), the app:
- selects the oldest unsummarized turns whose token count fills ~25% of ctx,
- side-calls the model: "Summarize the following roleplay exchange into a concise paragraph preserving names, decisions, locations, and relationship state. Output only the summary.",
- replaces those turns with the returned summary,
- merges with the existing summary (via another side-call: "Combine these two summaries into one, deduplicating.") if a prior summary exists,
- updates `summarizedThrough` index in the chat.

Summary cap: 600 tokens default. When a merged summary exceeds the cap, summarize-the-summary with a tightening prompt.

**3. World info / lorebook.** MVP ships the data model and key-matching logic but no editor UI; entries injectable via JSON edit. V2 adds an editor.

### Fact extraction (suggestions)

Every 10 turns (configurable) **and** on demand via a "Scan for new facts" button, run a side-call:

```
System: You are a fact extractor for a long roleplay. Read the recent exchange and list any new persistent facts that should be remembered: character names introduced, relationships established, locations, decisions, items acquired, promises made. Return JSON:
[{"category": "character|location|relationship|item|event", "fact": "..."}, ...]
Return [] if nothing new.

User: <last N turns>
```

Results land in `pendingFactSuggestions` in the chat file, surfaced in the Suggestions pane. User clicks ✓ to pin into Memory or ✗ to dismiss. **Never auto-merged** — quality over recall.

### Token budgeting

Every assembly pass uses `/api/extra/tokencount` (cached per content hash) to check sizes. Budget allocation, in priority order:

1. Template overhead (computed once per template).
2. Pinned memory (cap).
3. Author's note (small, ~80 tok).
4. Reserved for `max_length` reply (e.g., 512).
5. Rolling summary (cap).
6. World info hits (cap, e.g., 400).
7. **Recent turns fill the remainder**, truncated from the oldest end.

If a recent turn would be the *only* thing pushing us over and it's been newly-summarized, drop it — it's now in the summary.

Status-bar context meter shows stacked usage.

### Per-chat persisted shape

```json
{
  "id": "uuid",
  "title": "Chat title",
  "created": "2026-05-02T12:00:00Z",
  "modified": "2026-05-02T12:34:00Z",
  "templateId": "gemma",
  "samplerPresetId": "balanced",
  "memory": "Pinned facts...",
  "memoryTokenCap": 800,
  "summary": "Rolling summary...",
  "summarizedThrough": 42,
  "summaryTokenCap": 600,
  "summaryTriggerRatio": 0.70,
  "authorsNote": { "text": "", "depth": 4 },
  "worldInfo": [
    { "keys": ["Citadel","fortress"], "content": "...", "tokenCap": 200 }
  ],
  "turns": [
    { "id": "uuid", "role": "user|assistant", "text": "...", "edited": false, "ts": "..." }
  ],
  "pendingFactSuggestions": [
    { "id": "uuid", "category": "character", "fact": "...", "createdTurn": 38 }
  ]
}
```

---

## 5. Architecture

### Source layout

```
Sources/RPClient/
  main.swift                    — NSApplication entry
  AppDelegate.swift             — window, menu, app lifecycle, settings sheet
  KoboldClient.swift            — URLSession SSE, abort, tokencount, model, perf, ctx
  PromptBuilder.swift           — orchestrates template + memory + budgeting
  Templates.swift               — PromptTemplate protocol
  GemmaTemplate.swift
  QwenTemplate.swift
  Memory/
    MemoryManager.swift         — coordinates pinned, summary, suggestions
    Summarizer.swift            — side-call to model for compression
    FactExtractor.swift         — side-call for fact suggestions
    TokenBudget.swift           — assembles within ctx budget
  Models/
    Chat.swift                  — Codable
    Turn.swift
    AuthorsNote.swift
    WorldInfoEntry.swift
    Settings.swift              — server URL, voice, default sampler/template
    SamplerPreset.swift
  Storage.swift                 — JSON I/O under Application Support
  UI/
    ChatViewController.swift    — message list (NSTextView per turn), streaming
    Markdown.swift              — minimal MD → NSAttributedString
    InputBar.swift              — multiline NSTextView + Send/Stop/Regen
    SidebarViewController.swift — chat list
    StatusBar.swift             — model, tok/s, ctx fill bar
    Inspector/
      InspectorViewController.swift — tabs: Memory / Summary / AN / Suggestions / Samplers
      MemoryPane.swift
      SummaryPane.swift
      AuthorsNotePane.swift
      SuggestionsPane.swift
      SamplersPane.swift
    SettingsWindowController.swift — server URL, default template, voice
  Voice/
    Speaker.swift               — AVSpeechSynthesizer wrapper
```

### Window layout

`NSSplitViewController` with three panes:

```
┌──────────┬─────────────────────────────────┬────────────────┐
│ Sidebar  │ Chat                            │ Inspector      │
│          │                                 │ ┌────────────┐ │
│ + New    │ ┌─ assistant ──────────────┐    │ │ Memory     │ │
│          │ │ markdown rendered text   │    │ │ Summary    │ │
│ Chats:   │ └──────────────────────────┘    │ │ Author's N │ │
│  ▸ Sage  │ ┌─ user ───────────────────┐    │ │ Suggestion │ │
│  ▸ Crew  │ │ what next?               │    │ │ Samplers   │ │
│          │ └──────────────────────────┘    │ └────────────┘ │
│          │ [streaming...]                  │                │
│          │ ┌─ Input ──────────────────┐    │                │
│          │ │ ...                      │    │                │
│          │ │ [Send] [Stop] [Regen]    │    │                │
│          │ └──────────────────────────┘    │                │
├──────────┴─────────────────────────────────┴────────────────┤
│ gemma-3-27b · 32768 ctx · ▓▓▓▓▓░░░ 18.4 tok/s              │
└─────────────────────────────────────────────────────────────┘
```

### Concurrency

- All Kobold I/O on `URLSession` (background queue).
- Stream tokens dispatched to main for UI updates, batched per ~30ms via a coalescing timer (avoids redraw thrash).
- Side-calls (summarize, extract) on a separate task; chat is non-blocking.
- Single in-flight generation enforced; "Send" disabled while streaming.

### Storage

`~/Library/Application Support/RPClient/`
```
settings.json
chats/<uuid>.json
presets/samplers.json
```
Atomic writes (write-to-temp + rename). One file per chat for easy sync/backup.

---

## 6. Build system

Mirror ImageViewer:

- `build.sh` — finds all `.swift` under `Sources/RPClient/`, runs `swiftc -O`, wraps in `.app` bundle, copies `Info.plist`, ad-hoc signs with `codesign --sign -`.
- `Package.swift` exists for tooling but is unused.
- Build outputs `RPClient.app` in project root.
- `cp -r RPClient.app /Applications/` to install.

`Info.plist` essentials: `LSMinimumSystemVersion`, `NSAppTransportSecurity` allowing arbitrary loads (since the kobold box is on LAN HTTP), `NSMicrophoneUsageDescription` (not needed yet — no STT in MVP).

---

## 7. Build order

| # | Step | Verifies |
|---|---|---|
| 1 | `KoboldClient` + `Templates.swift` + `GemmaTemplate` | CLI smoke test: send hello, stream reply |
| 2 | `main.swift` + `AppDelegate` + minimal window + `ChatViewController` plain text streaming | Type, send, see streamed reply |
| 3 | `Turn`/`Chat` models, persistence, edit-turn UI, regen, abort | Editable history survives restart |
| 4 | `SettingsWindowController` (server URL, template picker, sampler preset) | Switch to a Qwen server, works |
| 5 | `Markdown.swift` + render assistant turns | `**bold**` and `*italics*` look right |
| 6 | `Inspector` shell + `MemoryPane` + `AuthorsNotePane` (manual) | Pinned facts visible across turns |
| 7 | `TokenBudget` + status-bar ctx fill bar | Truncation kicks in correctly near limit |
| 8 | `Summarizer` + `SummaryPane` + auto-trigger | Long chat doesn't lose early context |
| 9 | `FactExtractor` + `SuggestionsPane` (auto every 10 turns + manual button) | Suggestions appear, pinning works |
| 10 | `QwenTemplate` (with `<think>` neutralization) | Switch templates in settings |
| 11 | `Speaker` + voice toggle in settings | Hear assistant reply |
| 12 | Polish: keyboard shortcuts, status bar perf, error states | — |

Each step ends in a committable, runnable binary.

---

## 8. Defaults

- Server URL: `http://localhost:5001` (override in settings).
- Template: Gemma.
- Effective ctx: read from `/api/extra/true_max_context_length`. Settings allow capping below.
- Sampler preset "Balanced": `temp=0.9, top_p=0.95, min_p=0.05, rep_pen=1.07, max_length=512`.
- Memory cap: 800 tok. Summary cap: 600 tok. Summary trigger: 70% of ctx.
- Fact-extraction cadence: auto every 10 turns + manual scan button.
- Voice: off. When on, system default voice, rate 0.5, speak full reply post-stream.

---

## 9. Research: additional memory-retention methods

Open webui seems better at managing memory than koboldcpp's own web interface, but far from perfect, research why.

The MVP memory system (pinned facts + rolling summary + keyword world info + suggestion extraction) is a solid baseline, but there's a wide design space worth investigating before V2. Spike each of these — read prior art, prototype if cheap, decide whether to adopt.

### 9.1 Vector / semantic retrieval (RAG over chat history)
- Embed every turn (or every summarized chunk) with a local embedding model. On each new user turn, retrieve top-K semantically similar past turns and inject them as a "Relevant earlier moments" block.
- **Why useful:** captures callbacks the rolling summary has compressed away — a character's offhand line from turn 14 resurfaces when relevant 80 turns later.
- **Investigate:** which embedding model runs cheaply on a Mac (MiniLM, BGE-small, Nomic) and how to host it — does koboldcpp expose embeddings, or do we run a sidecar (`llama.cpp` server, Ollama, MLX)? Storage: SQLite + sqlite-vec, or a flat file with cosine-similarity in Swift (small N is fine).
- **Risk:** retrieval can pollute the prompt with off-topic snippets. Need a relevance threshold and a hard cap on injected tokens.

### 9.2 Hierarchical / tiered summarization
- Instead of one rolling summary, keep multiple levels: per-scene summary → per-act summary → overall arc summary. Older detail compresses further over time.
- **Why useful:** preserves more granularity for recent past while still bounding token cost for ancient past. Closer to how human memory degrades.
- **Investigate:** how to detect scene boundaries (time-jump cues, location changes, model-detected via side-call), and how the layers get assembled into the prompt without bloat.

### 9.3 Entity / knowledge-graph memory
- Maintain a structured store: `entities` (characters, locations, items) each with attributes that update over the chat. Inject only entities mentioned (or likely to be mentioned) in the current turn.
- **Why useful:** facts stay precise — "Sage's sword is Mournbringer, gifted by Lir in chapter 2" doesn't drift through summarization. Updates are explicit, not implicit.
- **Investigate:** SillyTavern's "Smart Context" / "Vector Storage" extensions, the MemGPT paper, prior art in `letta`/`mem0`. Schema design: how rigid vs. freeform. Update mechanics: side-call after each turn to mutate entity records.
- **Cost:** every turn pays an extraction round-trip. Might be acceptable; benchmark.

### 9.4 MemGPT-style self-managed memory
- Give the model tools to read/write its own memory store (paginated history, working memory, archival memory). Model decides what to recall.
- **Why useful:** delegates curation to the model — no fixed cadence, no human-tuned thresholds.
- **Investigate:** the MemGPT paper and `letta` implementation. Whether Gemma/Qwen at our sizes follow tool protocols reliably enough for this to work. Probably overkill for RP, but worth a read.

### 9.5 Author's-note depth experiments
- Kobold supports author's-note depth (how many turns from the end to inject). The "right" depth is unclear and probably model-dependent.
- **Investigate:** run A/B tests at depths 2, 4, 8 on a long chat, measure whether style/scene cues actually take hold. May not be a research item so much as a per-chat tuning UI.

### 9.6 Memory at every user turn (re-injection)
- Already noted as a risk: Gemma's no-system-role fold means memory only appears in the *first* user turn. For long chats the model may drift away from it.
- **Investigate:** measure drift empirically. Compare first-turn-only vs. every-turn injection (token cost vs. fidelity). Could be a per-chat toggle, or auto-switch when chat exceeds N turns.

### 9.7 Salience / decay scoring
- Tag each fact (pinned or extracted) with a salience score that decays unless reinforced by new mentions. Low-salience facts evict first when budget is tight.
- **Why useful:** automatic pruning of stale memory without user babysitting.
- **Investigate:** how decay should interact with explicit user pins (probably: pinned facts immune from decay).

### 9.8 Chat-level "lessons learned" / persistent author voice
- A long-running chat develops a tone, vocabulary, recurring beats. Capture these separately from plot facts: "this chat tends toward gothic prose", "the user prefers slow-burn pacing", "the AI partner's voice uses British idioms".
- **Inject as a style block** rather than a fact block.
- **Investigate:** prompt design for extracting style separately from plot. Whether this belongs in author's note vs. its own slot.

### 9.9 Cross-chat memory
- Some facts should persist across chats with the same character (their core personality, established backstory). Distinct from chat-specific events.
- **Investigate:** pairs naturally with V2's character-card support. Storage: per-character memory file in addition to per-chat memory.

### 9.10 Prompt-cache awareness
- Koboldcpp's `--smartcache` snapshots KV-cache. If our prompt prefix (memory + summary) stays stable across turns, generation is dramatically faster. If memory is re-injected at every turn, the cache invalidates.
- **Investigate:** how much memory volatility costs in latency, whether to pin memory updates to "between turns only" vs. mid-stream-allowed.

### Research deliverable
Before starting V2, produce a short `MEMORY_RESEARCH.md` summarizing findings on each item, with a recommendation: adopt / defer / reject. Adopt set becomes V2 scope.

---

## 10. Open items / V2

- SillyTavern v2 character card import (PNG-with-embedded-JSON).
- Personas (user side).
- Branching / swipes — turn tree, alt-replies, sibling navigation.
- Lorebook editor UI.
- Group chats.
- Per-character voices.
- Bonjour/mDNS server discovery.
- Multiple-server switching.

---

## 11. Risks

- **SSE buffering on macOS URLSession.** `URLSession` sometimes buffers small SSE chunks. If we see laggy streaming, switch to `URLSessionStreamTask` or raw `Network.framework` `NWConnection`. Plan to use `URLSessionDataDelegate` first; have the fallback in mind.
- **Token-count round-trips.** `/api/extra/tokencount` is cheap but not free. Cache by content hash; only re-tokenize edited regions.
- **Summary quality varies by model.** Small/fast models summarize poorly. Settings should allow a different "summarizer model" URL later (V2). For MVP, use the same model.
- **Gemma's no-system-role fold.** If first-turn injection feels weak (model "forgets" memory by turn 30), revisit: re-inject memory into every user turn at the cost of tokens. Make this a per-chat toggle if needed.
