# RPClient V2 — Detailed plan

Forward plan for the V2 surface area listed in [`PLAN.md`](PLAN.md) §10. The MVP and the Memory V2 subsystem (Steps A–D, see [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md)) shipped 2026-05-03. This doc plans everything outside the memory subsystem; memory polish is deferred per the user's directive and tracked in [`NEXT_STAGES.md`](NEXT_STAGES.md) §A.

**Status as of 2026-05-05.** Phase 1 (V5 Lorebook UI), Phase 2 (V1 Swipes — including a stale-variant detection follow-up), and Phase 3 (V3 Character cards + V4 Personas) all shipped 2026-05-04. Phase 4 (V8 Multi-server) shipped 2026-05-05. Phase 5 (V10 Avatars) shipped 2026-05-05. Phase 6 (V6 Per-character voices) is next.

---

## 0. V2 inventory

From [`PLAN.md`](PLAN.md) §10 (with cross-links to the existing fragmented notes in [`NEXT_STAGES.md`](NEXT_STAGES.md)):

| # | V2 item | Where mentioned | Status today |
|---|---|---|---|
| V1 | Swipes (alternative continuations) | NEXT_STAGES B1 | **Shipped 2026-05-04** (Phase 2, including stale-variant badge + per-variant discard) |
| V2 | Branching (turn tree) | NEXT_STAGES B4 | Not started; superset of V1 |
| V3 | SillyTavern v2 character cards | NEXT_STAGES C2 | Not started |
| V4 | Personas (user side) | PLAN.md §10 only | Not started |
| V5 | Lorebook editor UI | NEXT_STAGES C1 | **Shipped 2026-05-04** (Phase 1) |
| V6 | Per-character voices | NEXT_STAGES F2 | Not started |
| V8 | Multi-server / multi-server switching | NEXT_STAGES F1 | Not started |
| V9 | Group chats | PLAN.md §10 only | Not started |
| V10 | Avatars / image rendering | NEXT_STAGES C3 | **Shipped 2026-05-05** (Phase 5; sidebar + assistant-turn avatars, inline image rendering deferred per §6.3) |

The chat-view UI overhaul (NEXT_STAGES §E) is **not** in this plan — it's a polish track and is sequenced separately.

---

## 1. Sequencing

The order below is the recommended path. Each phase ends with a shippable, runnable binary; later phases depend on earlier ones only where called out.

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1   V5 Lorebook UI            ✅ shipped 2026-05-04      │
│  Phase 2   V1 Swipes                 ✅ shipped 2026-05-04      │
│  Phase 3   V3 Character cards + V4 Personas  ✅ shipped 2026-05-04 │
│  Phase 4   V8 Multi-server            ✅ shipped 2026-05-05      │
│  Phase 5   V10 Avatars                ✅ shipped 2026-05-05      │
│  Phase 6   V6 Per-character voices    (depends on Entity store) │
│  Phase 7   V2 Full branching          (refactor; design doc)    │
│  Phase 8   V9 Group chats             (largest; design doc)     │
└─────────────────────────────────────────────────────────────────┘
```

Rationale for the order:

- **V5 first** because the data model is sitting unused and the prompt-builder injection path is the smallest of the lot — it's the cheapest "complete a thing already half-built" win and unblocks any future world-info-aware features.
- **V1 (swipes) before V2 (branching)** because swipes solve 90% of the user need with a non-breaking storage change (`Turn.alternatives: [Variant]`). Branching is a tree-of-turns refactor — defer until swipes prove the UX shape.
- **V3 + V4 paired** because character cards naturally include a persona slot for the user, and the import path lands cleaner if `Chat.persona` and `Chat.character` exist in the same change.
- **V10 before V6** because avatars give us the per-entity image slot V6 wants for its speaker indicator.
- **V6 depends on the Entity store** (already shipped in Memory V2 Step C) — speaker→voice mapping is per-entity.
- **V2 (branching) and V9 (group chats)** are both architecture-shifts and each warrants its own design doc before code. They sit at the end so V1/V3/V8 can inform their final shape.

If the user only wants to do one or two of these, the recommended pair is **V5 + V1**. Both ship in ~3 days total and address the most visible gaps.

---

## 2. Phase 1 — V5 Lorebook editor UI ✅ shipped 2026-05-04

Landed across four commits (`076f548` → `dacb4fc`). Section preserved as historical record of the shape that shipped.

**Why first.** [`Models/WorldInfoEntry.swift`](Sources/RPClientCore/Models/WorldInfoEntry.swift) exists, [`Chat.worldInfo`](Sources/RPClientCore/Models/Chat.swift) is persisted, but nothing reads it and nothing writes it through UI. Two-day job to close the loop.

### 2.1 Data-model touch-up

Current shape is minimal (`keys`, `content`, `tokenCap`). Extend before wiring UI:

```swift
struct WorldInfoEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String           // human label, distinct from keys
    var keys: [String]         // case-insensitive trigger words
    var secondaryKeys: [String] // optional AND-gate (entry fires only if a primary AND a secondary match)
    var content: String
    var tokenCap: Int
    var enabled: Bool
    var injectionMode: InjectionMode  // .keyword | .always | .vectorized (later)
    var matchScope: MatchScope        // .recentTurns(n) | .lastUserTurn | .entireChat
    var priority: Int          // tiebreak when total cap exceeded
}
```

Migration: read old entries, default `name = keys.first ?? "Untitled"`, `enabled = true`, `injectionMode = .keyword`, `matchScope = .recentTurns(4)`, `priority = 0`.

### 2.2 Injection

New file `Sources/RPClientCore/Memory/WorldInfoInjector.swift`:

- Input: `[WorldInfoEntry]`, recent turns (window per `matchScope`), token budget.
- Word-boundary, case-insensitive match (use `\bkey\b` semantics — same fix as memory selective-injection §A4).
- Returns `[String]` content blocks, ordered by `priority desc`, truncated to budget.

Wire into [`PromptBuilder`](Sources/RPClientCore/PromptBuilder.swift) above the rolling summary, below pinned memory — matches the layout in [`PLAN.md`](PLAN.md) §4.

### 2.3 Inspector pane

New `Sources/RPClientCore/UI/Inspector/WorldInfoPane.swift` modelled on `EntitiesPane`:

- Top: "+ New entry" button.
- List of entries with name, key count, enabled toggle.
- Detail editor: name, keys (comma-separated), secondary keys, content (multi-line), token cap, mode picker, scope picker, priority stepper, delete.
- Live token-count chip per entry (uses cached tokencount).

Add tab to [`InspectorViewController`](Sources/RPClientCore/UI/Inspector/InspectorViewController.swift).

### 2.4 Token accounting

Status-bar [`StatusBar.swift`](Sources/RPClientCore/UI/StatusBar.swift) already shows stacked usage; add a "World" segment.

### 2.5 Files touched

- `Models/WorldInfoEntry.swift` (extend + migration)
- `Models/Chat.swift` (no shape change; just exercise existing field)
- `Memory/WorldInfoInjector.swift` (new)
- `PromptBuilder.swift` (call injector)
- `UI/Inspector/WorldInfoPane.swift` (new)
- `UI/Inspector/InspectorViewController.swift` (tab registration)
- `UI/StatusBar.swift` (segment)
- `Tests/PromptBuilderTests.swift` and `Tests/WorldInfoInjectorTests.swift` (new)

### 2.6 Risks / open

- Substring vs. word-boundary matching: same pitfall as Memory §A4. Use word-boundary from day one.
- Vector mode (`injectionMode == .vectorized`) — defer; matching against the chunk store is a Memory-V3 feature.
- Secondary-key AND-gate is SillyTavern-standard; useful for "entry only fires if 'sword' AND 'Mournbringer' both appear". Implement it; the cost is low.

**Effort: 2 days.**

---

## 3. Phase 2 — V1 Swipes (alternative continuations) ✅ shipped 2026-05-04

Landed across four commits (`764b41f` model → `89ac4a6` core logic → `c750139` UI → `54fca62` stale-variant follow-up). Section preserved as historical record of the shape that shipped.

**Stale-variant detection** (extension to the original spec, §3.6 last bullet): each `TurnVariant` records a `contextFingerprint` (FNV-1a hash of the prefix turns' id/role/text) at generation time; `Chat.isVariantStale(turnIndex:variantIndex:)` recomputes and compares. UI badges the active variant with `⚠` when stale, and a per-turn discard button (`minus.circle`) lets the user prune. Memory/summary blocks are deliberately excluded from the fingerprint — only turn text edits / reorders / page-swaps mark variants stale.

**The pitch.** Generate N alternative replies for the same prompt; user pages through them with arrow controls; pinned variant becomes "the" reply for the next turn's context.

### 3.1 Data-model change

Extend `Turn` non-breakingly:

```swift
struct Turn: Codable, Identifiable, Equatable {
    let id: UUID
    var role: TurnRole
    var text: String           // mirror of variants[activeVariant].text — kept for backward compat
    var edited: Bool
    var ts: Date

    // V2 additions
    var variants: [TurnVariant]   // empty on user turns; ≥1 on assistant turns once swipes used
    var activeVariant: Int        // index into variants; default 0
}

struct TurnVariant: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var edited: Bool
    var ts: Date
    var samplerPresetId: String?   // capture sampler at gen time (optional)
}
```

**Migration.** On load, if `variants` is empty for an assistant turn, synthesise `variants = [TurnVariant(text: text, ...)]`, `activeVariant = 0`. Keep mirroring `text` for the active variant on save so a downgrade still reads sensibly.

### 3.2 Generation flow

Today regen replaces the trailing assistant turn. New behaviour:

- **Send** → generate variant 0, append turn.
- **Swipe-right on assistant turn** → generate a new variant, append to `variants`, set `activeVariant = variants.count - 1`. The next user turn assembles context from the active variant.
- **Swipe-left** → previous variant; no generation.
- **Regen** (existing button) → behaviour change: appends a new variant rather than overwriting. The "destructive regen" of today becomes opt-in via Cmd-Shift-R or a context-menu "Replace current variant".

### 3.3 UI

[`TurnView.swift`](Sources/RPClientCore/UI/TurnView.swift) gains a footer row on assistant turns when `variants.count > 1`:

```
◀  3 / 5  ▶                    [Edit] [Delete]
```

Hover-only when count == 1 (don't visually clutter).

[`InputBar.swift`](Sources/RPClientCore/UI/InputBar.swift) adds a "Swipe" button (or relabels Regen). Keyboard shortcuts: `⌘→` swipe-next-or-generate, `⌘←` swipe-prev.

### 3.4 Persistence

[`Storage.swift`](Sources/RPClientCore/Storage.swift) — no changes beyond the model. JSON files grow; that's acceptable.

### 3.5 Files touched

- `Models/Turn.swift` (extend)
- `Models/Chat.swift` (migration in initialiser-from-decoder)
- `UI/TurnView.swift` (footer, swipe controls)
- `UI/InputBar.swift` (button + shortcut)
- `UI/ChatViewController.swift` (orchestration: bind swipe → gen pipeline)
- `KoboldClient.swift` (no change)
- `Tests/TurnTests.swift` and migration test in `Tests/StorageMigrationTests.swift`

### 3.6 Risks / open

- **Edited variants.** If the user edits variant 2's text, the variant gets `edited = true`. Don't lose the original on regen-into-variant.
- **Token cost.** Each swipe is a full generation. Cheap on a local box; still worth a "max variants per turn" setting (default 5).
- **Streaming UX.** During a streaming swipe-generation, lock paging until done.
- **Branching consequence.** Swipes are linear-with-alternatives; they do not create a tree. If the user then edits an *earlier* turn, all later variants on that turn become stale — surface a "stale" badge but don't delete (let the user prune).

**Effort: 2-3 days.**

---

## 4. Phase 3 — V3 Character cards + V4 Personas

These two ship together: character cards include both an AI-character payload and (often) a recommended user-side persona.

**Status (2026-05-04):** all of Phase 3 shipped on `v2-plan`. Steps 1–3 across `dd102db` → `50da4ab` (with v1/Pygmalion importer follow-up `c941baf`); step 4 (prompt-builder integration) shipped as sub-steps 4a–4g across `2e99602` → `342791c`. Imported cards now fully drive the model: system_prompt + biographical prefix at the top of memory, first_mes + alt greetings seeded as turn 0 with swipeable variants, postHistoryInstructions as the author's note fallback, character_book merged into chat world-info, persona injection per-template, and a read-only "from card" surface in MemoryPane with a per-chat override/merge picker.

### 4.1 Data-model additions ✅ shipped (step 1 — `dd102db`)

```swift
struct Persona: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String     // injected as user-context block
    var avatarPath: String?
    var created: Date
}

