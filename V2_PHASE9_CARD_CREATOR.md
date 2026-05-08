# RPClient V2 Phase 9 — Card creator + AI-assisted field population design doc

**Status: draft, awaiting sign-off.** See [`V2_PLAN.md`](V2_PLAN.md) §5 for the parent plan entry and the five settle-before-coding decisions this doc expands on.

## Why

Today RPClient *consumes* character cards (Phase 3 importer) but cannot author or edit them. Users either edit JSON by hand, drop into another app to build a card and import the result, or hand-edit the on-disk `.json` files RPClient saves under `~/Library/Application Support/RPClient/characters/`. Even *editing* an imported card — fixing a typo in `description`, adding an `alternateGreeting`, tweaking `system_prompt` — currently requires leaving the app. Authoring + editing is the missing half of the V3 / V4 work.

Phase 9 ships a unified **Character Creator** window that handles three flows in one surface: **create from scratch**, **edit an existing card** from the Library, or **import a PNG/JSON and refine before saving**. Every card field is exposed alongside bundled placeholder examples. An **AI-assist** path lets the model propose 2–3 candidates per field and re-condition downstream candidates as upstream fields are edited. The author retains full control: AI-assist drafts, never decides.

The use case is heavily NSFW. The design intentionally surfaces the fields and conventions NSFW authors actually rely on (`post_history_instructions`, depth-prompt extensions, kink tags, content-rating creator notes) rather than treating them as advanced corners.

Half the work has prior art to lean on: ST v2 import is shipped, the v2 spec is well-documented, and v3 is a straightforward delta. The novel surface is the **AI-assist re-conditioning graph** — when does a downstream field's candidate strip go stale, and what does it consume to regenerate? — and the **server-routing + refusal-detection** plumbing that has to keep up with NSFW-shaped output.

## 1. Scope

**In scope (sub-steps §5.1 → §5.5):**

