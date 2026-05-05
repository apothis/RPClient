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

**Implementation sketch:**

Sub-steps a–e are the data layer (all shipped, fully TDD-covered, 290/290 green). f onwards is the live UI / IO / engine work.

a. **Dependency wiring — shipped 2026-05-05 (`01109b0`).** Pulled `microsoft/onnxruntime-swift-package-manager` 1.24.2 as a SwiftPM dep (binary artifact, not a vendored xcframework). New `RPClientVoice` target (`Sources/RPClientVoice/`) sits between `RPClientCore` and the `RPClient` executable; it owns the ONNX import. `RPClientCoreTests` depends only on `RPClientCore`, so `otool -L` confirms zero ONNX symbols leak into the test binary. Bumped package `platforms: [.macOS(.v14)]` to satisfy ORT's minimum. `OnnxProbe.swift` exposes `onnxRuntimeVersion()`; `main.swift` writes `voice: ONNX Runtime <ver>` to stderr at launch. .app binary grew from ~7 MB to ~33 MB (static-linked, only referenced ORT symbols pulled in; will grow further once sessions/tensors land in 7.1i).

b. **Settings.voiceModelPath — shipped 2026-05-05 (`c6f2a6d`).** `String?` field on `Settings` with `encodeIfPresent` / `decodeIfPresent` so legacy JSON migrates to nil. 3 tests: default-nil, Codable round-trip, legacy-JSON tolerance.

c. **Voice catalogue — shipped 2026-05-05 (`2544589`).** `Sources/RPClientCore/Voice/KokoroVoiceCatalogue.swift` (lives in Core, not RPClientVoice — pure data, lets `RPClientCoreTests` verify it directly). Exposes `KokoroVoiceCatalogue.all: [KokoroVoice]` as a Swift literal: 54 entries with id, displayName, language, gender, per-language sampleText. Download URL derived (`https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/<id>.pt`); `modelDownloadURL` + `modelByteSize` (325_532_387, exact) are constants. Compiled code, not a Bundle resource. 13 tests.

d. **Storage paths + scout — shipped 2026-05-05 (`3e39fb9`).** `KokoroStoragePaths` exposes the on-disk layout (`<root>/kokoro/{model.onnx, voices/<id>.pt, manifest.json}`). `VoiceStorageScout.options(from:applicationSupport:)` is a pure ranking function — orders external volumes by free space desc, drops internal volumes and any below 600 MB, appends Application Support as fallback. `liveOptions()` is the FileManager-probing wrapper. 15 tests including label format, free-space ordering, mount-point heuristics.

e. **Manifest + model store — shipped 2026-05-05 (`34d3846`).** `KokoroManifest` is the Codable state file at `<root>/kokoro/manifest.json` (versioned, `.empty` constant, decode-tolerant init). `KokoroModelStore` is synchronous state queries + atomic manifest IO. State enum: `.missing | .ready(URL, sha256: String?) | .volumeUnavailable` (separately for model and voices). File presence wins over manifest record — orphan file reads as `.ready(_, sha: nil)`. Volume unavailability detected via `/Volumes/<X>` mount-point heuristic. Manifest writes are atomic (temp file + replaceItemAt). 14 tests including persistence across store instances, removeVoice idempotency, orphan handling, volumeUnavailable detection.

f. **First-run storage prompt sheet (next up).** New `UI/Voice/VoiceStoragePromptSheet.swift` — fired when `voiceEnabled` flips on and `Settings.voiceModelPath` is nil. Lists `VoiceStorageScout.liveOptions()` rows (detected externals + Application Support) plus a "Choose…" escape hatch. Persists choice into `Settings.voiceModelPath`; dismissing the sheet falls back to Application Support. Subsequent toggles do not re-prompt.

g. **Settings UI — Voice library manager.** New `UI/Settings/VoiceLibraryView.swift`. Persistent catalogue table reading `KokoroVoiceCatalogue.all` and per-row state from `KokoroModelStore`. Filter chips (language, gender). Per-voice Download / Installed-Remove button + Preview button (enabled only when base + voice are installed). Storage-location picker (same NSOpenPanel as f). Base-model row with its own Download / Remove. No "download all" affordance — every voice is opt-in per voice.

h. **Download manager.** Likely lands as `Voice/KokoroDownloadManager.swift` in `RPClientVoice` (since it has no Core consumers and writes ORT-relevant assets). One-shot URLSession download tasks per asset with progress reporting; concurrency cap of 2; cancellable mid-download. Computes SHA-256 on completion and calls `KokoroModelStore.recordModelDownloaded` / `recordVoiceDownloaded`. Pure-progress-tracking logic is testable with a stub URL session; URLSession glue is smoke-tested.

i. **Adapter.** New `Voice/KokoroSpeechSynthesizer.swift` in `RPClientVoice` conforming to `SpeechSynthesizing`. On `speak(_:)`: synthesises PCM frames via ONNX Runtime, streams into an `AVAudioEngine` player node. On `stopSpeaking()`: cancels the synth task and flushes the player. Falls back to `AVSpeechSynthesizerAdapter` when the base model isn't `.ready`. **Highest-risk sub-step** — see Risks / open for the .pt-parsing + g2p tokenization questions; expect this to surface design choices that ripple back to the plan.