struct Character: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var description: String
    var personality: String
    var scenario: String
    var firstMessage: String
    var alternateGreetings: [String]
    var systemPrompt: String?           // ST card v2 system_prompt
    var postHistoryInstructions: String?
    var avatarPath: String?
    var tags: [String]
    var creator: String?
    var characterVersion: String?
    var charBook: [WorldInfoEntry]      // ST "character book" lorebook entries
}
```

`Chat` gains:

```swift
var characterId: UUID?    // nil = no character (free-form chat)
var personaId: UUID?      // nil = anonymous user
```

Storage:

```
~/Library/Application Support/RPClient/
  characters/<uuid>.json
  characters/avatars/<uuid>.png
  personas/<uuid>.json
  personas/avatars/<uuid>.png
```

### 4.2 Card import ✅ shipped (step 2 — `3149dda`; v1/Pygmalion follow-up `c941baf`)

New `Sources/RPClientCore/Importers/CharacterCardImporter.swift`:

- Accept `.png` (V2 spec, JSON in tEXt chunk keyed `chara`, base64-encoded) and `.json` (Tavern V2 spec).
- Parse PNG chunks manually — small format, ~80 lines of Swift, no dependency.
- Decode base64 → JSON → map to `Character`. ST card v2 fields map cleanly; `character_book.entries` map to `WorldInfoEntry` (see Phase 1 schema).
- Avatar = the PNG image itself (extract and write to `characters/avatars/<uuid>.png`).
- Validate spec_version (`chara_card_v2`); reject v1 with a clear message (or convert with degraded fields).

  Landed accepting v2 + v1 + Pygmalion-aliased v1 + explicit `chara_card_v1`. v1 has no `system_prompt`/`post_history_instructions`/`alternate_greetings`/`character_book`, so those default empty; `mes_example` folds into `description` as "Example dialogue:\n…" so it isn't dropped. Unknown future specs (e.g. `chara_card_v3`) still reject.

Importer UI:

- File menu: "Import Character…"
- Drag-drop a PNG anywhere on the sidebar or character picker.
- Toast on success; reveal in character library.

### 4.3 Character library + persona library ✅ shipped (step 3 — `50da4ab`)

- New "Library" sheet (Cmd-Shift-L): tab for Characters, tab for Personas. Grid of avatars + names. Click → details + "Start chat" / "Edit" / "Delete".
- New chat flow: sidebar "+" splits into "+ New chat" and "+ New chat with character…".

  Landed as `LibraryWindowController` with `NSCollectionView` flow-layout grids; characters tab is import-only for now (no edit sheet — too many fields, can come later), personas tab has full create/edit/delete via a name+description sheet. Sidebar's "+" became an `NSPopUpButton` pull-down. Character chat-creation flow: `AppState.newChat(withCharacter:)` seeds `Chat.characterId` and the chat title; new chats inherit `Settings.defaultPersonaId`. Drag-drop lands PNG/JSON onto the sidebar root view (`SidebarRootView`).

### 4.4 Prompt-builder integration ✅ shipped (step 4 — `2e99602` → `342791c`)

Landed as seven sub-steps, mirroring the earlier-phase cadence (model touch-up → core helpers → UI surface):

- **4a (`2e99602`)** — plumbing: `CardPromptMode` (override/merge, default override), `Chat.systemPromptMode` with Codable backwards-compat (existing chats decode as `.override`), `Character?` / `Persona?` threaded through `PromptBuilder.build` → `TokenBudget.assemble` → the single `AppState.assembleAndStream` callsite. No behaviour change.
- **4b (`b9e9ade`)** — `PromptBuilder.composeMemoryBlock` is now the single source of truth for the top-of-prompt memory block: card `system_prompt` (if any) → userName line → read-only `[from card]` description/personality/scenario → user-set `chat.memory`. The user memory is suppressed only when `systemPromptMode == .override` AND the card has a non-empty `system_prompt`. Test path and production path share the same composition.
- **4c (`123a56a`)** — `AppState.newChat(withCharacter:)` seeds `firstMessage` as turn 0 (assistant role); `alternateGreetings` ride along as swipeable variants on that same turn. Empty / whitespace-only `firstMessage` skips seeding entirely. Card-prefix header gained a one-line nudge framing `Scenario` as the *default* opening so the model defers to recent turns when the user swipes to an alt that disagrees with the static scenario field.
- **4d (`b35b558`)** — `PromptBuilder.effectiveAuthorsNote` picks the user's note when set, otherwise synthesises one from the card's `postHistoryInstructions` inheriting the chat's existing AN depth. User-set notes always win; whitespace-only counts as empty.
- **4e (`e2a0594`)** — `AppState.mergedWorldInfo` copies card `character_book` entries into the chat's `worldInfo`, name prefixed `[from card] <orig>`. Pure name-prefix idempotency — re-running is a no-op, and user edits to a `[from card]` entry survive subsequent merges. Each merged entry gets a fresh UUID so chat-side edits don't bleed across.
- **4f (`403188f`)** — `PromptBuilder.renderPersonaBlock` formats persona as `<You are NAME>\nDESCRIPTION` (or just one of those when only one is populated). Per-template placement: Qwen folds it into the `<|im_start|>system` block right after memory; Gemma folds it into the first user turn alongside the preamble. Soft-cap warning logs to `DebugLog` when the rendered block exceeds ~200 tokens (V2_PLAN §4.6).
- **4g (`342791c`)** — MemoryPane gains a "From card (read-only) · *Name*" section showing description/personality/scenario live from `AppState.character(id:)`, plus a per-chat `system_prompt: [Override | Merge]` segmented control. Both sections are NSStackViews so they cleanly collapse via `isHidden` when no character is attached. Diagnostic line in `assembleAndStream` (`card-compose: …`) reports both card and persona resolution + composed/persona char counts so the wiring is visible from logs.

Test coverage grew from 140 → 175. Key suites: `PromptBuilderTests` (composition, AN precedence, persona format + per-template placement), `CharacterPersonaTests` (greeting seeding, charBook merge idempotency), `ChatCodableTests` (systemPromptMode default + round-trip).

### 4.5 Files touched

- `Models/Character.swift` (new)
- `Models/Persona.swift` (new)
- `Models/Chat.swift` (add `characterId`, `personaId`; migration: nil)
- `Storage.swift` (character + persona dirs, atomic IO, avatar copy)
- `Importers/CharacterCardImporter.swift` (new) + `Importers/PNGTextChunks.swift` (new)
- `PromptBuilder.swift` (character + persona injection)
- `UI/LibraryWindowController.swift` (new)
- `UI/CharacterCardView.swift` and `UI/PersonaCardView.swift` (new)
- `UI/SidebarViewController.swift` (split "+" menu)
- `UI/Inspector/MemoryPane.swift` (read-only "from card" prefix display)
- `UI/SettingsWindowController.swift` (default persona picker)
- `Tests/CharacterCardImporterTests.swift` with at least one canonical ST v2 PNG fixture.

### 4.6 Risks / open

- **PNG parsing.** The tEXt chunk format is simple but easy to get wrong (CRC, zero-terminator). Land it behind a single function with comprehensive tests against fixtures from public ST card collections.
- **System-prompt vs. memory precedence.** Card's `system_prompt` should *replace* chat-level memory, not concatenate, when present — match SillyTavern's behaviour. Make this configurable per-chat ("merge" vs. "override") with default = override.
- **Avatar storage.** Avatars are PNGs that may be large. Cap at 2 MB on import; downscale to 512px max dimension.
- **Persona-as-memory drift.** The persona description occupies token budget at every turn. Cap at 200 tokens default; warn on overflow.

**Effort: 3-4 days for both items together (importer + libraries + injection + UI).**

---

## 5. Phase 4 — V8 Multi-server ✅ shipped 2026-05-05

### 5.1 Multi-server data model

Replace `Settings.serverURL: String` with:

```swift
struct ServerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseURL: URL
    var role: ServerRole       // .general | .summarizer | .extractor | .embeddings
    var capabilities: ServerCapabilities?  // last-probed: model name, ctx, version
    var lastProbed: Date?
}
struct Settings {
    var servers: [ServerProfile]
    var defaultServerId: UUID
    // optional per-role overrides
    var summarizerServerId: UUID?
    var extractorServerId: UUID?
    var embeddingsServerId: UUID?
}
struct Chat {
    var serverId: UUID?         // nil = use default
    // existing fields...
}
```

Migration: existing `Settings.serverURL` becomes one `ServerProfile` named "Default", everyone points at it.

### 5.2 Client routing

`KoboldClient` is already per-instance (it takes a `baseURL` in `init`). Today, `AppState.kobold` is a single shared instance with a mutable URL via `setBaseURL`. Phase 4 replaces that with a registry:

```swift
final class KoboldClientRegistry {
    func client(for role: ServerRole, chatOverride: UUID?) -> KoboldClient
}
```

- Generation calls → `chat.serverId` ?? `settings.defaultServerId`.
- Side-calls (summarize, extract, embed) → role-specific override ?? default.
- Registry caches one `KoboldClient` per profile so token-count caches and URLSession state survive lookups.

The current `AppState.kobold` field stays as a *façade* pointed at the chat's effective generation client, so existing callers don't all need rewriting on day one. Side-call callers (`Summarizer`, `FactExtractor`, retrieval embeddings) get migrated to the registry as a follow-up commit. This unblocks "small fast model for chat, beefy model for memory side-calls" — a clear quality win once it lands.

### 5.3 Settings UI

New Servers tab in [`SettingsWindowController`](Sources/RPClientCore/UI/SettingsWindowController.swift):

- Server list: name, base URL, last-probed model, status dot.
- Per-server: edit name/URL, "Test connection" button (probes `/api/v1/model` + `/api/extra/version`), delete (blocked if it's the default).
- Role assignment: dropdowns for Default / Summarizer / Extractor / Embeddings.
- "Add server" → free-text URL.

### 5.4 Per-chat picker

In the chat header (next to template + sampler picker): server dropdown showing "Use default" or a specific profile. Persists to `Chat.serverId`.

### 5.5 Files touched

- `Models/Settings.swift` — rewrite: `serverURL: String` → `servers: [ServerProfile]` + `defaultServerId` + per-role overrides. Migrate `serverURL` into a single `ServerProfile` named "Default" on decode.
- `Models/Chat.swift` — add `serverId: UUID?` (Codable backwards-compat: existing chats decode as nil = use default).
- `KoboldClient.swift` — already per-instance; add `KoboldClientRegistry.swift` that owns one client per profile.
- `AppState.swift` — replace the single `kobold: KoboldClient` field + `setBaseURL` mutation with a registry-backed accessor. Keep the `kobold` property as a façade pointed at the current chat's generation client so existing callers don't all need rewriting on day one.
- Side-call callers — `Memory/Summarizer.swift`, `Memory/FactExtractor.swift`, `Memory/ContextBlurber.swift`, `Memory/RetrievalEngine.swift` (embeddings) — switch from `AppState.shared.kobold` to the registry's role-specific client.
- `UI/SettingsWindowController.swift` — new "Servers" tab.
- `UI/ChatViewController.swift` — per-chat picker in the chat header (next to template + sampler).

### 5.6 Risks / open

- **Side-call routing must not regress today's behaviour.** Default everything to the same server initially; only switch when the user opts in.
- **Capability probing latency.** Cache probe results on `ServerProfile.capabilities` with a TTL; re-probe on demand.
- **Sampler / template incompatibility across servers.** Different servers may run different models. Per-chat already pins template + sampler — nothing extra to do, but warn if the chat's template doesn't match the server's reported model family.

**Effort: 3 days.**

### 5.7 Shipped: 2026-05-05

Sub-steps as shipped (one commit per):
- **4a** — ServerProfile / ServerRole / ServerCapabilities models + Settings rewrite (servers + defaultServerId + per-role overrides) + Codable migration of legacy `serverURL`. 6 round-trip / migration tests.
- **4b** — KoboldClientRegistry: caches one client per profile, role + chatOverride routing, in-place URL update preserving identity, eviction on profile removal, stable localhost sentinel for corrupt state. AppState.kobold became a computed façade. 10 unit tests on routing.
- **4c** — Chat.serverId pin + façade plumbing. server-resolve: diagnostic includes the per-chat serverId. 2 Codable tests (round-trip + legacy nil-default).
- **4d** — Side-call role routing in AppState: retrieve→.embeddings, index→.embeddings + .summarizer (split clients), summarize→.summarizer, extract→.extractor. Carved KoboldGenerating + KoboldEmbedding protocols out of KoboldClient so the engine's two side-calls can be wired to different clients (and so the routing is testable). RetrievalEngine grew an injectable `storesDir` so the routing test runs on a tmp dir. 3 routing tests with fake protocol doubles.
- **4d-followup** — `side-call:` log line at every side-call dispatch point so misrouting is visible in the debug log without inspecting network traffic.
- **4e** — Settings UI Servers section: scrollable list of profile rows (name + URL + Test + status dot + delete), four role-assignment popups, "+ Add server", short-timeout `ServerProbe` of /api/v1/model + /api/extra/version + /api/extra/true_max_context_length. Editing rules in pure `ServerEditing` helpers. 9 + 6 tests for the rules and JSON parsers.
- **4f** — Per-chat server picker in a new chat header bar. ChatServerPicker model helpers (selectedIndex / idAtIndex / displayLabel) test-covered, AppKit popup is glue. New `settingsChanged` notification so the picker refreshes when profiles change.

What landed differently from §5.6 risks:
- Sampler / template incompatibility warning: punted to a follow-up. The routing infrastructure ships clean without it; the warning UX needs its own thinking (where does it surface? on chat open? on send?).
- Capability probing: lazy on demand only, not on app launch. `ServerCapabilities` is cached on the profile and refreshed by the user clicking "Test connection".

---

## 6. Phase 5 — V10 Avatars / image rendering ✅ shipped 2026-05-05

Avatars (per-character, per-persona, per-entity) drop in cleanly on top of Phase 3.

**Status (2026-05-05):** sidebar + assistant-turn avatars shipped across three commits (`f6d9192` → `aab21e7` → `897747a`). 5a introduced `AvatarSource` (id → NSImage resolver with library-changed cache invalidation, TDD'd against 5 cases); 5b added the 32px circular avatar slot to each sidebar row; 5c replaced the assistant ✦ glyph in TurnView with the same 32px avatar (placeholder ✦ kept for character-less chats). Persona avatars on user turns, entity avatars, and inline image rendering are deferred — see §6.3 and §6.4 for the deferred sub-items.

### 6.1 Sidebar avatars

[`SidebarViewController`](Sources/RPClientCore/UI/SidebarViewController.swift): each chat row gains a 32px avatar from `chat.characterId`'s character avatar, falling back to a glyph.

### 6.2 In-turn avatars

On the chat view, assistant turns show the character avatar at top-left (matches Open WebUI styling — pairs naturally with NEXT_STAGES §E1).

### 6.3 Inline images in turns (defer)

Markdown `![alt](path)` rendering. Out of scope for this phase; opens questions about copy-to-clipboard, drag-out, sandboxing. Punt to a later cosmetic pass.

### 6.4 Deferred sub-items (potential future work)

Decisions made at Phase 5 kickoff (2026-05-05) — call these out so they don't get lost when picking up the chat-view polish pass later:

- **Persona avatars on user turns.** §6 only specifies *character* avatars. User turns today are right-aligned bubbles with no glyph column, so adding a persona avatar means a layout break. Defer to the chat-view styling pass (NEXT_STAGES §E).
- **Entity avatars in turns / sidebar.** §6's preamble mentions per-entity avatars but no UI is specified. Defer until V6 (per-character voices) lands the speaker indicator that the entity avatar would naturally pair with.
- **Avatar size scaling.** Phase 5 ships fixed-32 in the sidebar / in-turn slot, matching the library cards' fixed-96 (which already ignore `uiFontOffset`). Revisit only if a user reports the fixed size feels wrong against an extreme font offset.
- **Storage `avatarPath` field on Character/Persona.** V2_PLAN §4.1's snippet shows `avatarPath: String?` but the actual models derive the path from id via Storage (see [Persona.swift:8](Sources/RPClientCore/Models/Persona.swift:8) docstring). The plan's snippet is stale; no migration is needed. Mentioned here so future-us doesn't try to "add the missing field."

**Effort: 1 day for sidebar + chat-view avatars (without inline image rendering).**

---

## 7. Phase 6 — V6 Per-character voices

**Precondition — verify before starting §7.1.** §7.2–§7.5 depend on the Entity store from Memory V2 Step C. §7.1 (engine swap) does not — it touches only the `SpeechSynthesizing` adapter — but if the Entity store is missing or incomplete, the rest of Phase 6 is blocked and the work after §7.1 stalls. Check whether `Entity` exists as a first-class persisted store with names/aliases queryable from `AppState` (or wherever it landed) before kicking off §7.1, so you know what you're walking into. If it's missing, decide whether to land Memory V2 Step C first or scope §7.1 standalone.

### 7.0 Prestep — basic "Speak replies" (single voice)

Discovered 2026-05-05 while scoping Phase 6: the existing **Speak replies** checkbox in Settings is a stub. `Settings.voiceEnabled` is declared, persisted, and surfaced via [`SettingsWindowController.voiceCheck`](Sources/RPClientCore/UI/SettingsWindowController.swift:25), but **nothing reads it** — there's no `Voice/Speaker.swift`, no `AVSpeechSynthesizer` import anywhere, and git history shows no such file was ever deleted (the checkbox shipped ahead of any TTS implementation). V2_PLAN §7.3's "Existing `Voice/Speaker.swift` currently speaks the whole turn in one voice — refactor:" is therefore wrong; there's nothing to refactor.

The prestep ships the missing single-voice path so the UI promise stops lying. The follow-up sub-steps below layer a better engine and per-character attribution on top of a working pipeline rather than building TTS from scratch.

**Status: shipped 2026-05-05** in commit `c7a3f81`. New `Sources/RPClientCore/Voice/Speaker.swift` with a `SpeechSynthesizing` protocol seam (production: `AVSpeechSynthesizerAdapter`; tests: recording fake), reads finished assistant turns via `AppNotification.streamFinished`, stops on `streamStarted` / `currentChatChanged` / settings-toggle / app quit. Markdown + `<think>` stripping in `Speaker.plainText`. 10 new SpeakerTests, total 245/245 green.

### 7.1 Better TTS engine — Kokoro swap

Sequenced ahead of §7.2–§7.4 (was §7.5, promoted 2026-05-05). Rationale: §7.0 smoke-tested AVKit's quality and it's poor — flat prosody, robotic cadence, unsuited to RP. Layering attribution on top of a bad engine just gives you four different bad voices. Swapping the engine is orthogonal to attribution work thanks to the §7.0 protocol seam, so doing it first means §7.2–§7.4 land on output worth attributing to.

**Decision (2026-05-05):** Kokoro 82M (ONNX) is the chosen engine. Apple Premium voices were considered as a cheaper first try (zero new deps, same API) but rejected — the user wants a clean quality jump rather than another tier of "still recognisably synthetic." Cloud APIs (ElevenLabs / OpenAI / Cartesia) were ruled out as misaligned with RPClient's local-first posture. Piper was ruled out (lighter than Kokoro but flatter prosody on long passages); Coqui XTTS was ruled out (defunct upstream, restrictive licence, ~2GB model).

**Why Kokoro:**

- Open-weight neural TTS (~325MB model, ~82M params), Apache-2.0 licence — fits a local-first app distributable without external API contracts.
- Quality is competitive with commercial cloud TTS on read-aloud English passages — the meaningful tier jump §7.0 was missing.
- Multiple built-in speaker IDs gives §7.2 a finite-but-sufficient catalogue for per-character voice picking.
- Runs on Apple Silicon at usable speed via ONNX Runtime; expected ~300–500ms first-audible-token after model warm-up.

**Costs accepted:**

- New dependency: ONNX Runtime (vendored xcframework, ~50MB binary impact). This ships with the .app regardless of where models live.
- Two-tier asset model, **none of which lives in the .app bundle**: one base ONNX model (`kokoro-v1.0.onnx`, 325 MB exactly, from `github.com/thewh1teagle/kokoro-onnx` releases) plus per-voice tensor files (`<id>.pt`, 523 KB each, 54 voices, from `huggingface.co/hexgrad/Kokoro-82M/voices/`). User downloads the base model once, then opts in to whichever voices they want à la carte. Verified roster spans 9 languages — en-US, en-GB, ja, zh, es, fr, hi, it, pt-BR — with 29 female + 25 male voices.
- AVKit stays available as the fallback engine when the base model is missing or fetch fails — the §7.0 adapter is not deleted, just demoted.
- Latency floor (~300–500ms after warm-up) means we keep §7.0's "speak after stream finishes" pattern; we do not attempt sub-utterance streaming TTS in §7.1. §7.4's queue-aware shape can revisit if needed.

**Model storage path is user-configurable, with a first-run prompt.** When the user first toggles `voiceEnabled` on AND `Settings.voiceModelPath` is unset, a one-time sheet appears: "Voice models are large (the base model alone is ~310 MB). Where would you like to store them?" Detected non-system mounted volumes are surfaced as one-click options (largest free volume listed first), with `~/Library/Application Support/RPClient/voice-models/` always present as the conservative fallback, plus a "Choose…" escape hatch for an arbitrary directory. Once chosen, the path is persisted in `Settings.voiceModelPath: String?` and the user is dropped straight into the Voice library manager (next subsection) to pick which voices to install. The user can change the location later via Settings → Voice → "Set storage location…" which opens the same `NSOpenPanel`. Rationale for an auto-detect prompt rather than a hardcoded default: keeps the source portable across machines, but in practice surfaces the user's external SSD as the obvious pick when one is mounted. On launch (and on `NSWorkspace.didMountNotification` / `didUnmountNotification`), `KokoroModelStore` re-validates the path; when the volume is absent, `state` goes back to `.missing` and speech falls back to AVKit cleanly — never a crash on unplug, even though the user's setup is always-mounted in practice. App is unsandboxed today, so a raw path is sufficient; a sandboxed build would need security-scoped bookmarks (noted in §10).

Layout under the configured root (everything here is downloaded at runtime — none of it is in the .app bundle):

```
<voiceModelPath>/kokoro/
  model.onnx                    (325 MB, kokoro-v1.0.onnx, downloaded once)
  voices/
    af_bella.pt                 (523 KB each, raw HuggingFace .pt files)
    af_nicole.pt
    am_michael.pt
    bf_emma.pt
    ...                         (only the voices the user opts in to)
  manifest.json                 (state file: installed voices + checksums + downloaded-at timestamps)
