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

The reason this matters: per [`V2_PLAN.md`](V2_PLAN.md) §8, the rest of the app needs a UI overhaul against this same language eventually. Phase 9's creator window is the **gold-standard reference implementation** that V2_UI_OVERHAUL.md will build on — so the application contract in §11 of the design language doc is binding here, not aspirational. Reviewers should be able to answer "why this gap?" with a token name (`lg`), not a pixel measurement.

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
| **Identity** | **Avatar** (image control, see §3.6), `name`, `nickname` (v3, marked), `tags` (token-pill input + autocomplete), `creator`, `characterVersion` |
| **Persona** | `description`, `personality`, `scenario` |
| **Greetings** | `firstMessage`, `alternateGreetings` (list editor, drag-reorder), `groupOnlyGreetings` (v3, marked) |
| **Examples** | `messageExample` |
| **System** | `systemPrompt`, `postHistoryInstructions`, **Depth prompt** (text + depth + role; see §3.4), `creatorNotes` |
| **Lorebook** | Read-only summary of imported `charBook`. Pointer: "Edit per-chat lore in the World Info pane." |
| **Advanced** | `source` (v3, marked), `creatorNotesMultilingual` (v3, marked), `extensions` raw JSON viewer (read-only) |

v3-only fields are tagged with a small "v3" pill so authors know they'll be dropped on a v2 export.

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

## 4. AI-assist

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

```
name           ←  (cold-start: tags[], or empty)
description    ←  name, tags
personality    ←  name, description
scenario       ←  name, description, personality
firstMessage   ←  name, description, personality, scenario
messageExample ←  name, description, personality
alternateGreetings ←  firstMessage, scenario, personality
systemPrompt   ←  name, description, personality
postHistoryInstructions ←  systemPrompt, scenario
depthPrompt    ←  scenario, systemPrompt
creatorNotes   ←  name, description, personality, scenario, tags
tags           ←  name, description, personality
nickname       ←  name
groupOnlyGreetings ←  firstMessage, name, description
```

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

### §5.3 — Creator window UI

- `CharacterCreatorWindowController` + tabbed layout.
- Field controls per §3.3.
- Bundled placeholder library at `Resources/CardCreatorExamples.json`.
- Tag autocomplete vocabulary at `Resources/CardTagVocabulary.json` — hand-curated ~150-entry common set per §3.3.
- Examples-tab "Restore example dialogue" affordance per §3.5 (conditional, opt-in legacy-squash splitter).
- Identity-tab avatar control per §3.6 (image picker + drag-drop, auto-resize via `Storage.normalizeAvatarData`, common formats).
- Advanced-tab read-only `extensions` JSON viewer per §3.7.
- Save → `AppState.characters` + Library refresh. Save handles all three origin modes per §3.1 (`.created` / `.editing` / `.importing`).
- Menu items: `File → New Character…`, `File → Import & Edit Card…`, `Library → New Card…`, `Library → Edit Card…` (enabled when a Library card is selected).
- Library window "+ New Card" button.
- Edit-existing path: right-click a Library card → "Edit Card…".
- Import-and-edit path: file picker (`File → Import & Edit Card…`) and drag-drop a `.png` / `.json` onto the creator window. Preserve the existing sidebar drag-drop import-and-save fast path unchanged.
- Tests: `DraftOrigin` save-path semantics — `.created` mints UUID + writes avatar; `.editing` preserves UUID + skips avatar write unless changed; `.importing` mints UUID + writes import's avatarPNG. Pure tests with a stub `Storage`.
- Smoke-tested. UI sub-step — flag honestly per the TDD memory rule. Pure unit tests cover the draft-flush logic + the placeholder-rotation seed + the legacy-squash detection predicate; the AppKit layer is smoke-tested against a sample card.
- ~3–4 days.

### §5.4 — AI-assist field generation

- `CardFieldGenerator` — owns the dependency graph, the prompts, the side-call dispatch, the candidate parser.
- Suggestions strip per §4.1 wired into each multi-line field control.
- Per-window server picker per §3.1 + `Settings.cardCreatorServerId` persistence.
- Refusal detection per §4.5.
- Diagnostic logging per §4.6 — from commit one.
- Tests:
  - Dependency graph: per-field upstream list, stale-on-edit propagation, no false-positive cycles.
  - Candidate parser: refusal detection (5+ refusal-shaped fixtures), length-ratio heuristic, sanitization markers.
  - Stub `KoboldGenerating` returning canned candidates + scripted refusals; verifies strip state machine end-to-end.
- Smoke against a real NSFW server (user's normal chat-gen server).
- ~2–3 days.

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
- **Card-bound lorebook editing.** Phase 1's `WorldInfoPane` covers per-chat lore; card-bound editing is a follow-up that pairs with v3 decorator support in `WorldInfoEntry`.
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