- Prior-art research + this design doc (§5.1).
- `Character` model expansion: first-class `messageExample`, `creatorNotes`, opt-in v3 fields (`nickname`, `groupOnlyGreetings`, `source`, `creatorNotesMultilingual`, `creationDate`, `modificationDate`), and an `extensions` passthrough blob for round-trip preservation of unknown keys (§5.2).
- `CharacterCardImporter` updates (populate the new fields; preserve unknowns; restore `mes_example` first-class on v1) (§5.2).
- New `CharacterCardExporter`: write v2 PNG by default; write v3 (`ccv3` + backfilled `chara`) opt-in. PNG-chunk *writer* added to `PNGTextChunks` (§5.2).
- Round-trip tests on synthetic fixtures shaped after real-world cards, including NSFW-shaped fixtures (§5.2 / §5.5).
- Character Creator window (`NSWindowController`, tabbed layout, save → `AppState.characters`) — unified surface for **create from scratch**, **edit existing Library card**, and **import-and-edit** (PNG/JSON → editable draft, save commits) (§5.3).
- Avatar / display-image control on the Identity tab — file picker + drag-drop, common formats (PNG / JPEG / WebP / HEIC / GIF / BMP), auto-resize via existing `Storage.normalizeAvatarData` (longest side capped at 512px) (§3.6).
- Per-field "Suggestions" strip — 2–3 candidates per field, lazy-on-focus, stale-on-upstream-edit, refresh on demand (§5.4).
- Side-call routing through a per-window server picker (default: current chat's server; persists in `Settings.cardCreatorServerId`); refusal-detection in the candidate parser; diagnostic logging from commit one (§5.4).
- Bundled placeholder example library (per-field, NSFW-realistic shape), surfaced as greyed-out hint text on empty fields (§5.3).
- Smoke pass: real-world card round-trips, multi-field chained generation (§5.5).

**Out of scope (this phase):**

- **In-window image cropping or AI portrait generation.** §3.6 ships a basic Choose image… / Drag-drop / Remove control routed through the existing `Storage.normalizeAvatarData` (auto-resize, no crop). Crop UI inside the creator stays out — authors crop in their image editor before drop-in. AI-generated portraits also stay out — Phase 9 is text-side only on the AI-assist surface.
- **Lorebook (`character_book`) editing in the creator.** Phase 1's `WorldInfoPane` handles per-chat lore; the importer pulls `character_book` into chat-level `worldInfo`. Card-bound lorebook *editing* inside the creator is a follow-up. The creator displays the imported book read-only with a pointer to the existing pane.
- **`assets[]` (v3).** Multi-portrait + emotion-set authoring is a meaningful UI surface in its own right. Round-trip preservation only — the importer reads `assets[]` into `extensions["rpclient/assets_passthrough"]` so v3 cards re-export cleanly without losing them, but the creator UI does not edit them.
- **CHARX (`.charx`) format.** Read + write for `.charx` zip-archive bundles — the v3 spec's recommended format for cards-with-assets — is deferred. PNG remains primary; JSON remains secondary.
- **Multi-card pack import/export, marketplace integration, sharing.** Out of scope.
- **Live card preview** (render the card as the user edits). Optional polish; deferred.
- **Persona creator.** Phase 9 is character-side only. Phase 3 already has minimal persona editing in the Library window — extending that is a separate, smaller piece of work.
- **AI-assisted regeneration of *existing* cards.** The creator opens new cards. Editing an existing card uses the same window but skips the cold-start paths; AI-assist is identical (re-conditions on whatever fields are populated).

## 1.5 Prior art

Surveyed at the spec level (ST v2/v3) and the source-code level (RisuAI imports, KoboldAI Lite, Backyard archive). Three production format families matter; the rest are derivatives.

### Card formats

| Format | Year | Container | Spec | Use | Notes |
|---|---|---|---|---|---|
| TavernAI v1 / Pygmalion | 2022 | flat JSON or PNG `chara` chunk | informal | legacy ecosystem | flat `name/description/personality/scenario/first_mes/mes_example`. Pygmalion aliases (`char_name`, `char_persona`, `char_greeting`, `world_scenario`). No `system_prompt`, no lorebook, no extensions. |
| **SillyTavern v2** (`chara_card_v2`) | 2023 | PNG `chara` tEXt chunk (base64 JSON) or `.json` | [malfoyslastname/character-card-spec-v2](https://github.com/malfoyslastname/character-card-spec-v2) | dominant ecosystem | adds `system_prompt`, `post_history_instructions`, `alternate_greetings`, `creator_notes`, `tags`, `creator`, `character_version`, `character_book`, **`extensions`** passthrough. |
| **SillyTavern v3** (`chara_card_v3`) | 2024 | PNG `ccv3` tEXt chunk (utf-8 → base64), or `.charx` zip, or `.json` | [kwaroran/character-card-spec-v3](https://github.com/kwaroran/character-card-spec-v3) | growing | adds `assets[]`, `nickname`, `creator_notes_multilingual`, `source[]`, `group_only_greetings`, `creation_date`, `modification_date`. Lorebook gains regex keys, decorators (`@@depth`, `@@activate_only_after`, etc.). v2-readable backfill of `chara` chunk is recommended. |
| **KoboldAI Lite** | 2023 | `.json` or PNG `chara` chunk | informal; tracks ST v2 | first-party kobold.cpp UI | reads ST v1 / v2 cards directly. No format of its own — adopts ST. |
| **RisuAI** | 2023 | PNG v2 / v3, `.charx` v3 | uses ST v2/v3 | second-largest ecosystem | namespaces NSFW/UI extras under `extensions.risuai` (kinks, content rating, expressions, regex scripts). v3 spec author. |
| **Backyard.ai (BYAF)** | 2024 | `.byaf` zip + JSON Schema | [byaf](https://www.npmjs.com/package/byaf) | Backyard.ai users | own format. ZIP with root manifest + character + scenario manifests. Importable to ST via converter. **Out of import scope for v1** — round-trip needs schema work; users converting from Backyard go via existing PNG export. |
| **agnai** | 2023 | extends ST v2 | uses ST v2 | small | namespaces under `extensions["agnai/voice"]`, `extensions.agnai`. |
| **CharacterAI / NovelAI / AI-Dungeon** | various | proprietary | n/a | walled gardens | not card-shaped; users typically convert via [charactercardconverter.com](https://charactercardconverter.com/). Out of scope. |

### What we borrow

- **PNG `tEXt` chunk embedding (v2 + v3).** Already shipped in `PNGTextChunks.swift` (read). Phase 9 §5.2 adds the writer.
- **The `extensions` passthrough policy.** v2 + v3 both mandate that editors preserve unknown keys. RPClient's importer currently *drops* `extensions` — Phase 9 §5.2 adds a `Character.extensions: [String: JSONValue]?` round-trip slot.
- **v2's `creator_notes`.** Currently dropped on import. Phase 9 makes it first-class — also the natural home for content-rating / trigger-warning text on NSFW cards (community convention).
- **v3's `nickname`, `group_only_greetings`, `source`, `creator_notes_multilingual`.** All useful, none expensive. Stored optionally; v2 export drops them with a warning, v3 export writes them.
- **v3 lorebook decorators.** RPClient's `WorldInfoEntry` already has `injectionMode` (`.always` / `.keyword`) which roughly maps `@@activate` / default. Full decorator support (`@@depth`, `@@activate_only_after`, `@@reverse_depth`) is a `WorldInfoEntry` extension and slots in cleanly when card-bound lorebook editing lands as a follow-up. **§5.2 only round-trips decorators in the `extensions` blob; the engine doesn't honour them yet.**
- **The community `extensions["depth_prompt"]` convention.** Not in either spec text but widespread on chub.ai cards. RPClient round-trips it through `extensions` and exposes a first-class "Depth prompt" control in the creator window — see §3.4.

### What we explicitly do not do

- **CharacterAI scraping / proprietary import.** Out of scope. Users convert via existing third-party tools.
- **Backyard `.byaf` import.** Round-trip support needs the schema work and a ZIP reader. v1 ships PNG/JSON only.
- **Live card preview.** Deferred — optional polish.
- **AI-generated portraits.** Out of scope. Phase 9 reuses V10's avatar path.
- **Marketplace / publishing flow.** Out of scope.

### NSFW workflow notes

The dominant NSFW card ecosystem (chub.ai, Risu Realm, JanitorAI exports) leans on three conventions that are easy to miss if you only read the formal spec:

1. **`post_history_instructions` carries the "UJB" / jailbreak / explicit-permission text.** Spec text frames this as "instructions appended after history." The community uses it to inject permission-style framing ("respond in character, including explicit content where the scene calls for it") because models drift if this lands at system-prefix depth. RPClient currently imports the field but never surfaces it in any UI; Phase 9 makes it first-class with bundled NSFW-shaped placeholders.
2. **`extensions["depth_prompt"]` is load-bearing.** Standards-track equivalent is v3's `@@depth N` lorebook decorator, but the inline `depth_prompt` extension is what's actually on most NSFW cards from 2023–2025. Shape: `{ prompt: string, depth: number, role: "system" | "user" }`. The creator exposes this as a first-class "Depth prompt" control (§3.4); preserved verbatim through `extensions` for v2 round-trip; the doc recommends the v3 form for new cards but doesn't force migration.
3. **`creator_notes` is the trigger-warning / kink-list slot.** chub.ai cards uniformly put content rating, kink list, and author commentary here. AI-assist on `creator_notes` should be prompted to *summarize content flavor* rather than redact it.

Tags vocabulary: the creator's tag picker autocompletes from a curated bundled list including common NSFW tags (`nsfw`, `male`, `female`, `futa`, `dom`, `sub`, `monstergirl`, `mommy`, `tsundere`, etc.) so authors aren't fighting blank input. Hand-curated, not networked.

## 2. Data model

### 2.1 Schema additions to `Character`

```swift
struct Character: Codable, Equatable, Identifiable {
    // ----- existing (Phase 3) -----
    let id: UUID
    var name: String
    var description: String
    var personality: String
    var scenario: String
    var firstMessage: String
    var alternateGreetings: [String]
    var systemPrompt: String?
    var postHistoryInstructions: String?
    var tags: [String]
    var creator: String?
    var characterVersion: String?
    var charBook: [WorldInfoEntry]
    var created: Date

    // ----- Phase 9 §5.2 additions (v2-mappable) -----
    /// Restored as first-class. Currently squashed into `description` on v1
    /// import. Maps to `data.mes_example` on v2/v3 export. Spec field — kept
    /// out of `description` so round-trips don't accumulate the prefix.
    var messageExample: String

    /// v2 first-class field. Display-only — never reaches the prompt. NSFW
    /// authors use this for content-rating / trigger-warnings / kink list.
    var creatorNotes: String?

    /// v2 + v3 passthrough. Preserves unknown keys verbatim through
    /// import → save → export so round-trips don't lose data. Includes the
    /// community `depth_prompt` convention (surfaced as a first-class
    /// control in the creator UI but stored here for spec-compliance).
    /// Keys are app-namespaced per the spec ("agnai/voice", "risuai", etc.).
    var extensions: [String: JSONValue]?

    // ----- Phase 9 §5.2 additions (v3-only, opt-in) -----
    /// Replaces `{{char}}` if non-nil; `name` is the fallback. Useful for
    /// "the character is called Marin in-fiction but cards as Captain".
    var nickname: String?

    /// Greetings shown only in group chats. Applies on the cast-add path —
    /// when an entity joins a multi-cast chat, the seeded turn (if any) is
    /// drawn from this list rather than `firstMessage`.
    var groupOnlyGreetings: [String]

    /// Provenance — read-only on import, append-only on edit. URLs, IDs.
    var source: [String]

    /// Language-keyed creator notes. ISO 639-1 keys. `en` mirrors
    /// `creatorNotes`. Editor exposes a language picker.
    var creatorNotesMultilingual: [String: String]?

    /// Auto-managed by Storage on save. Unix timestamps.
    var creationDate: Date?
    var modificationDate: Date?
}
```

`JSONValue` is a small `Codable` sum that stands in for `Any` — Swift's encoder can't round-trip arbitrary JSON without a wrapper. Implementation: ~30 LOC, similar to libraries like `AnyCodable` but in-tree (no dep).

### 2.2 Migration

Additive `decodeIfPresent` only. Legacy `Character` records on disk are missing every Phase 9 field; defaults are empty / nil. No `schemaVersion` bump needed (per V2_PLAN §6.1 — first non-additive change earns the version hook, and this isn't it).

`mes_example` restoration: v1 import currently folds the field into `description` with an `Example dialogue:\n` prefix. After §5.2, v1 import populates `messageExample` directly and leaves `description` clean. **Existing on-disk Character JSONs already have the squashed shape** — we leave them alone (no automatic un-squashing) but flag in the importer the next time the original card is re-imported. Cosmetic; the prompt builder still includes both.

### 2.3 Importer changes

`CharacterCardImporter`:

- Map `data.mes_example` → `Character.messageExample` on v2 path. Drop the v1 `description` squash; populate `messageExample` directly.
- Map `data.creator_notes` → `Character.creatorNotes`.
- Capture `data.extensions` verbatim → `Character.extensions`. Unknown keys preserved.
- v3 path: detect `spec == "chara_card_v3"` (currently rejected via `unsupportedSpec`); map every v3-only field; preserve `assets[]` through `extensions["rpclient/assets_passthrough"]`.
- v3 PNG chunk lookup: prefer `ccv3`, fall back to `chara` per the v3 backfill convention.
- **Legacy v1 squash detection.** Pre-Phase-9 imports of v1 / Pygmalion cards folded `mes_example` into `description` with a literal `\n\nExample dialogue:\n` separator. On every import, scan the resulting `description` for that prefix and log a one-line warning (`importer: ⚠ legacy v1 squash detected; consider re-importing the original card to restore mes_example`). **Do not auto-split** — false-positive risk is real (authors write "Example dialogue:" naturally in prose). The creator window's Examples tab gets a conditional "Restore example dialogue" button (§3.5) that lets the author opt in to the split with the result visible before save.
- Update the stale doc-comment at the file head — it claims to reject v1 cards, but the code accepts them. Cosmetic, fold into the §5.2 commit.

### 2.4 Exporter (new)

`CharacterCardExporter` mirrors the importer's surface. Pure (returns `Data`), caller writes to disk.

```swift
enum CharacterCardExporter {
    enum Format { case v2, v3 }
    enum Container { case png(avatar: Data), json }

    static func export(_ c: Character, as format: Format,
                       container: Container) throws -> Data
}
```

- v2 PNG: assemble the `data` block, base64-encode JSON, write into a `chara` tEXt chunk on the avatar PNG. Preserves `extensions` passthrough; drops v3-only fields with a warning logged once per export.
- v3 PNG: assemble the v3 envelope, base64-encode utf-8 → `ccv3` chunk, **also** write a v2-shaped `chara` chunk for reader compat (per spec).
- JSON containers skip the PNG path — pure JSON output.

`PNGTextChunks` gains `writeTextChunks(into baseImage: Data, chunks: [TextChunk]) throws -> Data` — reuses the chunk-walker logic to insert before `IDAT`. ~60 LOC. Tested by round-tripping read → write → read.

### 2.5 RPClient-namespaced extensions

Per the spec, app-specific data goes under a namespaced `extensions` key. RPClient uses `extensions["rpclient"]: { ... }`:

| Sub-key | Type | Purpose |
|---|---|---|
| `rpclient.default_voice_id` | string | Preferred voice (engine:voice-id). Auto-applied to the stub `Entity` on `newChat(withCharacter:)` so card-bound voice survives import. |
| `rpclient.entity_aliases` | string[] | Alt names for attribution. Fed to the heuristic so "Marin" + "the Captain" both resolve to the same entity. |
| `rpclient.attribution_mode` | string | `"heuristic"` / `"tagged"`. Per-card recommended mode; the chat picks it up unless the user has explicitly overridden. |
| `rpclient.assets_passthrough` | object | v3 `assets[]` stored verbatim for round-trip. The creator UI does not edit these. |

These are *recommendations carried with the card*, not authoritative. RPClient honours them when binding a card to a chat; other clients ignore them. Preserved on round-trip.

## 3. Creator window

### 3.0 Design language alignment

The Card Creator is the first surface that fully applies the [`V2_DESIGN_LANGUAGE.md`](V2_DESIGN_LANGUAGE.md) system — typography scale, 8pt spacing tokens (`xs` / `sm` / `md` / `lg` / `xl`), semantic colors, SF Symbols 6, Liquid Glass material via `NSSplitViewController` for any sidebar-shaped sub-surface, motion budgets (180ms tab swap, 160ms suggestions-strip reveal). Every concrete spacing / typography / color reference in §3.1 onward uses tokens from that doc; magic numbers are bugs.

The reason this matters: per [`V2_PLAN.md`](V2_PLAN.md) §8, the rest of the app needs a UI overhaul against this same language eventually. Phase 9's creator window is the **gold-standard reference implementation** that V2_UI_OVERHAUL.md will build on — so the application contract in §12 of the design language doc is binding here, not aspirational. Reviewers should be able to answer "why this gap?" with a token name (`lg`), not a pixel measurement. The design language draws from Apple HIG (platform contract) AND non-Apple modern UX systems (Linear, Things 3, Notion, Vercel/Geist, Stripe, Raycast) per §11 — so "modern UX" here means the broader productivity-tool tradition, not just what Apple ships.

### 3.1 Window shape

`CharacterCreatorWindowController : NSWindowController`. Single window, tabbed via `NSTabView`. The unified create / edit / import-and-edit surface — the same window handles all three flows; only the seeding of the initial draft differs.

**Three modes** (all flow through `CharacterDraft`, the mutable working copy):

- **Create from scratch.** Opens with all fields empty. Window title: "New Character". Save creates a fresh `Character` (new `UUID`) and adds to `AppState.characters`. Entry points: `File → New Character…`, `Library → New Card…`, "+ New Card" button in the Library window.
- **Edit existing.** `init(editing: Character)` opens with fields populated from a saved card. Window title: character name. Save replaces the existing record (`id` preserved). Entry points: right-click a Library card → "Edit Card…", or `Library → Edit Card…` menu when a card is selected. Dirty drafts prompt to save on close.
- **Import and edit.** `init(importing: CharacterCardImporter.Result)` opens with fields populated from a freshly-imported PNG / JSON, but *without* the draft having been saved. Window title: imported character name + `(Unsaved import)`. The author edits / AI-assists / refines, then **Save** is the first time the card lands on disk — at that point a new `UUID` is minted, the avatar PNG (if any) is written, and `AppState.characters` is updated. Cancel discards the imported draft entirely; nothing is persisted. Entry points:
  - `File → Import & Edit Card…` → file picker → `CharacterCardImporter.importFile(at:)` → creator.
  - Drag a `.png` / `.json` onto the creator window's title bar / drop zone → same path.
  - Library window's existing drag-drop sidebar import path is **preserved as-is** (immediate save, no editing step) — it's the fast path. Import-and-edit is the new deliberate path.

The distinction between **Edit existing** and **Import and edit** matters for save semantics: Edit replaces; Import creates. Cancel on Edit leaves the on-disk record intact; Cancel on Import discards everything (the user explicitly opted into reviewing the import before committing).

State management: `CharacterDraft` — a mutable working copy of `Character` plus an `origin: DraftOrigin` enum (`.created` / `.editing(existingId: UUID)` / `.importing(avatarPNG: Data?)`) and a dirty flag. Save flushes the draft via `Storage.shared.saveCharacter(_:)`, writes the avatar PNG when origin is `.importing` and PNG is present, posts `charactersChanged` notification, closes the window. Cancel discards (with confirmation if dirty). Standard Cocoa save-on-close prompt.

**Replacing the draft mid-edit.** Dragging a second card onto a creator window with a dirty draft prompts: *"Replace current draft with imported card?"* — Replace / Keep / Cancel. Keep loads the import into a *new* creator window. Avoids accidentally clobbering 20 minutes of editing on a misplaced drop.

Top of window: **server picker** (`NSPopUpButton` listing `Settings.servers`) + **AI model name** (read-only label resolved via `ServerProbe`). Default selection: `chat.serverId` of the active chat, falling back to `Settings.defaultServerId`. Selection persists in `Settings.cardCreatorServerId` so the creator opens with the same choice next time. Tooltip: "AI-assist suggestions are generated against this server."

### 3.2 Tabs

| Tab | Fields |
|---|---|
| **Identity** | **Avatar** (image control, see §3.6), `name`, `nickname` (v3, marked), `tags` (token-pill + autocomplete + persistent custom-vocabulary, §3.8), `creator`, `characterVersion` |
| **Details** | Age, Pronouns, Species, Orientation (single-line), Appearance, Mood (multi-line). RPClient-structured, folded into `description` on save, see §3.9 |
| **Persona** | `description`, `personality`, `scenario` |
| **Intimacy** | Body, Sensitivities, Scent, Turn-ons, Kinks, Limits (all multi-line). RPClient-structured, folded into `description` on save, see §3.9 |
| **Greetings** | `firstMessage`, `alternateGreetings` (list editor, drag-reorder), `groupOnlyGreetings` (v3, marked) |
| **Examples** | `messageExample` |
| **System** | `systemPrompt`, `postHistoryInstructions`, **Depth prompt** (text + depth + role; see §3.4), `creatorNotes` |
| **Lorebook** | Read-only summary of imported `charBook`. Pointer: "Edit per-chat lore in the World Info pane." |
| **Advanced** | `source` (v3, marked), `creatorNotesMultilingual` (v3, marked), `extensions` raw JSON viewer (read-only) |

v3-only fields are tagged with a small "v3" pill so authors know they'll be dropped on a v2 export.

The **Details** and **Intimacy** tabs are RPClient-structured surfaces. Their fields are stored under `extensions["rpclient/details"]` and `extensions["rpclient/intimacy"]` for round-trip preservation, AND auto-rendered into a fenced block at the start of `description` on save so the prompt sees them without engine integration. Bidirectional: cards opened from other tools that already carry the fenced block in description get their values extracted into the form on load. See §3.9 for the marker shape and §4.2 for AI-assist conditioning on these fields.

### 3.3 Field controls

- Single-line: `name`, `nickname`, `creator`, `characterVersion` → `NSTextField`.
- Multi-line: `description`, `personality`, `scenario`, `firstMessage`, `messageExample`, `systemPrompt`, `postHistoryInstructions`, `creatorNotes` → `NSTextView` in `NSScrollView` with line numbering off, soft-wrap on, monospace optional.
- Tags: token-pill `NSTokenField` with a bundled autocomplete vocabulary (~150 entries, NSFW-aware — tight common set covering structural / genre / tone / dynamics / broad NSFW). Hand-curated; lives at `Resources/CardTagVocabulary.json`. Freeform input falls through — autocomplete is a convenience, not a gate. Long-tail tag-discovery is a deferred follow-up; see §6.
- `alternateGreetings` / `groupOnlyGreetings`: list editor — each item is a multi-line text view, drag to reorder, delete button per row, "+ Add greeting" footer.
- Bundled placeholder text appears greyed-out on empty fields, drawn from a static `Resources/CardCreatorExamples.json` (3–5 examples per field, deterministically rotated by day-of-year so the editor doesn't show the same one forever).

### 3.4 Depth prompt control

Surfaced first-class (System tab, below `postHistoryInstructions`):

- Text input — multiline.
- Depth: `NSStepper` (0–10, default 4).
- Role: `NSPopUpButton` (`system` / `user`, default `system`).

Stored in `extensions["depth_prompt"]` as `{ prompt: string, depth: number, role: string }` (community-convention shape). Empty `prompt` removes the key.

The **engine integration is out of scope for §5.2** — Phase 9 ships the field as a creator-window control + round-trip preservation; integrating it into `PromptBuilder`'s injection logic is a follow-up. The doc-comment on the field control says so. Authors building NSFW cards still benefit because the field round-trips cleanly to / from clients (ST, Risu) that *do* honour it.

### 3.5 Examples-tab "Restore example dialogue" affordance

Conditional UI on the Examples tab. Visible **only** when `messageExample.isEmpty` AND `description` contains the literal `\n\nExample dialogue:\n` separator that pre-Phase-9 v1 imports produced (§2.3). Layout:

```
[ Example dialogue                                          ]
[ <empty NSTextView>                                        ]
                                                            
ⓘ This card may have its example dialogue squashed into
  Description (legacy v1 import shape).  [ Restore ]  [ Dismiss ]
```

- **Restore:** splits `description` on the first occurrence of `\n\nExample dialogue:\n`. Everything before becomes the new `description`; everything after becomes `messageExample`. Result lands in the live draft — author sees the split before saving and can undo via standard text-undo (cmd-Z) on either field. Only triggers if the author saves; not destructive on click alone.
- **Dismiss:** hides the affordance for this draft session. Re-appears next time the card is opened (cheap; better than a persisted "ignored" flag).

Out of scope: auto-split on import, or a "find and split all my legacy cards" batch tool. Per-card opt-in only.

### 3.6 Identity-tab avatar control

The card's display image — used in the Library grid, sidebar chat rows, assistant turn glyphs (V10), and embedded into the PNG on v2/v3 export. Surfaced on the Identity tab as a left-column thumbnail, with name / nickname / tags / creator / version filling the right column.

**Layout.**

```
┌──────────────┐  Name        [_______________________________]
│              │  Nickname    [_______________________________]
│   <avatar>   │  Tags        [pill1] [pill2] [+______________]
│   128 × 128  │  Creator     [_______________________________]
│              │  Version     [_______________________________]
└──────────────┘
[ Choose image…  Remove ]
   PNG / JPEG / WebP / HEIC / GIF — auto-fit
```

- Thumbnail rendered at 128×128 (4× retina source pulled from the same `AvatarSource` resolver V10 already uses for the Library grid). Empty state: a generic placeholder glyph with caption *"No image set"*.
- **Choose image…** opens `NSOpenPanel` filtered to `[.png, .jpeg, .webp, .heic, .gif, .bmp]`.
- **Remove** clears the avatar (sets the draft's avatar slot to `nil`); on save, the on-disk avatar PNG is deleted via `Storage.shared.deleteAvatar(for:)`. Confirmation prompt only if the existing avatar is non-empty.
- Drag-drop an image file onto the thumbnail area replaces (same drop zone honours the §3.1 mid-edit Replace / Keep / Cancel prompt only for full *card* drops — image-only drops just replace the avatar without prompting since they're scoped).

**Format support + auto-resize.**

All input is funnelled through `Storage.normalizeAvatarData(_:)` (already shipped, [Storage.swift:209](Sources/RPClientCore/Storage.swift)). Behavior:

- Accepts any AppKit-decodable bytes (PNG, JPEG, WebP, HEIC, GIF static, BMP). Selection panel surfaces these explicitly so the picker doesn't accept non-images.
- Re-encodes to PNG.
- Caps longest side at `Storage.avatarMaxDimension` (512px); aspect ratio preserved (no crop, no stretch).
- Already-small images skip the re-encode pass.
- Returns `nil` for unreadable input → UI surfaces an error sheet ("Couldn't read that image") and leaves the existing avatar untouched.

No in-window cropping. The author crops in their image editor of choice before drop-in if they want a tighter framing; the creator centers + scales but doesn't offer a crop UI. Cropping inside the creator stays out of scope (§6).

**Save semantics by `DraftOrigin`** (per §3.1).

- `.created`: avatar slot starts empty. Save writes the avatar PNG via `Storage.shared.saveAvatar(_:for:)` only if non-nil.
- `.editing(existingId:)`: avatar slot pre-loaded from `Storage.shared.loadAvatar(id:)`. Save writes only if the avatar bytes changed (cheap byte-wise compare against the loaded baseline).
- `.importing(avatarPNG:)`: avatar slot pre-loaded from the importer's `avatarPNG` (the source PNG of an imported card already *is* the avatar — that's how ST cards work). Save writes via `saveAvatar(_:for:)`. The author can replace via Choose image… before saving.

**Round-trip on export.** When exporting back to v2/v3 PNG (§2.4), the saved avatar PNG is the container — the JSON envelope is base64-encoded into a `chara` / `ccv3` tEXt chunk on *that* image. If the avatar slot is empty at export time, the user gets prompted: *"This card has no image. Export as JSON instead?"* — Export-as-JSON / Cancel. Avoids producing a 1×1 placeholder PNG just to have something to embed metadata into.

### 3.7 Advanced-tab `extensions` viewer

Read-only pretty-printed JSON in an `NSTextView` (`isEditable = false`, monospace), wrapped in an `NSScrollView`. Displays the live `Character.extensions` blob — updates as the author edits other fields that write into it (depth_prompt control, RPClient namespace). Empty `extensions` shows a placeholder ("No extensions data on this card.") rather than `{}`.

Multi-megabyte blobs (RisuAI cards with embedded scripts / images / regex) are common; the viewer must not try to render them as a single layout pass. `NSTextView`'s default text-storage handles large content fine — confirm the scroll view is the layout boundary, not a fixed-height container.

Raw JSON *editing* is deliberately out of scope. Footgun. If a future need lands, it's a separate sub-step.

### 3.8 Persistent custom tag vocabulary

The Identity-tab `tags` token field autocompletes from a **union** of:

- The bundled hand-curated common-set (~140 entries, see V2_DESIGN_LANGUAGE §11 + §3.3).
- A user-accumulated custom list at `Settings.customTags: [String]` — additive Codable, like the rest of Settings.

When the author commits a token that isn't already in the union (case-insensitively), the token is appended to `Settings.customTags` and `AppState.shared.saveSettings(_:)` fires. Future sessions show that tag in autocomplete.

Out of scope for §5.3c: an "Edit tag list" UI for removing accumulated tags. The JSON file is editable on disk if needed; a Settings → Tags surface is a candidate for the future V2_UI_OVERHAUL pass.

Long-tail community-vocabulary discovery (network-fetched chub-style ~1000-entry list) remains deferred per §6 — the persistent custom list bridges the common case (authors who use a specific niche tag a few times per card) without committing to maintaining a churning third-party vocabulary.

### 3.9 RPClient-structured Details + Intimacy

Two tabs that surface NSFW-relevant structured data without the tedium of editing prose-shaped `description` text. Each tab's fields are independent — leaving a tab entirely empty produces no fenced block, so SFW or minimalist cards stay clean.

**Field layout.**

Details tab (between Identity and Persona):

| Field | Shape | Maps to fence key |
|---|---|---|
| Age | Single-line | `age` |
| Pronouns | Single-line | `pronouns` |
| Species | Single-line | `species` |
| Orientation | Single-line | `orientation` |
| Appearance | Multi-line — height, build, hair, eyes, skin, clothing | `appearance` |
| Mood | Multi-line — default emotional state, baseline temperament | `mood` |

Intimacy tab (between Persona and Greetings):

| Field | Shape | Maps to fence key |
|---|---|---|
| Build | Multi-line — overall shape, height, weight, body type, athleticism | `build` |
| Anatomy | Multi-line — explicit physical / sexual anatomy | `anatomy` |
| Markings | Multi-line — tattoos, scars, piercings, distinguishing features | `markings` |
| Sensitivities | Multi-line — where they're ticklish, what arouses | `sensitivities` |
| Scent | Multi-line — what they smell like | `scent` |
| Turn-ons | Multi-line — list-style, what arouses | `turn_ons` |
| Kinks | Multi-line — specific fetishes / preferences | `kinks` |
| Limits | Multi-line — hard nos, dislikes | `limits` |

The single-`body` shape was replaced by the `build` / `anatomy` / `markings` triad during §5.3c.2 smoke pass — splitting gives AI-assist (§5.4) narrower targets to draft and lets authors pick which axes matter for a given card. `CardIntimacy.fromJSONValue` and `parseIntimacy` migrate any legacy `body` key into `anatomy` so existing on-disk records repopulate without manual fixup.

Each field gets bundled NSFW-realistic placeholder examples (not graphic; example shape illustrates the expected register).

**On-disk shape.**

Source of truth: `extensions["rpclient/details"]` and `extensions["rpclient/intimacy"]` as JSONValue objects with the snake_case keys above. Empty / nil / whitespace-only fields are omitted from the object so the extensions blob stays clean.

```json
"extensions": {
  "rpclient/details": {
    "age": "28",
    "pronouns": "she/her",
    "species": "Human",
    "appearance": "tall, lean, copper braid…"
  },
  "rpclient/intimacy": {
    "build": "lean, runner's frame",
    "anatomy": "small chest, freckled shoulders, narrow hips",
    "markings": "dragon tattoo on left shoulder",
    "turn_ons": "praise, slow build",
    "limits": "nothing involving family roles"
  }
}
```

**Description-block rendering.**

On every save, the structured fields auto-render into a fenced text block at the start of `description`, so the prompt-builder (which already reads `description + personality + scenario` as the read-only memory prefix) sees them without engine integration:

```
[character_details]
age: 28
pronouns: she/her
species: Human
appearance: tall, lean, copper braid down her back
[/character_details]

[character_intimacy]
build: lean, runner's frame
anatomy: small chest, freckled shoulders, narrow hips
markings: dragon tattoo on left shoulder
turn_ons: praise, being read to, slow build
limits: nothing involving family roles
[/character_intimacy]

(rest of description, written by the author)
```

Marker shape rationale: `[character_details]…[/character_details]` — plain-text fence with a distinctive prefix, snake_case `key: value` lines, blank line after the closing fence to separate from prose. Distinctive enough to avoid prose collision; readable when the author glances at description; parseable by a small regex.

**Note on the alternative**: if `[character_details]` collisions surface in real cards (an author whose prose legitimately uses that exact section header), the fallback is HTML-namespace tags (`<rpclient:details>…</rpclient:details>`) — collision-proof but uglier in description. Documented here so future code knows the escape hatch.

**Bidirectional sync.**

- **On save.** Render the fenced blocks from form fields. Replace any existing blocks in description (matched by fence regex). If absent, prepend at the start of description with a blank line separator. Persist `extensions["rpclient/details"]` + `extensions["rpclient/intimacy"]` from the same form values. Both surfaces stay in sync.
- **On load.** Editor reads from extensions first. If extensions are missing but description contains a recognized fence, parse the fence values into the form (one-time extract on load — no auto-write back to extensions until the user saves). Handles cards from other clients or from manual prose edits.
- **Conflict resolution.** Extensions wins. Manual edits to the description-block content do not survive a save — the next save re-renders from form values and overwrites. If this becomes annoying, a "Re-import from description" button is a §5.3e polish candidate.

**v3 export interaction.** The `rpclient/*` extension keys are namespaced per the spec, so they round-trip through other v2/v3 readers as opaque blobs. Other tools that read the description see the fenced block as plain text — they don't break, they just see structured prose.

## 4. AI-assist

Phase 9's largest user-facing payoff. Three distinct modes that share a single backend (`CardFieldGenerator`, the prompt template registry, side-call routing, refusal detection, diagnostic logging) but expose different UX surfaces:

- **Mode 1 — Per-field suggestions.** The author drafts manually; per-field "Generate" produces 2–3 candidates the author picks / edits / skips. Reactive: changes upstream mark downstream candidates stale. The deliberate, fine-grained mode for authors who want to keep a tight grip on each field. **§4.1–§4.6 cover this mode end-to-end.**
- **Mode 2 — Multi-field fill.** Author has a partial card; clicks a single button (e.g., "Fill missing fields" or per-section "Fill this section") and the model proposes values for several fields together with shared context. Returns a structured proposal the author reviews and accepts per-field. The "I've done the hard part, finish the rest" mode. **§4.7.**
- **Mode 3 — Full-card autopilot.** Author types a single seed (a one-line description, or just a name + a few tags) and clicks "Generate full card". The model walks the full §4.4 dependency graph, generating every field in coordinated passes. Returns a complete proposal presented as a diff preview the author can accept-all, reject-all, or pick per-field before final save. The "I have a vibe; do the rest" mode — the most ambitious of the three and the biggest single-user win. **§4.8.**

The three modes share infrastructure but their UX postures diverge: Mode 1 is reactive and fine-grained, Mode 2 is opt-in batch, Mode 3 is single-click full-card. Each is independently shippable and the §5.4 staging treats them as separate sub-passes (§5.4.a / §5.4.b / §5.4.c) gated behind a §5.4.0 research pass. **The research pass is mandatory** — this is the sub-step where existing tools (chub.ai's create flow, RisuAI's chargen, sillytavern community add-ons) and prompting techniques (structured output via JSON mode / function calling / KoboldCPP grammars, sequential prompt chains, few-shot exemplars) get surveyed before a single line of generation code is written.

### 4.1 Suggestions strip

Each multi-line field gets a "Suggestions" strip below it. Three slots, lazy-loaded (no API call until the strip is opened). Shape:

```
[ Description                                                ]
[ <multi-line text view>                                     ]
[                                                            ]
─────
Suggestions ▼  [ Generate ]  [ Refresh ]                stale
  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐
  │ A drifter who…   │ │ Born in the…     │ │ Marin grew up…   │
  │ [Use] [Edit]     │ │ [Use] [Edit]     │ │ [Use] [Edit]     │
  └──────────────────┘ └──────────────────┘ └──────────────────┘
```

- **Closed by default.** Disclosure triangle expands the strip; once expanded, stays open for the session.
- **Generate** issues the side-call. Disabled until the strip is open.
- **Refresh** discards current candidates and re-issues. Same as Generate but explicit.
- **Use** copies the candidate into the field, replacing the current value.
- **Edit** opens a sheet with the candidate pre-filled in a larger text view; OK closes back into the field.
- **Stale badge** appears when an upstream field changed since the last generation. Clicking it shows which upstream field changed.

Single-line fields (`name`, `nickname`, tags) get a single-shot dropdown rather than a strip — same backend, simpler UI.

### 4.2 Re-conditioning graph

Direction of read: **node → list of upstream nodes whose change marks this node's strip stale.** This is *not* a generation-order DAG. Reactive: an upstream change does not auto-regenerate; it badges the strip and waits for an explicit Refresh.

**Tags are an explicit upstream for every narrative-shaped field**, not just transitively-via-description. Tags carry strong genre / tone / kink signals; the prompt template references them directly so a draft for `personality` with tags `monstergirl, fantasy, dom` reads differently from the same field with tags `human, modern, sub` even when description is identical.

```
name                ←  (cold-start: tags, or empty)
description         ←  name, tags
personality         ←  name, description, tags
scenario            ←  name, description, personality, tags
firstMessage        ←  name, description, personality, scenario, tags
messageExample      ←  name, description, personality, tags
alternateGreetings  ←  firstMessage, scenario, personality, tags
systemPrompt        ←  name, description, personality, tags
postHistoryInstructions ← systemPrompt, scenario
depthPrompt         ←  scenario, systemPrompt
creatorNotes        ←  name, description, personality, scenario, tags
nickname            ←  name
groupOnlyGreetings  ←  firstMessage, name, description, tags

# §3.9 RPClient-structured fields
details.age          ←  (cold-start; usually author-set)
details.pronouns     ←  (cold-start)
details.species      ←  tags
details.orientation  ←  tags, details.species
details.appearance   ←  name, tags, details.species, details.age
details.mood         ←  name, personality, tags
intimacy.build       ←  details.species, details.age, tags
intimacy.anatomy     ←  details.species, details.age, intimacy.build, tags
intimacy.markings    ←  intimacy.build, tags
intimacy.sensitivities ← intimacy.anatomy, tags
intimacy.scent       ←  details.species, intimacy.build, tags
intimacy.turn_ons    ←  personality, tags, intimacy.anatomy
intimacy.kinks       ←  tags, intimacy.turn_ons
intimacy.limits      ←  (cold-start; explicit author intent)
```

`limits` deliberately has no upstream — hard nos are an author intent statement, not a derived field. Generate on `limits` produces a generic starting list (the bundled placeholder) that the author edits; AI-assist doesn't try to infer limits from other fields because the cost of a wrong inference is high.

`tags ↔ description / personality` is a near-cycle. Resolved by a freshness rule: tags consume description/personality but only marks-stale on tag *removal*, not addition. Adding a tag does not mark description stale — that would loop authors who add a tag mid-write. Removing one does (because the implicit shape changed).

Cold-start (every upstream is empty):
- `name` accepts a sheet input — "Optional seed: tags, genre, vibe" — which falls into the prompt as additional context. Skippable (model spitballs from nothing).
- All other cold-start generations succeed against whatever the empty model produces; they're typically generic but acceptable as a starting point. The author's first edit re-conditions everything else immediately.

### 4.3 Candidate prompting

Each field's Generate call is a **triad shot**: three candidates with distinct stylistic constraints, not three blind samples at temperature ~0.7.

- **Candidate A — Literal.** Direct, plain, leans on the upstream fields verbatim. Low-temperature, low-creativity.
- **Candidate B — Creative.** Distinctive, surprising, leans into the genre signals from tags + scenario. Medium-high temperature.
- **Candidate C — Terse.** Shorter, punchier, scaffolding for the author to expand. Low temperature, length-capped.

Three samples blind at the same temperature produces near-duplicate strips at low temp and incoherent strips at high temp. The triad gives the author meaningfully different starting points. Per the user's "speed not of the essence" call, the side-call serialises the three completions rather than batching — clearer diagnostics, easier to retry just one slot.

Prompt template per field is in `Resources/CardGenPrompts.json` — keyed by `field × candidate-style`. The doc-comment in the file calls out the NSFW posture: prompts explicitly grant explicit-content licence at the system level so a server willing to comply will, and a server unwilling will refuse cleanly (caught by §4.5).

### 4.4 Side-call routing

- **Server.** Per-window picker (§3.1), persisted in `Settings.cardCreatorServerId`. Default: active chat's `serverId` falling back to `defaultServerId`. *Not* `.summarizer`.
- **Reasoning for not reusing `.summarizer`.** Phase 8 §4.4's director routes through `.summarizer` because it emits a single name; sanitization doesn't matter. Card-gen emits prose. If a user has a small SFW summarizer configured, NSFW card-gen against it will return refusals or sanitized output and the author won't know why their candidates are bland. Per-window picker defaulting to the chat-gen server avoids the silent regression.
- **Routing through `template.assemble`.** Same Phase 8 §4.4 lesson: Qwen3 will burn `maxLength` inside `<think>` if the assembly doesn't pre-fill an empty `<think></think>`. Use the active chat's template (or the server's detected template) so the model produces output instead of meditation.
- **Timeout.** 30s per candidate (more lenient than Phase 8's 5s — quality over latency). Cancel button in the UI for an in-flight strip generation.
- **Token cap.** Per-field, set in `CardGenPrompts.json`. `description` ~512, `firstMessage` ~768, `messageExample` ~512, etc. Hard cap; truncated output is shown with a "..." indicator.

### 4.5 Refusal detection

After each candidate returns, the parser scans for the canonical refusal shapes before applying. Detection rules (additive — first match wins):

1. Leading regex: `^(I('m|\s+am)\s+(sorry|unable|not\s+able)|I\s+can(not|'t)|As\s+an\s+AI|I\s+(must|should|won't))`.
2. Sanitization marker: presence of `[Content removed]`, `[Sanitized]`, `[I cannot generate]`, etc.
3. Length-ratio heuristic: candidate < 25% of expected length AND contains any apology word (`sorry`, `unable`, `cannot`, `inappropriate`).

On detection:
- Candidate is shown in the strip with a **warning chip** (yellow triangle, tooltip: "Looks like a refusal — try a different server").
- Diagnostic log captures the raw output: `cardgen: <field> ⚠ refusal | <truncated text>`.
- The "Use" button is still available — false positives exist; the author can override.
- After 3 consecutive refusals on the same field, an inline tip surfaces: "All candidates look like refusals. Switch the server picker at the top of the window." — non-modal.

Detection is not an attempt to bypass server policy. RPClient does not retry with adjusted prompts after a refusal; that's the author's job (switch server, edit prompt template, accept the limitation).

### 4.6 Diagnostic logging

Per the `feedback_diagnostic_logging` rule. Bake from commit one of §5.4. Format:

```
cardgen: open <fieldName> | server=<id> model=<name>
cardgen: gen <fieldName> [A|B|C] ← <upstream summary, 80c truncate>
cardgen: gen <fieldName> [A|B|C] → <N tokens> in <ms>ms
cardgen: gen <fieldName> [A|B|C] ⚠ refusal | <80c truncate>
cardgen: gen <fieldName> [A|B|C] ✗ <error>
cardgen: apply <fieldName> [A|B|C] | <80c truncate of applied text>
cardgen: stale <fieldName> ← <changedUpstream>
```

Grep-able prefix `cardgen:`. Every line carries the field name so a multi-field generation flow can be reconstructed from the log.

### 4.7 Mode 2 — Multi-field fill

The "I've done the hard part, finish the rest" surface. Author has a partial card (e.g., name + description + tags) and wants the model to propose values for the empty fields without going field-by-field.

**Entry points.**

- **"Fill missing fields"** button on the Identity tab — global; targets every empty multi-line field across Persona / Greetings / Examples / System / Details / Intimacy.
- **"Fill this section"** button at the top of each tab body — scoped; targets only the empty fields within that tab. Useful when the author wants the model to fill Intimacy without touching Persona.

**UX shape.**

1. Click triggers a side-call (or a chain of side-calls — see §4.7.1 below).
2. Progress indicator appears at the top of the affected tabs / window: *"Filling missing fields… 3 of 7"* with a Cancel button.
3. On completion, each filled field shows the generated value with a **"Proposed"** badge in the field label and a small accept/reject toggle. Until the author commits, the field's previous value (empty) is preserved as undo state.
4. Author reviews each filled field; clicks **Accept** to commit, **Reject** to clear, or just edits inline (which auto-accepts). Bulk **Accept all** / **Reject all** at the top.
5. Save commits accepted fields; rejected fields stay empty.

**§4.7.1 Implementation strategy — settled in §5.4.0 research pass (see [`V2_PHASE9_AI_ASSIST_RESEARCH.md`](V2_PHASE9_AI_ASSIST_RESEARCH.md) §2.2).** **Single-call structured output** wins: one `response_format: json_schema` strict-mode call against `/v1/chat/completions` populates every empty field in a single coherent pass. Empirically measured at ~5s for 5 prose fields against the user's stack. Sequential per-field is the fallback for servers that don't honor `response_format`; capability-probed at first use, cached for the session.

**Cost ceiling.** Mode 2 budgets at most one side-call per multi-line empty field unless the chosen strategy is single-call structured. Cancel button at every step. Diagnostic logging per §4.6 with a `cardgen: mode2` prefix.

### 4.8 Mode 3 — Full-card autopilot

The biggest UX win and the biggest design risk. Author provides a seed — one of:

- A one-line description (e.g., *"an aging archivist who keeps to themselves in a port town"*).
- A name plus a few tags (e.g., name = *"Mira Vance"*, tags = `nsfw, fantasy, courier, dom`).
- Just tags (cold-start; the model invents a name + everything else).

…and clicks **"Generate full card"**. The model walks the full §4.4 dependency graph in coordinated passes, populating every field. The author then reviews the proposal end-to-end via a diff preview before committing.

**Pass shape — confirmed in §5.4.0 (see [`V2_PHASE9_AI_ASSIST_RESEARCH.md`](V2_PHASE9_AI_ASSIST_RESEARCH.md) §3.5):**

1. **Identity pass** — name (if cold-start), nickname, age, pronouns, species, orientation. Single json_schema call, small string fields.
2. **Persona+Voice pass** — description, personality, scenario, first_message, alternate_greetings (array), mes_example. Single json_schema call. Empirically 4.82s for 5 prose fields on the user's stack with cross-field coherence preserved.
3. **Body+Intimacy pass** — details (appearance, mood) + intimacy (build, anatomy, markings, sensitivities, scent). Single json_schema call.
4. **Disposition pass** — turn_ons, kinks. `limits` deliberately gets a bundled-defaults treatment (per §4.4) — author intent, not inferred.
5. **System pass** — system_prompt, post_history_instructions. Single json_schema call; templated more than free-form (these are usage instructions, not character content).
6. **Notes pass** — creator_notes, depth_prompt. Single json_schema call, conditioned on everything above.

Total: 5–6 sequential json_schema calls against `/v1/chat/completions`. Each pass's accepted fields land in the next pass's user-message context — KV-cache reuse on the system+exemplar prefix amortises across passes. ~25–35s total against a fast local model; longer against a constrained server. **Cancel button is mandatory at every pass boundary.**

**Diff preview UX.**

After generation completes, the creator window shows a modal sheet (or replaces the tab content with a "Review" surface) listing every populated field. Each field row:

- Field label.
- Generated value (rendered same as the live field would be — multi-line text view, single-line input, etc.).
- Per-field **Accept** / **Reject** / **Re-roll** buttons.
- Diff highlight: green for new content, neutral for fields the author had pre-filled (the model preserved them).

Bulk actions at the top: **Accept all**, **Reject all**, **Re-roll all**. Once the author commits, the accepted values land in the form; rejected values revert to empty (or the author's pre-filled value); re-rolls fire a fresh single-field generation per §4.1.

**Refusal handling.** If a pass produces refusals (per §4.5), the entire generation is marked as having sanitized output and the author gets a banner: *"Some fields look like refusals. The model may not be willing to produce explicit content; switch the server picker at the top and re-roll those fields."* The non-refused fields still get accepted normally.

**Cold-start prompting.** With only tags (no name, no description), the model has to invent a coherent character. The system prompt for the Identity pass explicitly instructs invention with creative latitude; the Persona pass then uses the invented name + tags as anchor. Quality varies; this is the mode most exposed to the chosen model's creative writing strength.

**Cost / safety ceilings.** Mode 3 has a hard total side-call cap (default 10) and a hard total token cap (default 16k tokens emitted across the whole run). Exceeding either aborts with a banner. Diagnostic logging per §4.6 with a `cardgen: mode3` prefix.

### 4.9 Cost and budget management

Cross-mode infrastructure. The §5.4.0 research pass is expected to surface specific guidance here — these are the questions the research must answer:

- **Anthropic prompt caching** — applicable to RPClient? Most users run KoboldCPP-shaped local models which don't have Anthropic-style prompt caching, so this is mostly relevant if RPClient ever supports an Anthropic-compatible side-call backend. Document but don't prioritize.
- **KoboldCPP context reuse** — KoboldCPP keeps a KV cache between requests if the prompt prefix is stable. Sequential prompt chains benefit substantially if each call shares a prefix; parallel calls with diverging prefixes don't. The research pass needs to verify the cache-reuse behavior on the user's typical local server.
- **Per-mode token budgets.** Mode 1: ~512 tokens per candidate × 3 candidates × per-field. Mode 2: ~512 × N empty fields. Mode 3: hard cap 16k total. Configurable in `CardGenPrompts.json`.
- **Concurrency caps.** Side-calls during AI-assist must not block the chat-gen pipeline. The §4.4 server picker keeps card-gen on a different connection from `defaultServerId` when configured separately. If the same server, side-calls queue behind chat generation rather than racing.
- **Cancellation.** Every mode exposes a Cancel button. Cancellation is a `URLSession` task cancel; no in-flight tokens are wasted but already-emitted tokens are preserved (logged but discarded).

### 4.10 Diff/review UX (Mode 2 + Mode 3)

Modes 2 and 3 produce multi-field proposals that need a review surface before commit. UX precedent worth surveying in §5.4.0:

- **GitHub Copilot's accept/reject pattern** — single-keystroke accept (Tab), reject (Esc), inline ghost-text rendering. Works for line-shaped suggestions; less applicable to multi-field card proposals.
- **Cursor's diff preview** — side-by-side or inline diff, accept-all / reject-all / per-hunk. Closer to what we need but still single-document oriented.
- **Notion AI's "Done" / "Try again" / "Discard"** — three-button accept pattern after generation. Simple; a good baseline.
- **chub.ai's card-creation review flow** — what does it look like? Does it surface field-by-field accept, or accept-all-or-nothing? Open research question.

Lean (subject to research): **per-field accept toggle in-place** (Mode 2) + **field-list diff sheet** (Mode 3). Both share a `ProposalReviewController` that takes a `[FieldProposal]` and presents the right UI for the mode. Implementation candidate for §5.4.d.

## 5. Sub-step staging

Mirroring Phase 6 / 7 / 8's incremental shape. TDD — tests-first on the data-model + importer/exporter sub-steps; smoke-tested on the UI sub-steps.

### §5.1 — Research + design doc

This document. Output: `V2_PHASE9_CARD_CREATOR.md`. ~1 day. **In progress (this PR).**

### §5.2 — Card model expansion + importer/exporter round-trip

- Extend `Character` with the v2-mappable additions, then opt-in v3 fields.
- Add `JSONValue` Codable wrapper.
- `CharacterCardImporter`: handle `data.mes_example`, `data.creator_notes`, `data.extensions`; v3 path on `chara_card_v3`; backfill detection.
- New `CharacterCardExporter`: v2 PNG / v2 JSON / v3 PNG (with `chara` backfill) / v3 JSON.
- `PNGTextChunks.writeTextChunks(...)` writer.
- Round-trip tests in `CharacterCardRoundtripTests`:
  - v2 PNG import → v2 PNG export → re-import → equality on v2-mappable subset.
  - v2 JSON import → v2 JSON export → equality.
  - v3 PNG import → v3 PNG export → re-import → equality on full subset.
  - v3 PNG → v2 PNG → re-import → v3-only fields nil; v2 fields equal.
  - `extensions` round-trip: unknown sub-keys preserved.
  - NSFW-shaped fixture: depth_prompt + dense `mes_example` + long `system_prompt` + NSFW tags. Equality.
  - Real-world chub-shape fixture: synthetic, hand-crafted to match the on-disk shape of community NSFW cards.
- Update the stale doc-comment at the head of `CharacterCardImporter.swift`.
- ~1–2 days. Tests-first.

### §5.3 — Creator window UI ✅ shipped 2026-05-07

Sub-passes a–e mirrored Phase 6/7/8 incremental shape. Each independently smoke-tested; commits staged in this order:

- **§5.3a** ✅ Window scaffold + Identity tab. `CharacterCreatorWindowController` + tabbed layout, `DesignTokens` foundation, `CharacterDraft.DraftOrigin`, `AvatarControl` per §3.6, server picker, save / cancel + dirty dot, menu entry stub. Smoke regressions caught + fixed: dark-mode CGColor snapshot trap (new `AppearanceAwareLayerView`); hint text contrast (`subheadline` paired with `secondary`, not `tertiary`); Library cache routing through `AppStateCardStorage` adapter.
- **§5.3b** ✅ Persona / Greetings / Examples / System tabs. `MultilineFieldView` + `GreetingListEditor` reusable controls, `DepthPromptControl` per §3.4, conditional "Restore example dialogue" affordance per §3.5. NSScrollView-as-tab-root pattern fixed via wrapper-NSView (NSTabView's frame-set was being eaten by `translatesAutoresizingMaskIntoConstraints = false` on the scroll view). NSTextView canonical setup (minSize/maxSize/isVerticallyResizable/autoresizingMask) added to stop multi-line fields from intercepting clicks intended for sibling fields.
- **§5.3c.1** ✅ Persistent custom tags. `Settings.customTags: [String]` additive Codable. Token-commit on Identity-tab `tagsField` checks the union (bundled + custom) and appends-and-saves on novel input. Autocomplete queries the union. Edit-tag-list UI deferred to V2_UI_OVERHAUL per §3.8.
- **§5.3c.2** ✅ Details + Intimacy tabs. New `CardStructuredDetails.swift` carrying `CardDetails` / `CardIntimacy` Codable structs + `JSONValue` round-trip + fence render / parse helpers. Bundled NSFW-realistic placeholder examples for every multi-line field via new `PlaceholderTextView` (NSTextView subclass — AppKit doesn't ship a native multi-line placeholder). Save flow: `CharacterDraft.prepareForSave()` re-renders fences and writes both `extensions["rpclient/{details,intimacy}"]` and the description-block. Load flow: extract from fence-in-description if extensions absent (one-time, on draft init for `.editing` origin), eagerly mirror back into extensions so a save-without-edits doesn't strip the fence. Body field split into `build` / `anatomy` / `markings` triad mid-pass; legacy `body` key migrates to `anatomy` on `fromJSONValue` and on `parseIntimacy` so existing on-disk records repopulate.
- **§5.3c.3** ✅ Lorebook tab — read-only summary of imported `charBook`. Per-entry card with name, keys/secondary-keys summary, content preview (3 lines), mode pill (always / keyword / vector), priority readout in mono. Disabled entries fade to half opacity. Card-bound lorebook editing remains §6 out-of-scope; pointer copy directs the author to the inspector's World Info pane for per-chat lore.
- **§5.3c.4** ✅ Advanced tab + `extensions` JSON viewer per §3.7. New `StringListEditor` (single-line list, lighter sibling of `GreetingListEditor`) for v3 `source`. New `MultilingualNotesEditor` for v3 `creator_notes_multilingual` — 12-language popup (en/ja/ko/zh/de/fr/es/it/pt/ru/ar/hi from §3.9 common set), with non-common langs preserved on round-trip via fallback popup item. Read-only pretty-printed JSON viewer (`ExtensionsJSONViewer`) refreshes on `viewWillAppear` so cross-tab edits land visibly.
- **§5.3d** ✅ Library + menu entry points + drag-drop + import-and-edit flow. `+ New Card` and `Edit Card…` buttons on the Library window. Right-click context menu on Library cards (Edit / Start Chat / Delete) and on empty space (New / Import). Double-click → Edit. New `LibraryCollectionView` subclass routes both right-click and double-click via closures back to the controller. `File → Import & Edit Card…` opens the file picker → CharacterCardImporter → `CardCreatorWindowController(importing:)`. Creator window's root view is now a `CardDropView` accepting `.png` / `.json` drops; each drop spawns a new creator window so the original draft is preserved (in-place "Replace / Keep / Cancel" replacement deferred — §5.3 deferred polish).
- **§5.3e** ✅ Doc sweep, V2_PLAN status update, deferred-polish inventory, synthetic NSFW fixture for manual smoke.

**Deferred from §5.3 (queued, not in Phase 9 scope):**
- In-place draft replacement on drag-drop (§3.1 Replace / Keep / Cancel — §5.3d ships only "Keep" via new window).
- Per-row keyboard shortcuts in `GreetingListEditor` (⌘⌫ delete, option-up/down reorder).
- "Restore from description" button — pulls description-block content back into Details / Intimacy form fields if the author manually edited the fence (§5.3c.2 currently clobbers manual block edits on save).
- Edit-tag-list UI — the persistent custom-tag vocabulary accumulates indefinitely without a remove path; lives on V2_UI_OVERHAUL.
- `+ Add` / `+ Add language` keyboard shortcuts on Advanced-tab list editors.
- Hide-the-fence-block on the Description tab — currently the auto-folded `[character_details]` block is visible inside Description; cleaner UX would render it as a non-editable inline pill or hide it entirely, but that's NSTextView surgery best done in V2_UI_OVERHAUL.

Tests: `DraftOrigin` save-path semantics + `CardStructuredDetails` render/parse round-trip + persistent-tag union behavior — pure unit tests with stub `CardStorage`. 763/763 passing across all of Phase 9 §5.3. AppKit assemblage smoke-tested manually throughout sub-passes; synthetic NSFW fixture at `/tmp/rpclient-fixtures/sample_card.json` covers full round-trip exercising every tab.

Total effort: 2 days end-to-end including the body-split mid-pass + smoke regression rounds.

### §5.4 — AI-assist field generation

Three modes (per §4) staged behind a mandatory research pass. Each mode is independently shippable.

#### §5.4.0 — Research pass ✅ shipped 2026-05-07

**Output: [`V2_PHASE9_AI_ASSIST_RESEARCH.md`](V2_PHASE9_AI_ASSIST_RESEARCH.md)** at repo root. Survey + 11 live empirical probes against the user's configured server (KoboldCPP v1.111.2 + Qwen3.6-35B-A3B-Uncensored, 16k ctx). Decisions taken (full detail in research doc):

- **Mode 1** — free-form prose via `/api/v1/generate` + empty `<think></think>` pre-fill (existing DirectorPicker pattern).
- **Mode 2** — single-call `response_format: json_schema` strict mode via `/v1/chat/completions`. ~5s for 5 prose fields measured.
- **Mode 3** — per-pass json_schema, sequential across passes, 5–6 passes total, ~25–35s.
- **GBNF grammar dropped** — json_schema covers it via OpenAI-compat endpoint and is more reliable on the user's stack.
- **Few-shot exemplars** — three archetypes (Mira / monstergirl / sci-fi) selected by tag-overlap; new `CardGenExemplars.swift` lands in §5.4.a.
- **Diff/review** — per-field accept toggle (Mode 2) + diff sheet with per-field lock + history (Mode 3, Inktomi93-pattern).
- **NSFW posture** — existing license phrase confirmed correct; no jailbreak escalation.
- **Refusal detection** — model-family-specific patterns added; uncensored-model softening applied via name detection.
- **Concurrency** — strictly sequential within a single mode invocation; KV-cache reuse via byte-deterministic prompt builder.
- **Gemma scenario** — same `template.assemble` abstraction; json_schema reliability is the open smoke item.

All §5.4.0 topics covered: existing card-gen tools survey (Chub / bmen25124 / ewizza / cha1latte / Inktomi93 / sphiratrioth666), structured-output techniques (with 11 live probes, not just literature), prompt-chain + KV-cache reuse (measured warm vs. cold on the actual stack), few-shot conventions (3-archetype exemplar set), NSFW posture (current license phrase validated), diff/review UX precedent (Notion / Cursor / Inktomi93 distilled), cost/budget (KoboldCPP cache reuse + Anthropic forward-note), and refusal-detection failure modes (model-family patterns + uncensored-stack softening). See research doc for full detail and reproducible probe transcripts.

#### §5.4.a — Mode 1: Per-field suggestions

- `CardFieldGenerator` — owns the dependency graph, the prompts, the side-call dispatch, the candidate parser, the server-capability probe (json_schema support, cached per session), and the byte-deterministic prompt builder per research §3.2.
- `Resources/CardGenPrompts.json` — prompt template registry (per-field × per-candidate-style instructions, per-pass schemas for §5.4.b/c). Schema in research §11.
- `Sources/RPClientCore/UI/CardCreator/CardGenExemplars.swift` — three full-character archetypes (Mira / monstergirl / sci-fi) with every §4.4-graph field populated; tag-overlap selector per research §4.1. Distinct from `CardCreatorPlaceholders.swift` (which stays UI-only).
- Suggestions strip per §4.1 wired into each multi-line field control.
- Per-window server picker per §3.1 + `Settings.cardCreatorServerId` persistence (already shipped in §5.3a).
- Refusal detection per §4.5 + model-family patterns per research §8.3 + uncensored-model softening per §8.4.
- Diagnostic logging per §4.6 — from commit one.
- Tests:
  - Dependency graph: per-field upstream list, stale-on-edit propagation, no false-positive cycles.
  - Prompt-builder determinism: same inputs → byte-identical output (KV-cache reuse correctness).
  - Exemplar selection: tag-overlap → expected archetype with documented ties resolving to Mira.
  - Candidate parser: refusal detection (5+ refusal-shaped fixtures across Qwen/Llama/Mistral families + 5+ false-positive baits), length-ratio heuristic, sanitization markers.
  - Stub `KoboldGenerating` returning canned candidates + scripted refusals; verifies strip state machine end-to-end.
- Smoke against the user's measured stack (Qwen3.6-Uncensored on KoboldCPP).
- ~2–3 days.

#### §5.4.b — Mode 2: Multi-field fill

- `CardMultiFieldGenerator` — single-call `response_format: json_schema` strict mode via `/v1/chat/completions` per research §2.2.
- Server-capability probe: tiny json_schema test call on first use, cached per session; fall back to sequential per-field if structured returns garbage.
- "Fill missing fields" + "Fill this section" buttons per §4.7.
- Per-field "Proposed" badge UI + accept/reject toggle.
- Bulk Accept all / Reject all.
- Cancellation (URLSession task cancel; per research §7.5).
- Tests: stub generator producing canned multi-field proposals; per-field accept/reject state machine; cancellation mid-chain leaves consistent state; capability-probe fallback when stub server returns non-compliant JSON; `{{user}}` placeholder preservation across long-form description fields.
- ~2–3 days.

#### §5.4.c — Mode 3: Full-card autopilot

- "Generate full card" entry point on Identity tab (with seed input) or on a new top-bar action.
- `CardAutopilotOrchestrator` — pass orchestration per §4.8 (Identity → Persona+Voice → Body+Intimacy → Disposition → System → Notes), each pass a single json_schema call composed via `CardFieldGenerator`.
- Hard cost ceilings (10 side-calls, 16k tokens) with abort behavior.
- Diff preview surface — `ProposalReviewController` per §4.10 + research §6.2 (per-field lock, history of last 3 rolls per field, Inktomi93-pattern).
- Re-roll path delegates to §5.4.a's single-field generator; locked fields skipped on Re-roll all unlocked.
- Tests: pass orchestration with stub generator (verify pass order + cancellation); cost-cap enforcement; diff-preview state transitions; lock-preservation across re-rolls; history stack growth + revert.
- ~3–4 days.

#### §5.4.d — Polish, telemetry sweep, smoke

- Per-mode diagnostic-log review against a real chat-gen run.
- Cost/budget instrumentation surfaced (e.g., status bar of the creator window: "Mode 3: 4 of 7 passes, 2.3k tokens").
- Refusal-detection regression suite expanded based on what real models actually emit during smoke.
- Small UX polish from smoke: progress indicators, button-label refinement, banner copy.
- ~1 day.

**Total §5.4 effort:** ~1 day research + ~7–11 days implementation across the three modes. Each mode is independently shippable; if scope tightens we ship Mode 1 first and gate Mode 2 / Mode 3 behind a follow-up phase.

### §5.5 — Polish + smoke

- Multi-card flows (create A, edit A, create B referencing A's tags via autocomplete).
- Multi-field chained generation: cold-start name, accept, generate description, accept, generate personality… all the way through. Verify stale badges propagate correctly.
- Real-world card round-trips:
  - chub-shape NSFW PNG (synthetic fixture).
  - Risu v3 PNG with `risuai` extensions (synthetic fixture).
  - Pygmalion v1 JSON (synthetic fixture; verifies v1 path → `messageExample` first-class restoration).
  - SillyTavern v2 PNG with full `character_book` (synthetic fixture).
- Verify the Library list, sidebar binding, and `newChat(withCharacter:)` all keep working with the expanded `Character` shape.
- ~1 day.

**Total effort:** ~1 week of implementation gated behind §5.1 sign-off. Matches V2_PLAN §5 estimate.

## 6. Out of scope (recap, with rationale)

- **`assets[]` editing.** Multi-portrait + emotion-set authoring is its own UI surface. Round-trip preservation only.
- **CHARX (`.charx`) read/write.** PNG remains primary; JSON remains secondary. CHARX is the v3 spec's recommended format for cards-with-assets and lands when assets do.
- **Card-bound lorebook editing.** Phase 1's `WorldInfoPane` covers per-chat lore; card-bound editing is a follow-up that pairs with v3 decorator support in `WorldInfoEntry`. **Queued as a §5.4-adjacent slice** — when picked up, also wires AI-generation of lorebook entries (single-shot json_schema returning `{name, keys, content}`, then optionally a multi-entry "build me a lore set" pass). Prereq: a lorebook editor surface on the Lorebook tab (currently read-only per §5.3c.3).
- **Backyard `.byaf` import.** Different format family. Users convert via existing third-party tools.
- **Persona creator window.** Phase 9 is character-side only.
- **Live card preview.** Optional polish.
- **AI-assisted regeneration of *existing* cards.** The creator handles editing existing cards via the same UI; AI-assist re-conditions on whatever's populated. No special "regenerate this whole card" pass — that's just hitting Refresh on every field, and bundling it as a button is dangerous (one click obliterates a finished card).
- **Marketplace integration / publishing flow.** Out of scope.
- **Engine integration of v3 lorebook decorators.** §5.2 round-trips them through `extensions`; the engine doesn't honour them. Follow-up.
- **Engine integration of `extensions["depth_prompt"]`.** Same. Round-trip + UI control only.
- **Long-tail tag-discovery vocabulary.** §3.3 ships the tight ~150-entry common-set bundle. A long-tail / chub-style discovery list (1000+ niche kink + community tags) is deferred. Likely shape when picked up: pairs with a Library-side facet-browse / tag-filter feature; vocabulary may be network-fetched from a community-curated index rather than bundled (which would otherwise commit RPClient to keeping a churning list current). Not a Phase 9 problem.
- **Raw `extensions` JSON editing.** §3.7 is read-only. Edit-the-JSON-directly is a power-user footgun and a separate sub-step if it ever earns its keep.
- **Auto-un-squash of legacy v1 `mes_example` on import or batch-fix tool.** §3.5 ships the per-card opt-in affordance only. False-positive risk of an automatic split (authors write "Example dialogue:" in prose) makes silent migration the wrong call.

## 7. Cross-cutting

### 7.1 Schema versioning

All Phase 9 changes are additive `decodeIfPresent`. No `Settings.schemaVersion` bump. Per V2_PLAN §6.1.

### 7.2 Migration testing

Per V2_PLAN §6.2 — `Phase9MigrationTests` (or fold into `CharacterCardRoundtripTests` if the migration surface stays small). Standing convention.

### 7.3 Sandbox forward-note

Card export writes to user-chosen paths (NSSavePanel). Sandbox compatibility unchanged; no security-scoped bookmark work needed.

### 7.4 What this plan does NOT do

- Touch the existing `WorldInfoEntry` engine integration. v3 decorators round-trip through `extensions` only.
- Touch `PromptBuilder`. Card-bound `depth_prompt` injection is engine work and a follow-up.
- Touch the Library window beyond the "+ New Card" / "Edit Card…" entry points and the post-save refresh notification.
- Touch the Avatar pipeline. The creator reuses V10's existing avatar resolver.

## 8. Testing strategy

- **Unit (TDD).**
  - `CharacterCardImporter` — every existing test continues passing; new tests cover `mes_example` first-class, `creator_notes` import, `extensions` preservation, v3 detection, v3 backfill detection.
  - `CharacterCardExporter` — every format × container combination, including the v3-to-v2 export warning path.
  - `PNGTextChunks.writeTextChunks` — chunk insert before `IDAT`, multiple chunks, idempotent rewrite.
  - `JSONValue` — round-trip through `JSONEncoder` / `JSONDecoder` for primitives, arrays, objects, nested.
  - `CardFieldGenerator` — dependency graph (per-field upstreams, stale propagation, no false cycles), candidate parser (refusal shapes, length-ratio), side-call dispatch (server resolution, timeout, error paths).
- **Integration.**
  - Round-trip fixtures in `Tests/CardRoundtripFixtures/` covering v1 / v2 / v3 / v3-with-risuai-extensions / NSFW-chub-shape. Hand-crafted (synthetic), shaped after real-world cards. No copyrighted content.
  - Stub `KoboldGenerating` for the AI-assist tests — scripted candidate responses including refusals.
- **Smoke (UI sub-steps).**
  - §5.3: open creator, fill every field, save, verify Library list updates and `newChat(withCharacter:)` loads the saved card.
  - §5.4: open creator, generate per-field candidates against real chat-gen server, accept, edit, verify stale propagation, verify refusal detection against a deliberately small SFW server.
  - §5.5: real-world card import → save → re-export → re-import on the synthetic fixtures.

## 9. Resolved questions (signed off in kickoff)

- **Tag vocabulary scope** → hand-curated ~150-entry common set (§3.3). Long-tail discovery is a deferred follow-up, may be network-fetched (§6).
- **Legacy v1 `mes_example` squash recovery** → no auto-fix (false-positive risk on prose containing "Example dialogue:"). Importer logs a warning when the prefix is detected (§2.3); the creator's Examples tab gets a conditional opt-in "Restore example dialogue" button (§3.5).
- **Advanced-tab `extensions` viewer** → ship in §5.3 as a read-only pretty-printed JSON viewer (§3.7). Diagnostic value during §5.4 testing earns the inclusion now rather than later.

## 10. References

- ST v2 spec: [malfoyslastname/character-card-spec-v2](https://github.com/malfoyslastname/character-card-spec-v2/blob/main/spec_v2.md).
- ST v3 spec: [kwaroran/character-card-spec-v3](https://github.com/kwaroran/character-card-spec-v3/blob/main/SPEC_V3.md).
- BYAF format: [npm byaf](https://www.npmjs.com/package/byaf).
- RisuAI character formats: [DeepWiki](https://deepwiki.com/kwaroran/RisuAI/3.1-character-cards).
- [`V2_PLAN.md`](V2_PLAN.md) §5 — Phase 9 plan entry.
- [`V2_PHASE7_FULL_BRANCHING.md`](V2_PHASE7_FULL_BRANCHING.md) — design-doc shape precedent.
- [`V2_PHASE8_GROUP_CHATS.md`](V2_PHASE8_GROUP_CHATS.md) — design-doc shape precedent + side-call routing precedent (§4.4).
- [`Sources/RPClientCore/Models/Character.swift`](Sources/RPClientCore/Models/Character.swift) — current shape.
- [`Sources/RPClientCore/Importers/CharacterCardImporter.swift`](Sources/RPClientCore/Importers/CharacterCardImporter.swift) — current importer.
- [`Sources/RPClientCore/Importers/PNGTextChunks.swift`](Sources/RPClientCore/Importers/PNGTextChunks.swift) — current chunk reader.
- [`Sources/RPClientCore/AppState.swift`](Sources/RPClientCore/AppState.swift) — `newChat(withCharacter:)`, `ensureCharacterEntity(_:)` lifecycle entry points.