```

The voice catalogue itself (id → language/accent/gender/sample-text mapping) ships as a **Swift literal** in `RPClientVoice` (`Sources/RPClientVoice/KokoroVoiceCatalogue.swift`), not as a Bundle resource. Static reference data, ~5 KB, updated by source edit when we bump the supported Kokoro version. The hard rule "nothing voice-related in the app bundle" applies to assets that the user is paying disk for (model + voices); pure metadata that drives the UI ships with the binary as code.

**Voice library manager (à la carte, no bulk download).** Settings → Voice tab grows a "Voice library" section — a persistent manager, not a one-shot wizard. Lists the full 54-voice catalogue from `KokoroVoiceCatalogue.all` (Swift literal in `RPClientVoice`); each voice is browsable but downloaded only when the user opts in. There is **no "download all" affordance** — every download decision is per-voice, with per-voice Remove to free the 523 KB on demand. The first-run prompt drops the user here after they've picked a storage location.

```
Voice library                                       [Set storage location…]

  Base model               [Download (310 MB)]   ●  ready  /Volumes/SSD1/…
  ─────────────────────────────────────────────────────────────────────────
  Available voices                                 [Filter: en-US] [Gender]
    af_bella    en-US (F)    [▶ Preview]   [Download]
    af_nicole   en-US (F)    [▶ Preview]   [✓ Installed]   [Remove]
    am_adam     en-US (M)    [▶ Preview]   [Download]
    bf_emma     en-GB (F)    [▶ Preview]   [Download]
    …
