# RPClient V2 — Detailed plan

Forward plan for the V2 surface area listed in [`PLAN.md`](PLAN.md) §10. The MVP and the Memory V2 subsystem (Steps A–D, see [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md)) shipped 2026-05-03. This doc plans everything outside the memory subsystem; memory polish is deferred per the user's directive and tracked in [`NEXT_STAGES.md`](NEXT_STAGES.md) §A.

**Status as of 2026-05-04.** Phase 1 (V5 Lorebook UI) shipped 2026-05-04. Phase 2 (V1 Swipes) shipped 2026-05-04, including the stale-variant detection follow-up not in the original spec. Phase 3 is next.

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
| V10 | Avatars / image rendering | NEXT_STAGES C3 | Not started |

The chat-view UI overhaul (NEXT_STAGES §E) is **not** in this plan — it's a polish track and is sequenced separately.

---

## 1. Sequencing

The order below is the recommended path. Each phase ends with a shippable, runnable binary; later phases depend on earlier ones only where called out.

```
┌─────────────────────────────────────────────────────────────────┐
│  Phase 1   V5 Lorebook UI            ✅ shipped 2026-05-04      │
│  Phase 2   V1 Swipes                 ✅ shipped 2026-05-04      │
│  Phase 3   V3 Character cards + V4 Personas  ← next             │
│  Phase 4   V8 Multi-server                                      │
│  Phase 5   V10 Avatars                (small; unlocks V3 polish)│
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

**Status (2026-05-04):** steps 1–3 shipped on `v2-plan` (commits `dd102db` → `50da4ab`). Step 4 (prompt-builder integration) is the remaining work and is what makes imported cards actually drive the model. Importer also gained loose v1 / Pygmalion JSON acceptance as a follow-up (commit `c941baf`).

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

### 4.4 Prompt-builder integration ⏳ next (step 4 — not yet shipped)

When `Chat.characterId != nil`, on first turn:

- Inject `character.systemPrompt` (if present) at the top of memory block — overrides chat memory.
- `description + personality + scenario` becomes a permanent prefix to the memory block (uneditable in Memory pane; shown read-only with a "from card" badge).
- `firstMessage` appears as the initial assistant turn (auto-inserted on chat creation; user can swipe to `alternateGreetings`).
- `postHistoryInstructions` injects as / replaces author's note.
- `charBook` entries merge into chat-level world info, prefixed with `[from card]` so the user can tell.

Persona injection: on Gemma, the persona description folds into the first user turn alongside memory. On Qwen, into the system block. Format:

```
<You are {persona.name}>
{persona.description}
```

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

## 5. Phase 4 — V8 Multi-server

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

[`KoboldClient`](Sources/RPClientCore/KoboldClient.swift) becomes per-instance, owned by a registry:

```swift
final class KoboldClientRegistry {
    func client(for role: ServerRole, chatOverride: UUID?) -> KoboldClient
}
```

- Generation calls → `chat.serverId` ?? `settings.defaultServerId`.
- Side-calls (summarize, extract, embed) → role-specific override ?? default.

This unblocks "small fast model for chat, beefy model for memory side-calls" — a clear quality win once it lands.

### 5.3 Settings UI

New Servers tab in [`SettingsWindowController`](Sources/RPClientCore/UI/SettingsWindowController.swift):

- Server list: name, base URL, last-probed model, status dot.
- Per-server: edit name/URL, "Test connection" button (probes `/api/v1/model` + `/api/extra/version`), delete (blocked if it's the default).
- Role assignment: dropdowns for Default / Summarizer / Extractor / Embeddings.
- "Add server" → free-text URL.

### 5.4 Per-chat picker

In the chat header (next to template + sampler picker): server dropdown showing "Use default" or a specific profile. Persists to `Chat.serverId`.

### 5.5 Files touched

- `Models/Settings.swift` (rewrite)
- `Models/Chat.swift` (add `serverId`)
- `KoboldClient.swift` (per-instance refactor) + new `KoboldClientRegistry.swift`
- All call sites of `KoboldClient.shared` (or equivalent) — likely [`PromptBuilder`](Sources/RPClientCore/PromptBuilder.swift), [`Memory/Summarizer`](Sources/RPClientCore/Memory/Summarizer.swift), [`Memory/FactExtractor`](Sources/RPClientCore/Memory/FactExtractor.swift), embeddings code if any.
- `UI/SettingsWindowController.swift` (Servers tab)
- `UI/ChatViewController.swift` (per-chat picker in header)

### 5.6 Risks / open

- **Side-call routing must not regress today's behaviour.** Default everything to the same server initially; only switch when the user opts in.
- **Capability probing latency.** Cache probe results on `ServerProfile.capabilities` with a TTL; re-probe on demand.
- **Sampler / template incompatibility across servers.** Different servers may run different models. Per-chat already pins template + sampler — nothing extra to do, but warn if the chat's template doesn't match the server's reported model family.

**Effort: 3 days.**

---

## 6. Phase 5 — V10 Avatars / image rendering

Avatars (per-character, per-persona, per-entity) drop in cleanly on top of Phase 3.

### 6.1 Sidebar avatars

[`SidebarViewController`](Sources/RPClientCore/UI/SidebarViewController.swift): each chat row gains a 32px avatar from `chat.characterId`'s character avatar, falling back to a glyph.

### 6.2 In-turn avatars

On the chat view, assistant turns show the character avatar at top-left (matches Open WebUI styling — pairs naturally with NEXT_STAGES §E1).

### 6.3 Inline images in turns (defer)

Markdown `![alt](path)` rendering. Out of scope for this phase; opens questions about copy-to-clipboard, drag-out, sandboxing. Punt to a later cosmetic pass.

**Effort: 1 day for sidebar + chat-view avatars (without inline image rendering).**

---

## 7. Phase 6 — V6 Per-character voices

Depends on the Entity store from Memory V2 Step C.

### 7.1 Data model

```swift
struct Entity {
    // existing fields...
    var voice: VoicePreference?    // nil → use chat default
}
struct VoicePreference: Codable, Equatable {
    var voiceIdentifier: String   // AVSpeechSynthesisVoice.identifier
    var rate: Float
    var pitch: Float
}
```

### 7.2 Speaker attribution

The hard part. Given a streamed assistant turn, decide which entity is speaking each line. Two strategies, both implemented; user picks per-chat:

- **Heuristic.** Match `^"…"` quoted lines to the most-recently mentioned entity in the surrounding text. Fall back to "narrator" voice (chat default).
- **Tagged.** Require the model output convention `Sage: "..."` (common in RP). Parse `^([A-Z][a-z]+):` against entity names + aliases.

### 7.3 TTS pipeline

Existing [`Voice/Speaker.swift`](Sources/RPClientCore/Voice/Speaker.swift) currently speaks the whole turn in one voice. Refactor:

- Split turn text into segments tagged with speaker.
- Queue an `AVSpeechUtterance` per segment with the matched voice.
- "Pause / resume" on chat focus changes.

### 7.4 UI

- Entity edit sheet gains a Voice section: pick voice, sliders for rate/pitch, "Preview" button.
- Settings adds default narrator voice (chat-level fallback).

**Effort: 2 days.**

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

### 10.5 What this plan does **not** do

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
| 3 | V3 Character cards + V4 Personas | 3-4 days | 9 |
| 4 | V8 Multi-server | 3 days | 12 |
| 5 | V10 Avatars (sidebar + turn) | 1 day | 13 |
| 6 | V6 Per-character voices | 2 days | 15 |
| 7 | V2 Full branching | 1 day design + 1 week+ build | ~21 |
| 8 | V9 Group chats | 1 day design + 1-2 weeks build | ~29+ |

Phases 1–6 together (~15 days of focused work) ship every V2 item except branching and group chats. Phases 7–8 are best treated as separate efforts with their own design rounds.

---

## 12. Recommended next move

Phases 1 and 2 are done. From a fresh context: start with **Phase 3 (V3 character cards + V4 personas)** — it's the next-biggest user-visible win and pairs cleanly because cards typically include both an AI-character payload and a recommended user persona. Spec is in §4.

The original recommendation was "start with Phase 1" — preserved for historical context but no longer applicable.