j. **Wiring.** `AppState` (or wherever the §7.0 `Speaker` is constructed) picks the adapter based on `KokoroModelStore.baseModelState()`. No change to the `SpeechSynthesizing` protocol; no change to `Speaker`'s call sites. `Settings.voiceEnabled` toggle drives initial adapter selection; mount/unmount notifications on `KokoroModelStore` swap the adapter live.

k. **Voice identifier namespacing.** §7.2's `voiceIdentifier` is stored as `engine:voice-id` (e.g. `kokoro:af_bella`, `avkit:com.apple.voice.premium.en-US.Ava`) so swapping engines later doesn't invalidate stored prefs. §7.5's voice picker is sourced from the catalogue, filtered to currently-installed voices.

l. **Smoke test.** `./build.sh && ./run.sh`, toggle Speak replies on (triggers first-run prompt → pick the external SSD), download base model + one voice, send a message, confirm Kokoro output is materially better than the §7.0 AVKit baseline.

**Risks / open:**

- **Download UX.** No progress UI today in Settings — this is the first long-running side-task in that surface, and the multi-row catalogue makes it a *parallel* download manager (user can hit "Download" on three voices at once). Cap concurrency at 2 to avoid thrashing the user's bandwidth.
- **Catalogue currency.** The Swift-literal `KokoroVoiceCatalogue.all` goes stale when upstream adds voices. Acceptable trade-off vs. fetching a remote catalogue (which would mean a hardcoded URL with its own decay risk). Bump the literal in lockstep with Kokoro version bumps.
- **.pt parsing on the Swift side.** HuggingFace ships per-voice files as PyTorch `.pt` tensor archives (pickle format). For ONNX inference we need the speaker style embedding as a flat float buffer. Either parse the pickle ourselves (~50 lines for a single-tensor case) or pre-process at download time. Decision deferred to 7.1g (adapter) — 7.1c–7.1f only need to know "the file exists at `<path>/voices/<id>.pt`."
- **Test coverage.** Pure logic is testable: catalogue parsing, manifest read/write, voice-id parsing, storage-path resolution, mount/unmount state transitions. The ONNX-driven synth, URLSession downloads, and `AVAudioEngine` glue are smoke-tested per the AppKit/side-effect exemption — flag honestly, don't fake unit tests for "did the audio play."
- **Binary size.** Static linkage of ONNX adds ~25 MB to the .app today (only referenced symbols pulled in); expect ~80 MB once sessions/tensors land in 7.1c. Acceptable for a local-first model-running app.
- ~~ONNX Runtime on Apple Silicon~~ — resolved in 7.1a: `microsoft/onnxruntime-swift-package-manager` 1.24.2 integrates cleanly via SwiftPM with no xcframework vendoring needed.

**Effort: 2–3 days.** Voice library UI is the long pole now (catalogue table + download manager + storage picker); the adapter itself is contained.

### 7.2 Data model

```swift
struct Entity {
    // existing fields...
    var voice: VoicePreference?    // nil → use chat default
}
struct VoicePreference: Codable, Equatable {
    var voiceIdentifier: String   // engine-specific voice id
    var rate: Float
    var pitch: Float
}
```

`voiceIdentifier` is engine-specific — the format depends on what §7.1 ships. AVKit uses `AVSpeechSynthesisVoice.identifier`; a Piper-based engine would use a model filename, etc. Consider whether to namespace it (`engine:voice-id`) so users don't have invalid prefs after an engine swap.

### 7.3 Speaker attribution

The hard part. Given a streamed assistant turn, decide which entity is speaking each line. Two strategies, both implemented; user picks per-chat:

- **Heuristic.** Match `^"…"` quoted lines to the most-recently mentioned entity in the surrounding text. Fall back to "narrator" voice (chat default).
- **Tagged.** Require the model output convention `Sage: "..."` (common in RP). Parse `^([A-Z][a-z]+):` against entity names + aliases.

### 7.4 TTS pipeline

Refactor `Speaker` to drive a queue rather than one utterance:

- Split turn text into segments tagged with speaker.
- Enqueue one utterance per segment with the matched voice.
- "Pause / resume" on chat focus changes.

The protocol seam may need a queue-aware shape (e.g. `func speak(_ segments: [(voiceId: String, text: String)])`) — design alongside §7.1's engine pick.

### 7.5 UI

- Entity edit sheet gains a Voice section: pick voice, sliders for rate/pitch, "Preview" button.
- Settings adds default narrator voice (chat-level fallback).

**Effort: ~2 days for §7.2–§7.5 once §7.1 lands.**

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

Phases 1, 2, and 3 are done. From a fresh context: start with **Phase 4 (V8 Multi-server)** — three days of work that unlocks remote KoboldCpp servers and stops the local-only assumption from leaking into UI affordances. Spec is in §5.

Earlier recommendations preserved for historical context: the original called for "start with Phase 1"; the 2026-05-04 update called for "start with Phase 3." Both are now superseded.