```

Per-voice rows: language/accent label, gender, Preview button (synthesises a short canned line — only enabled once base model + that voice are installed), Download / Installed-Remove button. Filter chips at the top (language, gender) so users browsing 50+ voices can narrow by their use case. Status dot on the base-model row reflects `KokoroModelStore.baseModelState`. The "Set storage location…" link opens the same `NSOpenPanel` as the first-run prompt; on path change, the manager re-resolves which voices are installed at the new location (it does **not** auto-migrate downloads — user prompted to either move existing files or re-download). The base model must be downloaded before any voice download is enabled (voices alone are useless without the model).

**Two-tier toggle UX.** A single "Speak replies" checkbox in Settings is too coarse — flipping it off still keeps the engine loaded for the next chat, and users have no quick mute for "I want to read this turn quietly without disabling voice globally." Split into:

- **`Settings.voiceEnabled` (existing field, repurposed as the *subsystem* gate).** Settings checkbox now reads "Enable voice subsystem". When OFF: no engine init, no model download prompts, the main-UI toggle is disabled, the Voice library section in Settings is hidden. When flipped ON: triggers the first-run storage prompt if `voiceModelPath` is nil; reveals the library manager; enables the main-UI toggle.
- **`Settings.voiceActive` (new, persisted, defaults true).** The runtime toggle. Speaker only synthesises when `voiceEnabled && voiceActive` — both must be true. Lives as a speaker icon button in the **chat header** (next to the existing template / sampler / server pickers added in Phase 4). Disabled (greyed) when `voiceEnabled == false`, with a tooltip pointing the user at Settings to enable the subsystem first. Click toggles `voiceActive`; flipping off mid-utterance stops the current speech (already wired in §7.0's `Speaker.setVoiceEnabled`).

Engine lifecycle:
- `voiceEnabled` flipping false → `Speaker` swaps to AVKit fallback, Kokoro adapter deinits, ONNX session releases its ~80 MB. No model unload (file stays on disk).
- `voiceActive` flipping false → `Speaker.setVoiceEnabled(false)` only; the Kokoro adapter stays loaded so re-enable is instant.

This keeps the cheap toggle on the main UI, and the costly "load the engine" toggle in Settings where it belongs.

**Implementation sketch:**

Sub-steps a–e are the data layer (all shipped, fully TDD-covered, 290/290 green). f onwards is the live UI / IO / engine work.

**Order deviation 2026-05-05:** sub-step i (chat-header speaker button) is being landed immediately after f rather than after g and h, because it pairs naturally with f (both surfaces of the same two-tier toggle) and lets f's runtime gate be exercised end-to-end before any IO/library work goes in. Plan order resumes at g after i ships.

a. **Dependency wiring — shipped 2026-05-05 (`01109b0`).** Pulled `microsoft/onnxruntime-swift-package-manager` 1.24.2 as a SwiftPM dep (binary artifact, not a vendored xcframework). New `RPClientVoice` target (`Sources/RPClientVoice/`) sits between `RPClientCore` and the `RPClient` executable; it owns the ONNX import. `RPClientCoreTests` depends only on `RPClientCore`, so `otool -L` confirms zero ONNX symbols leak into the test binary. Bumped package `platforms: [.macOS(.v14)]` to satisfy ORT's minimum. `OnnxProbe.swift` exposes `onnxRuntimeVersion()`; `main.swift` writes `voice: ONNX Runtime <ver>` to stderr at launch. .app binary grew from ~7 MB to ~33 MB (static-linked, only referenced ORT symbols pulled in; will grow further once sessions/tensors land in 7.1i).

b. **Settings.voiceModelPath — shipped 2026-05-05 (`c6f2a6d`).** `String?` field on `Settings` with `encodeIfPresent` / `decodeIfPresent` so legacy JSON migrates to nil. 3 tests: default-nil, Codable round-trip, legacy-JSON tolerance.

c. **Voice catalogue — shipped 2026-05-05 (`2544589`).** `Sources/RPClientCore/Voice/KokoroVoiceCatalogue.swift` (lives in Core, not RPClientVoice — pure data, lets `RPClientCoreTests` verify it directly). Exposes `KokoroVoiceCatalogue.all: [KokoroVoice]` as a Swift literal: 54 entries with id, displayName, language, gender, per-language sampleText. Download URL derived (`https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/<id>.pt`); `modelDownloadURL` + `modelByteSize` (325_532_387, exact) are constants. Compiled code, not a Bundle resource. 13 tests.

d. **Storage paths + scout — shipped 2026-05-05 (`3e39fb9`).** `KokoroStoragePaths` exposes the on-disk layout (`<root>/kokoro/{model.onnx, voices/<id>.pt, manifest.json}`). `VoiceStorageScout.options(from:applicationSupport:)` is a pure ranking function — orders external volumes by free space desc, drops internal volumes and any below 600 MB, appends Application Support as fallback. `liveOptions()` is the FileManager-probing wrapper. 15 tests including label format, free-space ordering, mount-point heuristics.

e. **Manifest + model store — shipped 2026-05-05 (`34d3846`).** `KokoroManifest` is the Codable state file at `<root>/kokoro/manifest.json` (versioned, `.empty` constant, decode-tolerant init). `KokoroModelStore` is synchronous state queries + atomic manifest IO. State enum: `.missing | .ready(URL, sha256: String?) | .volumeUnavailable` (separately for model and voices). File presence wins over manifest record — orphan file reads as `.ready(_, sha: nil)`. Volume unavailability detected via `/Volumes/<X>` mount-point heuristic. Manifest writes are atomic (temp file + replaceItemAt). 14 tests including persistence across store instances, removeVoice idempotency, orphan handling, volumeUnavailable detection.

f. **Two-tier toggle data layer — shipped 2026-05-05.** `Settings.voiceActive: Bool` (persisted, default `true`) added alongside `voiceEnabled`, with the same `decodeIfPresent` legacy-tolerance pattern as `voiceModelPath`. `Speaker` now stores both flags and gates `speak` + `handleStreamFinished` on `voiceEnabled && voiceActive` via a `shouldSpeak` computed property; `setVoiceEnabled` and the new `setVoiceActive` both call `stopSpeaking()` when flipping from speaking → silent so the toggle feels live. `Speaker.startObserving` now subscribes to `AppNotification.voiceActiveChanged` and re-mirrors both flags from `Settings` on `settingsChanged`. Legacy single-arg `Speaker(voiceEnabled:)` init kept (with `voiceActive: Bool = true` default) so existing call sites compile unchanged. Settings UI checkbox relabelled "Speak replies" → "Enable voice subsystem". 11 new tests (4 gating combos, setVoiceActive stop-on-mute, no-stop on enable, notification name, legacy-init default, Settings default + Codable round-trip + legacy-JSON tolerance); 301/301 green.

g. **Storage prompt sheet + always-visible storage row in Settings — shipped 2026-05-05.** Two pieces:

   - `Sources/RPClientCore/Voice/VoiceStoragePrompt.swift`: pure trigger predicate `shouldPrompt(old:new:) -> Bool` — fires iff `voiceEnabled` flipped false→true AND `voiceModelPath` is nil/empty. 5 unit tests covering each transition.
   - `Sources/RPClientCore/UI/Voice/VoiceStoragePromptSheet.swift`: NSAlert-based sheet with popup accessory listing `VoiceStorageScout.liveOptions()` plus a "Choose another folder…" escape hatch that drops into an `NSOpenPanel` (with `canCreateDirectories = true` so users can make a new folder anywhere). Static `present(over:options:completion:)` returning the chosen URL or nil.

   **Plan deviation: Cancel = abort, not silent fallback.** Plan §7.1 originally said dismissing the sheet falls back to Application Support; revised to "Cancel rolls `voiceEnabled` back to false" so cancelling actually means cancelling. User has to explicitly re-tick to re-fire the sheet.

   **Settings UI also gained an always-visible storage row** (separate from the first-run sheet): below the "Enable voice subsystem" checkbox, a `Voice storage:` label with the chosen path (truncating-middle, tilde-abbreviated, full path in tooltip) and a `Set location… / Change location…` button that re-fires `VoiceStoragePromptSheet` directly. Edits update a `voiceModelPathDraft` ivar; `save()` persists. Cancelling a Change… sheet is a no-op (distinct from the first-run abort behaviour). Pre-picking a path via the row also satisfies the trigger condition, so subsequently enabling the subsystem won't double-prompt.

   **Wiring in `save()`:** capture old settings, persist new, then call `VoiceStoragePrompt.shouldPrompt(old:new:)`; if true, present the sheet. On Save with a chosen URL → second `saveSettings` with `voiceModelPath` set + close. On Cancel → `voiceEnabled = false` rollback + close. UI/side-effect surface — smoke-tested per the AppKit exemption; only the predicate is unit-tested.

h. **Voice library manager — split into h1 (read-only) + h2 (action buttons).**

   h1. **Read-only catalogue window — shipped 2026-05-05.** `Sources/RPClientCore/UI/Voice/VoiceLibraryWindowController.swift` opens as a separate non-modal window (560×520, resizable, autosaved frame). Plan originally said a section in Settings; revised to a separate window because Settings has no tabs and a 54-row table doesn't belong inline. Reached via a "Voice library…" button in the Settings storage row, alongside Set/Change location.

   The window subscribes to `settingsChanged` and rebuilds on every save. Layout top-to-bottom: storage banner (`Storage: ~/...`); base-model state row reading `KokoroModelStore.baseModelState()` (✓ ready / ◯ not downloaded / ⚠︎ volume unavailable); filter bar with Language popup (All + 9 langs) + Gender popup (All + Female + Male) + voice count label; `NSTableView` with columns Voice, Language, Gender, State. Per-voice state computed live from `KokoroModelStore.voiceState(id:)`. When `voiceModelPath` is nil, banner reads "No storage location set" and state cells show "—" — the catalogue is still browsable. No action buttons in h1.

   **Storage save-immediate fix.** Originally the Settings storage row buffered a `voiceModelPathDraft` ivar and only persisted on Save. That meant changing the path then opening the Voice library showed the *old* path because `settingsChanged` hadn't fired. Removed the draft: `Change location…` now calls `AppState.shared.saveSettings(s)` directly, so any observer (including the library window) sees the new path immediately. Cancel-on-Settings doesn't revert the path change — storage location isn't a tweak-and-revert field.

   **Sheet UX revision: popup-action fires picker.** `VoiceStoragePromptSheet` was an enum with a static `present`; refactored to a class with self-retaining instances so `NSPopUpButton.target/action` can fire on the live coordinator. Selecting "Choose another folder…" from the popup now ends the alert sheet and presents `NSOpenPanel` immediately on the same window — no Save click required. Cancelling the panel cancels the whole flow. Public API (`present(over:options:completion:)`) unchanged.

   h2. **Action buttons — split: base shipped with §7.1j2, per-voice shipped 2026-05-05, Preview deferred to §7.1k.**

   Base-model Download / Cancel / Remove landed alongside the download manager in §7.1j2. Per-voice rows now host an Action column with the same Download / Cancel / Remove cycle, driven by the same `KokoroDownloadManager`. Per-row Download is disabled with tooltip "Download the base model first" until the base reports `.ready` (voices alone are useless without it). Cancel works mid-flight; Remove calls `KokoroModelStore.removeVoice(id:)`. State column shows live download progress per voice ("⬇︎ 156 KB of 524 KB (29%)") and falls back to on-disk truth (✓ installed / ◯ not installed) once the download settles. Progress updates reload only the affected row via `tableView.reloadData(forRowIndexes:columnIndexes:)` so a 54-row table doesn't churn per network chunk. No "download all" affordance — every voice is opt-in per voice.

   **Preview button — deferred to §7.1k.** Previewing a voice requires synthesising a short canned line, which means the engine must exist. Cleanest to add Preview as a column in h2's table when k lands and `KokoroSpeechSynthesizer` is real, rather than ship a stubbed Preview now.

   The window-level "hide when `voiceEnabled == false`" affordance from the original plan is moot — the library opens regardless of subsystem state because the catalogue is browsable independent of being able to play voices, and the per-row buttons already self-gate on `KokoroModelStore` state.

i. **Main-UI speaker toggle button — shipped 2026-05-05 (out of order, after f).** Added inline to `ChatViewController` rather than a separate `ChatHeaderSpeakerButton.swift` — the chat header is still small enough that a dedicated file would be premature abstraction. 22×22 pt borderless `NSButton`, anchored to the trailing edge of `chatHeader`. Icon swaps `speaker.wave.2.fill` ↔ `speaker.slash.fill` based on `Settings.voiceActive`. Disabled (`isEnabled = false`, `alphaValue = 0.4`) when `voiceEnabled == false`, with tooltip "Enable the voice subsystem in Settings". Click path: guard on `voiceEnabled`, toggle `voiceActive`, `AppState.shared.saveSettings(s)`, post `voiceActiveChanged`. Observers: `settingsChanged` (rebuilds picker + speaker button) and `voiceActiveChanged` (just speaker). Smoke-tested per AppKit/side-effect exemption — no unit tests faked.

j. **Download manager — split into j1 (pure types) + j2 (manager) + future j3 (per-voice wiring).** Lands in `RPClientCore` rather than `RPClientVoice` (plan said "likely RPClientVoice"; revised because it's pure URLSession + Foundation with no ONNX dep, and putting it in Core lets `RPClientCore` UI consume it without re-exporting symbols).

   j1. **Pure types + SHA-256 helper — shipped 2026-05-05 (`0323dfe`).** `KokoroDownloadAsset` (`.baseModel | .voice(id:)`), `KokoroDownloadTask` (asset + sourceURL + destinationURL + expectedBytes + stable id), `KokoroDownloadState` (queued / running / completed / cancelled / failed). `Sha256.hex(of:)` and `Sha256.hex(ofFileAt:)` (CryptoKit-backed; file variant streams 256 KB chunks). 9 unit tests covering id mapping, state equality, and SHA against canonical vectors + a 5 MB multi-chunk streaming fixture.

   j2. **KokoroDownloadManager + h2 base-model controls — shipped 2026-05-05.** `Sources/RPClientCore/Voice/KokoroDownloadManager.swift` is an `NSObject` singleton implementing `URLSessionDownloadDelegate`. `enqueue(_:store:)` is idempotent; `cancel(id:)` works for both in-flight and queued tasks. Concurrency cap of 2 enforced via a `pendingQueue` + `inFlight` map; `drain()` pulls from pending whenever a slot frees up. On `didFinishDownloadingTo`: streamed SHA-256 of the temp file → atomic move to destination → `KokoroModelStore.recordModelDownloaded` / `recordVoiceDownloaded`. State transitions post `AppNotification.kokoroDownloadStateChanged` with the task id in `userInfo` so UI can re-read `state(of:)` cheaply.

   The base-model row in `VoiceLibraryWindowController` now hosts a Download/Cancel/Remove button next to the state label. Live progress text ("⬇︎ 142.7 MB of 325.5 MB (43%)") via the new notification subscription. Cancel correctly removes the temp file (`URLSession` handles this) and the manifest stays untouched. Smoke-tested end-to-end on a real network: download → mid-flight cancel → restart → completion → remove. Per-voice action buttons (Download/Remove + Preview) deferred to a follow-up commit since they're substantial UI changes (per-row buttons in the table) and don't change the manager.

k. **Adapter — split into k-prep, k1–k4 (engine), then integration.** Highest-risk sub-step. Two design questions settled with the user before code:

   **G2P decision (2026-05-05):** subprocess to system `espeak-ng` rather than vendoring or building a Swift G2P. Reasons: (a) Kokoro was trained on espeak-ng/misaki phonemes, so any other G2P degrades quality via distribution shift; (b) GPL-3 stays out of our binary because espeak-ng runs as a separate process; (c) ~100 LOC of `Process` + `Pipe` wrangling vs. multi-week from-scratch Swift G2P; (d) one-time `brew install espeak-ng` is fair friction for a developer-targeted local-first app, and unblocks the full 9-language catalogue. Rejected alternatives: vendored neural G2P ONNX (~5 MB, English-only, noticeably lower quality due to phoneme distribution mismatch); from-scratch Swift CMUdict + LTS rules (~5K LOC + 3 MB dict); deferring k entirely (half the value of §7.1).

   **.pt parsing decision (2026-05-05):** parse the PyTorch pickle in Swift at inference time (~50 LOC for the single-tensor case). Rejected alternative: pre-process at download time to a flat float buffer (would couple the download path to engine internals).

   **k-prep — espeak-ng detection + library UI surface — shipped 2026-05-05.** New `Sources/RPClientCore/Voice/EspeakNg.swift` with `find()` + a pure `resolve(candidates:fileExists:whichLookup:)` resolver. Probe order: `/opt/homebrew/bin/espeak-ng`, `/usr/local/bin/espeak-ng`, then `/usr/bin/which espeak-ng` for non-default installs. 7 unit tests cover the path-resolution edges; the `which` shell-out is smoke-tested. Voice library window gains a persistent status row above the base-model row: `✓ found at <path>` when present (secondary text), or `◯ not installed — required for Kokoro voices.` with a monospace `brew install espeak-ng` + Copy + Re-check pair when missing. Re-check refreshes detection without an app restart. Window default size also bumped to 760×560 (was 560×520 — too narrow for the 5-column table after h2 added the Action column); minSize 660×360. Autosave key rolled to `.v2` to invalidate any too-narrow saved frame from earlier dev.

   k1. **Voice tensor loader — shipped 2026-05-05.** Modern PyTorch save format is a ZIP archive with `<voice>/data/0` carrying the raw float32 tensor (verified against `af_alloy.pt`: 522240 bytes = 510 × 1 × 256 × 4). We skip pickle parsing entirely since every Kokoro voice has the same known shape — read `data/0`, reinterpret as `[Float]`, validate length.

      Two new files in `RPClientCore`: `MinimalZipReader.swift` (STORE-only, ~120 LOC, throws `unsupportedCompression` on DEFLATE since voices don't compress) and `KokoroVoiceFile.swift` (thin wrapper exposing `loadStyleEmbedding(from:) throws -> [Float]`). 9 new tests: ZIP reader covers single + multi-entry round-trips, EOCD with trailing comment, missing-entry nil return, garbage input → `eocdNotFound`, DEFLATE entry → `unsupportedCompression`. Voice loader runs as integration tests against any voice file under `voiceModelPath` (skipped with a printed note when no voice has been downloaded yet) — verifies 130560 floats, all finite, all reasonably bounded.

   k2. **Text → token-id pipeline. Split into k2a (espeak client) + k2b (tokenizer).**

   k2a. **EspeakNgClient — shipped 2026-05-05.** `Sources/RPClientCore/Voice/EspeakNgClient.swift`: `Process` + `Pipe` wrapper that pipes text on stdin to `espeak-ng -q --ipa=3 -v <code>` and captures the IPA string from stdout. Stdin route (rather than positional argument) sidesteps shell-quoting issues for long passages. `KokoroLanguage → espeak voice code` mapping is pure-tested for all 9 languages (en-us, en-gb, ja, cmn, fr-fr, es, it, hi, pt-br). Smoke tests run against the real espeak-ng when present (skipped with a printed note otherwise) — verify "Hello, world." returns non-empty IPA, output is deterministic, and a bogus binary path throws `launchFailed`. The Speaker-level fallback to AVKit when `EspeakNg.find()` returns nil lives in §7.1l (engine selection).

   k2b. **KokoroTokenizer — shipped 2026-05-05.** `Sources/RPClientCore/Voice/KokoroTokenizer.swift` pins the canonical 114-entry vocab from `huggingface.co/hexgrad/Kokoro-82M/config.json` (fetched 2026-05-05) as a `[String: Int64]` literal, ids 1–177 with intentional gaps for upstream-reserved tokens. `tokenize(ipa:) -> [Int64]` NFD-normalises the input then iterates Unicode scalars (not `Character`s — TDD caught a real bug here, see below), looks each scalar up, drops any miss, and wraps the result with leading + trailing pad token (id 0).

   The scalar-iteration choice is load-bearing. espeak emits diphthongs like `o‍ʊ` and `e‍ɪ` with a U+200D ZWJ tie mark joining the components. Swift's default `for ch in string` iterates extended grapheme clusters, which means `o‍ʊ` reads as a single `Character`. The vocab has `o` and `ʊ` separately but no entry for the joined cluster, so cluster-iteration would silently drop both and break inference. Scalar iteration decomposes the cluster correctly. NFD normalisation handles the symmetric case where a precomposed glyph like `ã` (U+00E3) needs to split into `a` + combining tilde, both of which are separate vocab entries.

   9 new tests: vocab integrity (count + spot-check known ids), pad-token wrapping for empty input, hand-traced "Hello, world." IPA → known token sequence (also verified against the real espeak output for that string), space tokens between words preserved, unknown chars dropped, ZWJ tie marks dropped, newlines dropped, end-to-end espeak → tokenize on real espeak-ng (skipped if not installed) produces a non-trivial sequence of in-range tokens.

   k3. **ONNX session loader + inference (NEXT UP).** Pending. Lives in `RPClientVoice` (only piece of k that needs ORT symbols). New file `Sources/RPClientVoice/KokoroEngine.swift` (or split `KokoroSession.swift` + `KokoroEngine.swift` if it grows).

   Pre-coding probe shipped alongside this revision (`Sources/KokoroProbe`, run with `swift run KokoroProbe <model>`). Against the bundled `model.onnx` it prints inputs `tokens / style / speed` and output `audio`. So the bundled model is the **legacy export**, not the newer `input_ids` export — matters because [kokoro-onnx Python](https://github.com/thewh1teagle/kokoro-onnx/blob/main/src/kokoro_onnx/__init__.py) `_create_audio` branches on which export it sees and uses different dtypes for `speed` (the newer export passes `int32`, legacy passes `float32`). The Swift/Obj-C ORT bindings don't expose model-schema element types directly — only runtime `ORTValue` types — so this name probe is the only schema introspection these bindings allow without parsing ONNX protobuf.

   Inputs to model.onnx (legacy export — verified against probe + `kokoro-onnx` Python):
   - `tokens: int64[1, N]` — `KokoroTokenizer.tokenize(ipa:)` output (already pad-wrapped) as a 2D tensor of shape [1, len].
   - `style: float32[1, 256]` — speaker style embedding. The loaded `.pt` is `[510, 1, 256]` = 130560 floats; the model wants one `[1, 256]` slice. **Verified slice rule:** kokoro-onnx Python does `voice = voice[len(tokens)]` *before* wrapping `tokens` with leading + trailing pad. Our `KokoroTokenizer.tokenize(ipa:)` already wraps with pad, so in our terms the index is `style[paddedTokens.count - 2]` — i.e. unpadded length. (An earlier draft of this plan said `style[len(input_ids) - 1]`; that was off by one. Wrong indexing produces audio that's garbled but plausible-sounding, hard to debug — flagged.)
   - `speed: float32[1]` — playback rate, 1.0 = default. (Legacy export uses float32; the newer `input_ids` export uses int32, but we're not on that path.)

   Output: `audio: float32[N_samples]` — raw PCM at 24 kHz mono. Pass straight to `AVAudioEngine` in k4.

   API sketch:
   ```swift
   final class KokoroEngine {
       init(modelURL: URL) throws         // loads ORTSession, validates IO names
       func synthesize(tokens: [Int64], style: [Float], speed: Float) throws -> [Float]
   }
   ```

   Smoke test: load model + af_alloy.pt, tokens from `EspeakNgClient + KokoroTokenizer` on "Hello, world.", speed 1.0 → return `[Float]` PCM with non-zero RMS, length plausibly ~24000–48000 samples (1–2 s of audio). Validate at the test level by writing the floats to a `.wav` file and listening — there's no automated "is this speech?" check at this layer.

   ORT Swift API to use: `ORTSession`, `ORTValue.init(tensorData:elementType:shape:)` for inputs, `session.run(withInputs:outputNames:runOptions:)` for inference. Input/output names probed at session-init time (`session.inputNames`, `session.outputNames`) and asserted to match expected (`tokens`, `style`, `speed`, `audio`) so a future model bump fails fast — and so we notice if a download ever switches to the newer `input_ids` export, which would force a `speed`-dtype change.

   k4. **AVAudioEngine playback.** Pending — `AVAudioEngine` + `AVAudioPlayerNode`, schedule the `[Float]` PCM as an `AVAudioPCMBuffer` at 24 kHz mono. `stopSpeaking()` calls `playerNode.stop()` + `engine.reset()`.

   k5. **`KokoroSpeechSynthesizer` adapter.** Pending — conforms to `SpeechSynthesizing` from §7.0. Owns a `KokoroEngine` + `AVAudioEngine` pair. `speak(_:)` runs espeak → tokenize → synthesize → play, all on a background queue so the call returns fast. Lives in `RPClientVoice`. Selection wiring lives in §7.1l.

   k6. **Long-form natural speech — shipped 2026-05-05.** Three sub-fixes the §7.1n smoke surfaced, all bundled because they're all in service of "real assistant replies sound right":
   - **Token chunking.** `KokoroEngine` rejects token sequences longer than its 510-slot style buffer; real replies hit ~1600 tokens. New `KokoroTokenChunker` (Core) splits a pad-wrapped token sequence into chunks ≤500 unpadded each, preferring breaks by tier: sentence-end (`. ! ? — …`) → clause-end (`; :`) → comma → space → hard cap. The trailing pad cues end-of-utterance prosody to the model, so a comma split sounded like a fake full stop — preferring harder punctuation hides this. Leading space tokens are stripped from each chunk so chunks 2+ don't begin with a "pause" cue. The adapter synthesizes per chunk and schedules each on `AVAudioPlayerNode` in turn; the player queues internally so playback starts on the first chunk and stitches on without gaps.
   - **Punctuation-preserving phonemization.** `espeak-ng -q --ipa=3` strips ALL punctuation from its phoneme output — robotic monotone with no pause/intonation cues. New `EspeakNgClient.phonemizePreservingPunctuation` splits the input on `, ; : . ! ? — …`, runs `phonemize` per segment, and stitches the IPA back with the original punct chars between segments. ~30 ms per subprocess; 150–300 ms total for typical replies. Upstream `kokoro-onnx` Python uses `phonemizer.phonemize(..., preserve_punctuation=True)`, which has no CLI equivalent.
   - **Colon → period mapping.** Kokoro produces no audible pause for `:` (auditioned `;`, `,`, `.`; the user picked `.` as the right pause length). Remap happens at the IPA layer in the same method.
   Known model limitation: `?` produces flat intonation (no question lilt). Not fixable without retraining; flagged.

l. **Wiring — shipped 2026-05-05.** `KokoroSpeechSelector` in Core observes `settingsChanged` + `kokoroDownloadStateChanged` and picks AVKit vs Kokoro based on `Settings.voiceEnabled`, `KokoroModelStore.baseModelState()`, and at-least-one installed voice. `Settings.voiceEnabled` toggle drives initial adapter selection (subsystem on → load Kokoro, subsystem off → swap back to AVKit + deinit Kokoro). The factory closure injecting `KokoroSpeechSynthesizer` lives in the RPClient executable so Core doesn't need to import RPClientVoice. `Speaker.setSynthesizer(_:)` does the live swap (stops old, swaps in new). `VoiceLibraryWindowController` posts `kokoroDownloadStateChanged` after asset removal so the selector reverts cleanly.

m. **Voice identifier namespacing — shipped 2026-05-05.** `VoiceIdentifier` typed value (`engine:voice-id`, Codable as a single string) so §7.2's `VoicePreference.voiceIdentifier` survives engine swaps. Splits on the first colon only (defensive against future engines whose voice ids might themselves contain colons); rejects unknown engine prefixes, empty segments, and missing colons.

n. **Smoke test — verified 2026-05-05.** `./build.sh && ./run.sh`, toggled "Enable voice subsystem" on in Settings, voice library already had base model + voice files (`af_alloy`, `af_aoede`), chat-header speaker button enabled, clicked it on, sent a message, audited Kokoro output as materially better than AVKit baseline (after the k6 fixes — initial smoke surfaced the chunker overflow, punctuation strip, and colon-flat issues that k6 resolved). Toggle chat-header button off → reply silent. Toggle subsystem off → button greyed.

**Followup polish (out of §7.1):** chat-header speaker button uses black for the "active" state instead of orange. Tracked as a separate visual fix.

**Risks / open:**

- **Download UX.** No progress UI today in Settings — this is the first long-running side-task in that surface, and the multi-row catalogue makes it a *parallel* download manager (user can hit "Download" on three voices at once). Cap concurrency at 2 to avoid thrashing the user's bandwidth.
- **Catalogue currency.** The Swift-literal `KokoroVoiceCatalogue.all` goes stale when upstream adds voices. Acceptable trade-off vs. fetching a remote catalogue (which would mean a hardcoded URL with its own decay risk). Bump the literal in lockstep with Kokoro version bumps.
- **.pt parsing on the Swift side.** HuggingFace ships per-voice files as PyTorch `.pt` tensor archives (pickle format). For ONNX inference we need the speaker style embedding as a flat float buffer. Either parse the pickle ourselves (~50 lines for a single-tensor case) or pre-process at download time. Decision deferred to 7.1g (adapter) — 7.1c–7.1f only need to know "the file exists at `<path>/voices/<id>.pt`."
- **Test coverage.** Pure logic is testable: catalogue parsing, manifest read/write, voice-id parsing, storage-path resolution, mount/unmount state transitions. The ONNX-driven synth, URLSession downloads, and `AVAudioEngine` glue are smoke-tested per the AppKit/side-effect exemption — flag honestly, don't fake unit tests for "did the audio play."
- **Binary size.** Static linkage of ONNX adds ~25 MB to the .app today (only referenced symbols pulled in); expect ~80 MB once sessions/tensors land in 7.1c. Acceptable for a local-first model-running app.
- ~~ONNX Runtime on Apple Silicon~~ — resolved in 7.1a: `microsoft/onnxruntime-swift-package-manager` 1.24.2 integrates cleanly via SwiftPM with no xcframework vendoring needed.

**Effort: 2–3 days.** Voice library UI is the long pole now (catalogue table + download manager + storage picker); the adapter itself is contained.

### 7.2 Data model — shipped 2026-05-05

```swift
struct Entity {
    // existing fields...
    var voice: VoicePreference?    // nil → use chat default
}
struct VoicePreference: Codable, Equatable {
    var voiceIdentifier: VoiceIdentifier   // §7.1m — `<engine>:<voice-id>`
    var rate: Float                        // 1.0-centred multiplier
    var pitch: Float                       // 1.0-centred multiplier
}
```

`voiceIdentifier` is the §7.1m typed value (`engine:voice-id`, Codable as a single string). Existing chats with no voice preference set leave the field nil; migration is "if Entity.voice is missing, treat as nil and fall back to chat-default." `rate` and `pitch` are 1.0-centred multipliers shared by both engines (Kokoro's `speed` parameter and AVKit's rate/pitch are both multiplicative around 1.0); the plan range is 0.5..2.0 but range validation deliberately lives at the UI/engine boundary, not in the decoder, so an out-of-range value persisted by an older or hand-edited build still loads.

Sub-step shape that landed:

- **§7.2a — `VoicePreference` struct + Codable.** New file `Sources/RPClientCore/Voice/VoicePreference.swift`. Custom decoder: missing nested `rate`/`pitch` → 1.0 (matches the `decodeIfPresent ?? default` pattern used in `Entity` and `Settings`); missing or malformed `voiceIdentifier` throws (the preference is unusable without it). 8 pure tests in `VoicePreferenceTests`.
- **§7.2b — `Entity.voice: VoicePreference?` + migration.** One-line addition to `Entity` plus a `decodeIfPresent` line in its existing custom `init(from:)`. 4 migration tests in `EntityVoiceTests` cover: old-shape JSON (no `voice` key) decodes nil, new-shape round-trips, explicit `null` decodes nil, malformed nested voice rejects the whole entity (we'd rather throw than silently bind the wrong voice).
- **§7.2c — `Chat.voice: VoicePreference?` + `Settings.defaultVoice: VoicePreference?`.** Two-tier fallback: `Entity.voice ?? Chat.voice ?? Settings.defaultVoice`. Per-chat override mirrors the Entity migration shape (one `decodeIfPresent` line). Settings field uses `encodeIfPresent` so a fresh install doesn't grow a useless `"defaultVoice": null` key. 6 migration tests in `ChatSettingsVoiceTests`. The speaker layer (§7.4) is the consumer of the fallback chain; §7.5 only writes to these fields.

### 7.3 Speaker attribution — shipped 2026-05-05

Given a streamed assistant turn, decide which entity is speaking each segment. Two strategies; user picks per-chat via `Chat.attributionMode` (default `.heuristic`, additive Codable migration). Pure logic in `Sources/RPClientCore/Voice/SpeakerAttribution.swift`; output is `[AttributedSegment]` consumed by §7.4b's queue.

- **Heuristic.** Walk the text on quote boundaries (ASCII `"` and curly `\u{201C}`/`\u{201D}`). Each quoted span is attributed to the entity whose name or alias appears latest in *all preceding text* (revisit if long-form drift becomes a problem). Quoted spans with no preceding mention fall back to narrator. Unmatched opening quotes degrade gracefully — the rest of the turn becomes narration so a stray `"` doesn't blackhole content.
- **Tagged.** Line-based. `^Name: text` matched against entity names + aliases (case-insensitive, allowing internal spaces, hyphens, apostrophes). Untagged or unknown-name lines are narrator. Tag remains in the spoken text — natural for either reading style.

Adjacent same-speaker segments are coalesced so the queue plays one utterance per speaker rather than chopping at every quote. 17 pure tests in `SpeakerAttributionTests`.

UI for picking mode: deferred to §7.5d (a small chat-header dropdown alongside the voice picker). Default heuristic produces *some* per-character routing on day one with no convention — useful even before a UI exists.

### 7.4 TTS pipeline

Refactor the protocol seam, both engine adapters, and `Speaker` so per-call voice flows from the data model through to actual synthesis. Was originally scoped as "queue + per-segment voice swap" — the per-segment piece needs §7.3 attribution to be useful, so §7.4a ships the protocol + per-call swap and §7.4b (queue) folds in alongside §7.3 when speaker attribution lands.

- **§7.4a — Per-call voice swap — shipped 2026-05-05.** New `SpeakOptions` (voice, rate, pitch) carried through `SpeechSynthesizing.speak(_:options:)`. AVKit adapter looks up `AVSpeechSynthesisVoice(identifier:)` and maps our 1.0-centred rate/pitch into AVKit's native ranges. Kokoro adapter resolves voice per `speak()` call against `KokoroVoiceCatalogue.all` (catalogue carries the language; espeak gets that on every call), loads the .pt style buffer on demand, caches loaded buffers in a small dict (~510 KB each, 27 MB ceiling for the full 54-voice catalogue — no eviction needed). `Speaker` holds *both* engine adapters simultaneously and dispatches by `options.voice?.engine`; nil voice prefers Kokoro when installed (matches the pre-§7.4 default-engine behaviour). `Speaker.handleStreamFinished` resolves `chat.voice ?? settings.defaultVoice` and projects it into options. **§7.5's chat-header / settings pickers are now audible.** `KokoroSpeechSelector` no longer swaps the Speaker's lone synth; it installs/removes the Kokoro adapter via `setKokoroSynthesizer(_:)`. Per-character routing still pending — §7.3 attribution is what splits a turn into segments.
- **§7.4b — Queue + per-segment voice swap — shipped 2026-05-05.** `SpeechSynthesizing.speak` gained an optional `completion: (() -> Void)?` so adapters can signal "this utterance finished playing." `Speaker.speakSegments(_:)` plays a `[(text, options)]` list in order, advancing on each completion; cross-engine queues work because every adapter fires its own completion. AVKit adapter became `NSObject` + `AVSpeechSynthesizerDelegate`, mapping per-utterance completions through the `didFinish` / `didCancel` callbacks (handlers kept in a dict keyed by `ObjectIdentifier(utterance)`). Kokoro adapter ties speech-level completion to the *last chunk's* `KokoroAudioPlayer.play` completion, with a `FireOnce` wrapper so failure paths and successful completion can't double-fire. `Speaker.handleStreamFinished` now runs `SpeakerAttribution.split`, resolves each segment to options (entity voice → chat default → settings default), and dispatches the list. A monotonic queue generation in `Speaker` discards stale completions if `stop()` was called between segments. 4 new queue tests; per-character voices are now audible end-to-end.

### 7.5 UI

Two-tier fallback UI (entity → chat → settings — see §7.2). Sub-step shape:

- **§7.5a — Entity card Voice section — shipped 2026-05-05.** The "edit sheet" in the original plan is actually the inline entity card in the inspector's Entities pane (no modal). Each card now has a Voice row: NSPopUpButton with "(use chat default)" sentinel + sectioned Kokoro / AVKit options, and rate/pitch sliders (range 0.5..2.0) that appear only when a voice is set. Pure picker source lives in `VoicePickerSource.swift` — `KokoroVoiceCatalogue.all ∩ installedVoiceIds()` plus `AVSpeechSynthesisVoice.speechVoices()` injected by the AppKit layer (so the type stays test-friendly without `AVFoundation` in the test target). 9 pure tests in `VoicePickerSourceTests`. A stored voice that's no longer installed is preserved as a "Stored (unavailable)" item so the selection isn't silently lost. Pitch slider is disabled with tooltip on Kokoro voices (the model has no pitch parameter; speed is the only knob there). **Preview button deferred to §7.4** — previewing an arbitrary Kokoro voice requires the per-segment style-buffer swap that's part of the §7.4 refactor; AVKit-only Preview was rejected as half-finished UX.
- **§7.5b — Settings default narrator picker + chat-header voice picker — shipped 2026-05-05.** Settings gets a "Default narrator voice:" row below "Voice storage:", bound to `Settings.defaultVoice`. Chat header gets a "Voice:" picker between the server picker and the speaker mute button, bound to `Chat.voice`. Both reuse `VoicePickerSource` (§7.5a) via a small AppKit-side helper at `Sources/RPClientCore/UI/Voice/VoicePopupBuilder.swift` that handles popup population, sentinel-item insertion (per-surface label: "(use chat default)" / "(use settings default)" / "(none — system fallback)"), the "Stored (unavailable)" fallback for uninstalled voices, and selection round-trip. The §7.5a entity card was refactored to use the same helper, so all three surfaces share the same selection semantics. **Picker only — no rate/pitch sliders on chat or settings.** Rate/pitch tuning lives on the per-entity card (where it's actually meaningful for character voicing); chat and settings defaults ride at 1.0/1.0. Acceptable trade-off: the global default is rarely the place users want to tune speed.
- **§7.5d — Per-chat attribution mode picker — shipped 2026-05-05.** Chat header gains an "Attribution:" picker between the Server section and the Voice section, two items (Heuristic / Tagged), bound to `Chat.attributionMode`. The picker uses `representedObject` to carry the rawValue, so the action handler is decoupled from menu order — adding a third mode in §7.6 only needs an enum case + a `displayName` entry. `AttributionMode.displayName` lives in `SpeakerAttribution.swift` next to the enum so future modes get their UI label as a single addition. No new helper module yet — the picker is small enough that inlining it in `ChatViewController` (rebuild + action) costs less than abstracting. If a fourth voice-related per-chat picker shows up, fold all three (Voice, Attribution, future) into a shared chat-header builder. UI smoke-tested; the model-layer round-trip (`Chat.attributionMode` Codable migration) is already covered by `ChatSettingsVoiceTests`.

**Effort: ~2 days for §7.2–§7.5 once §7.1 lands.** §7.1, §7.2 (a/b/c), §7.5 (a/b/d), §7.3, §7.4 (a/b) all closed 2026-05-05 — Phase 6 is feature-complete for per-character voices, plus the attribution-mode escape hatch that gives users a fallback when the heuristic underperforms. Optional polish remaining: §7.5c (Preview button on the entity card, unblocked by §7.4a's per-call swap) and §7.6 (heuristic refinement pass over a real chat corpus).

### 7.6 Heuristic refinement pass — pending

Land §7.5d first so users can switch to tagged mode when heuristic underperforms, then come back here.

The §7.3 attribution heuristic — and the polish that landed 2026-05-05 — was tuned against a handful of one-off chat snippets the user fed back. Each round identified a class of mis-attribution (quote-first dialogue verbs, bare `I` short-circuit, stale-mention dominance, character-card vs. entity-name mismatch) and generalised it into a rule. That worked for the obvious classes, but the heuristic is necessarily fragile against the long tail of model output styles. A proper refinement pass should:

1. **Collect a corpus** of recent assistant turns from real chats, captured at the input boundary of `SpeakerAttribution.split`. Anonymisation only if multi-user becomes a concern; today RPClient is single-user.
2. **Run the current heuristic** over the corpus and dump `(turn-text, predicted-segments, attributed-voices)` triples to a fixture file.
3. **Hand-label** the right answer for a representative sample (50–100 turns covering different chat styles, character setups, language registers).
4. **Compute a confusion matrix** — identify dominant failure modes. Likely candidates: pronoun resolution (`she/he/they` mapping to wrong character), speaker-continuity loss after action verbs (`Sage smiled. I waved. "Hi."`), overlapping first/third-person within a paragraph, model-specific quirks (some models attribute via `, X said.` consistently; others use action-verb patterns).
5. **Decide per failure mode:** heuristic tweak, gate behind tagged mode (defaulting more chats to tagged when patterns are ambiguous), or document as a limitation.

Sequence the work so each tweak is validated against the *full* corpus rather than the one chat that motivated it — the sample-size-of-one tuning the heuristic has had so far is the bug class this step is trying to break out of.

**Research point — synthetic training data via self-driven chats.** A future agent session doing this refinement could drive the chat client itself to generate corpus turns under controlled conditions: spin up a chat with a known character setup, issue prompts crafted to elicit specific dialogue patterns (quote-first attribution, deeply nested first-person POV, multi-character exchanges, mixed pronoun + name reference, etc.), and label the expected attribution as part of the prompt design. That gives a reproducible test bed independent of any single user's chat history, and lets the heuristic be tested against deliberately-varied output rather than the narrow band of styles a single chat produces. Open questions:

- **Programmatic chat send.** Today there's no programmatic entry point for sending a turn; the path runs through `InputBar` + `AppState.send`. Would need either an internal test-driver hook (`AppState.sendForTest(chatId:text:)`), or a CLI subcommand that loads a chat by id, posts a turn, waits for streamFinished, and dumps the result.
- **Labels.** Two sources: author-by-construction (the prompt asks for a specific shape and the test asserts the shape; brittle if the model deviates) and agent-as-labeller (the driving agent reads its own output and suggests labels for review). Probably both, with human spot-check.
- **Cost.** Each generated turn hits the user's running koboldcpp; modest counts (≤200 turns) keep this trivial. Cache the generated corpus to disk so labels can iterate without re-generating.
- **Determinism.** Fix sampler temperature low + seed where possible so the corpus is stable across re-runs of a refinement experiment.

This is research, not a sized work item — the deliverable is a design doc that proposes the corpus-collection pipeline and the labelling protocol before any code is written.

**Known follow-ups:**
- Audio trimming between chunks. The model emits ~50–100 ms of trailing silence per synthesized chunk; concatenation accumulates these into noticeable gaps on multi-chunk replies. Upstream `kokoro-onnx` Python uses `trim_audio` on each chunk to remove leading/trailing silence. Add a Swift equivalent (RMS-windowed silence trim) before scheduling each PCM buffer in `KokoroSpeechSynthesizer.speak`. Cosmetic — current §7.1 output is acceptable but not ideal.
- Question lilt (rising intonation at `?`). Kokoro's training apparently produces flat prosody for `?`. Not fixable without model retraining; documented limitation.
- Per-character voice routing assumes the "narrator" / chat-default voice is always Kokoro when the subsystem is on. Quoted lines could be routed to per-entity voices via §7.3's attribution, then §7.4's queue. The selector wiring in §7.1l only knows about a single global voice; needs to be extended to a multi-voice resolver in §7.4.

---

## 8. Phase 7 — V2 Full branching

Treat as its own design doc. Headline questions to settle before coding:

- **Storage.** Tree of `Turn` nodes with `parentId`, `childrenIds`, `activePathId` per chat? Or flatten to `nodes: [Node]` + `path: [UUID]` with derived parent/child? The flat list is easier to render and diff; the tree is easier to reason about during traversal.
- **Migration from swipes.** Variants on a turn become first-class child nodes with the same parent. Forward-compatible if storage is flat.
- **UI.** Branch indicator (mini-tree minimap on the sidebar?), "Jump to branch" navigator, Cmd-↑/↓ to move along the active path, Cmd-B to fork from current.
- **Active-path semantics on regen.** Regenerating from turn N kills nothing — it forks. Old path remains discoverable.
- **Memory subsystem coupling.** Scene summaries today index by `turnIndex`. Branching breaks that — needs `turnId` indexing instead. This is a moderately invasive change to [`Memory/SceneSummary.swift`](Sources/RPClientCore/Models/SceneSummary.swift) and [`MemoryManager`](Sources/RPClientCore/Memory/MemoryManager.swift).

**Effort: 1 day design doc + 1 week+ implementation. Not picking this up casually.**

---

## 9. Phase 8 — V9 Group chats

The largest. Also its own design doc. Questions:

- **Speaker selection.** Round-robin? Director-LLM picks? User picks each turn?
- **Per-speaker prompt assembly.** Each AI gets its own system/memory block when generating, but sees the others' messages as user input? Or all assistant?
- **Token cost.** Linear in number of speakers per turn for the director-pick model.
- **UI.** Each turn tagged with speaker name + colour + avatar. Speaker picker in input bar.

Defer until after V1, V3, V6 land — those build the `Character`, swipe, and entity-voice primitives this would draw on.

**Effort: 1 day design doc + 1-2 weeks implementation.**

---

## 10. Cross-cutting concerns

### 10.1 Settings schema versioning

After Phase 4 (multi-server), the Settings shape changes substantially. Add `Settings.schemaVersion: Int` now (default 1) so future migrations have a hook. Bump to 2 after the multi-server rewrite.

### 10.2 Test backfill

Each phase ships with tests for the *new* code, but don't try to backfill Memory V2 tests as part of these phases. NEXT_STAGES §D1/D2 covers that separately.

### 10.3 Documentation

After Phase 3, update [`PLAN.md`](PLAN.md) §10 to strike completed items and leave a pointer to this doc for the rest. After Phase 4, add a "Servers" section to [`PLAN.md`](PLAN.md) §5.

### 10.4 Migration testing

Phases 1, 2, 3, 4 all change the Chat or Settings schema. Add a `Tests/MigrationFixtures/` directory with a snapshot JSON per pre-migration shape, plus a test that loads each, applies migration, and asserts the post-shape. This is cheap insurance against silently breaking older saves.

### 10.5 Sandboxing forward-note

RPClient is unsandboxed today. If a sandboxed build (App Store) is ever desired, several Phase 6 surfaces need adjustment: the user-configurable voice-model path (§7.1) needs security-scoped bookmark persistence rather than a raw URL string, and any future "user picks an external directory" UX inherits the same requirement. Not blocking; flagged here so it isn't a surprise later.

### 10.6 What this plan does **not** do

- Memory subsystem polish — see NEXT_STAGES §A.
- Chat-view UI overhaul — see NEXT_STAGES §E. Some items here (V10 avatars, V6 voices) lightly touch the chat view; the styling pass is independent.
- Per-character voices already on by default — voice integration is opt-in per chat.
- Inline image rendering in turns. Out of scope; revisit when there's a demand signal.

---

## 11. Effort summary

| Phase | Items | Effort | Cumulative |
|---|---|---|---|
| 1 | V5 Lorebook UI | 2 days | 2 | ✅ |
| 2 | V1 Swipes | 2-3 days | 5 | ✅ |
| 3 | V3 Character cards + V4 Personas | 3-4 days | 9 | ✅ |
| 4 | V8 Multi-server | 3 days | 12 |
| 5 | V10 Avatars (sidebar + turn) | 1 day | 13 |
| 6 | V6 Per-character voices | 2 days | 15 |
| 7 | V2 Full branching | 1 day design + 1 week+ build | ~21 |
| 8 | V9 Group chats | 1 day design + 1-2 weeks build | ~29+ |

Phases 1–6 together (~15 days of focused work) ship every V2 item except branching and group chats. Phases 7–8 are best treated as separate efforts with their own design rounds.

---

## 12. Recommended next move

Phases 1, 2, 3 are done. **Phase 6 is feature-complete** as of 2026-05-05 — §7.1, §7.2 (a/b/c), §7.5 (a/b/d), §7.3, §7.4 (a/b) all shipped, plus a heuristic-polish round (bare `I` short-circuit, lookback scoping, lenient first-person resolver, dialogue-verb subject detection). Per-character voices route end-to-end: pick a voice on an entity, send a message, the matching quoted lines narrate in that voice via the heuristic attribution. Tagged mode (`Sage: "…"`) also works for chats where the model produces that convention, and the chat-header attribution-mode picker (§7.5d) lets the user switch per-chat. 467/467 tests pass.

From a fresh context, the pragmatic next move is **§7.5c** (last quick polish) followed by **§7.6** (heuristic refinement, the load-bearing one). After that, **Phase 7 (V2 Full branching)** or **Phase 8 (V9 Group chats)** — both are sizeable refactors that warrant their own design rounds (PLAN.md §11). Remaining Phase 6 polish in suggested order:

- **§7.5c** — Preview button on the entity card. Unblocked by §7.4a's per-call swap; just needs a `Speaker.preview(voice:)` entry point that synths a canned line through an arbitrary voice without touching the live playback queue.
- **§7.6 — heuristic refinement pass.** The §7.3 polish was tuned against a small handful of one-off chat snippets. A real corpus-driven refinement pass — collect turns, run the heuristic, hand-label, fix dominant failure modes — is what gets the attribution from "usually right" to "reliably right". See §7.6 for the proposed shape, including a **research point on driving chats programmatically** to generate synthetic training data under controlled conditions. This is research, not a sized work item; expect a design doc first.

Phase 4 (V8 Multi-server) is also outstanding and roughly comparable in effort — pick whichever direction feels more pressing. Voice work has the larger surface area built up; multi-server is more self-contained.

Earlier recommendations preserved for historical context: original called for "start with Phase 1"; 2026-05-04 said "start with Phase 3"; 2026-05-04 update said "start with Phase 4 (V8 Multi-server)." All superseded by the §7.1 close.
