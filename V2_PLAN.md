# RPClient V2 — Plan

Forward plan for the V2 surface area listed in [`PLAN.md`](PLAN.md) §10. The MVP and the Memory V2 subsystem (Steps A–D, see [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md)) shipped 2026-05-03. This doc covers everything outside the memory subsystem; memory polish is deferred per the user's directive and tracked in [`NEXT_STAGES.md`](NEXT_STAGES.md) §A.

**Status snapshot (2026-05-06).** Phases 1–8 shipped on `v2-plan` (V5 Lorebook, V1 Swipes, V3 Cards + V4 Personas, V8 Multi-server, V10 Avatars, V6 Per-character voices, V2 Full branching, V9 Group chats). Phase 8 also shipped its deferred polish (cast reorder, convert-to-solo) plus a voice-attribution carry-forward improvement and a per-turn replay-audio button. **Phase 7's optional §3.6 (variant-collapse) is deferred indefinitely** — variants and branches are conceptually distinct but functionally fine; collapsing is a pure refactor with no user-visible payoff and a non-trivial migration. **Phase 9 §5.1 design doc shipped 2026-05-06** ([`V2_PHASE9_CARD_CREATOR.md`](V2_PHASE9_CARD_CREATOR.md)); §5.2 (model expansion + importer/exporter round-trip) is next. 644/644 tests pass; pushed to origin at 8aebfa0. The heuristic-refinement research item (§7) remains queued.

---

## 1. V2 inventory + status

| # | V2 item | Status | Pointer |
|---|---|---|---|
| V1 | Swipes (alt continuations) | ✅ shipped 2026-05-04 | §2.2 — commits `764b41f` → `54fca62` |
| V2 | Branching (turn tree) | ✅ shipped 2026-05-06 (§3.1–§3.5; optional §3.6 deferred indefinitely) | §3 + [`V2_PHASE7_FULL_BRANCHING.md`](V2_PHASE7_FULL_BRANCHING.md) |
| V3 | SillyTavern v2 character cards | ✅ shipped 2026-05-04 | §2.3 — commits `dd102db` → `342791c` |
| V4 | Personas (user side) | ✅ shipped 2026-05-04 | §2.3 (paired with V3) |
| V5 | Lorebook editor UI | ✅ shipped 2026-05-04 | §2.1 — commits `076f548` → `dacb4fc` |
| V6 | Per-character voices | ✅ shipped 2026-05-05 | §2.6 (~30 commits, see git log) |
| V8 | Multi-server | ✅ shipped 2026-05-05 | §2.4 (sub-steps 4a–4f) |
| V9 | Group chats | ✅ shipped 2026-05-06 (§4.1–§4.5 + deferred polish) | §4 + [`V2_PHASE8_GROUP_CHATS.md`](V2_PHASE8_GROUP_CHATS.md) |
| V10 | Avatars / image rendering | ✅ shipped 2026-05-05 (sidebar + assistant turn; inline images deferred) | §2.5 — commits `f6d9192` → `897747a` |
| V11 | Card creator (full-feature, AI-assisted) | ⏳ next | §5 |

The chat-view UI overhaul (NEXT_STAGES §E) is **not** in this plan — it's a polish track sequenced separately.

---

## 2. Shipped phases

One paragraph per phase. Captures the design decisions and load-bearing notes that future work will reference; sub-step delivery prose lives in commit messages.

### 2.1 Phase 1 — V5 Lorebook editor UI ✅ 2026-05-04

`WorldInfoEntry` data model existed unread before this phase; Phase 1 closed the loop. Extended the entry shape (`name`, `enabled`, `injectionMode`, `matchScope`, `priority`, `secondaryKeys`), added `WorldInfoInjector` (word-boundary case-insensitive matching, AND-gating on secondary keys, priority sort + token-budget truncation), wired into `PromptBuilder` above the rolling summary, and added a `WorldInfoPane` to the inspector mirroring `EntitiesPane`. Status-bar token chip shows the World segment alongside Memory. Migration: legacy entries default `name = keys.first ?? "Untitled"`, `enabled = true`, `mode = .keyword`, `scope = .recentTurns(4)`. Vector-mode injection deliberately deferred — that's a Memory-V3 feature.

### 2.2 Phase 2 — V1 Swipes ✅ 2026-05-04

`Turn.variants: [TurnVariant]` extends `Turn` non-breakingly; `Turn.text` mirrors the active variant for legacy readers (PromptBuilder, retrieval, downgraded saves) so nothing else needs to know variants exist. Migration synthesises one variant from legacy `text` on decode. Generation: send → variant 0; swipe-right → new variant generated; regen → appends rather than overwrites (destructive regen retired). UI footer on assistant turns shows `◀ N/M ▶` only when `variants.count > 1`. **Stale-variant detection** (follow-up, `54fca62`): each variant records a `contextFingerprint` (FNV-1a of prefix turns' id/role/text) at gen time; `Chat.isVariantStale(turnIndex:variantIndex:)` recomputes and compares, UI badges with `⚠`, per-variant discard button prunes. Memory/summary deliberately excluded from the fingerprint — only turn-text edits / reorders / variant-swaps mark stale.

### 2.3 Phase 3 — V3 Character cards + V4 Personas ✅ 2026-05-04

Shipped together because cards bundle both the AI character and a recommended user persona. New `Character` and `Persona` models; `Chat` gains `characterId`, `personaId`. Storage at `~/Library/Application Support/RPClient/{characters,personas}/<uuid>.json` plus per-id PNG avatars. `CharacterCardImporter` accepts ST card v2 (PNG with embedded JSON in the `chara` tEXt chunk, base64-encoded), v1 (Pygmalion-aliased included; degrades `mes_example` into `description`), and explicit `chara_card_v1`. PNG chunks parsed in ~80 LOC — no dependency. Library window (Cmd-Shift-L) lists characters/personas as avatar grids; sidebar `+` is a pull-down for "+ New chat" / "+ New chat with character…". Drag-drop PNG/JSON onto the sidebar lands directly. Prompt-builder integration shipped as 4a–4g sub-steps: `Chat.systemPromptMode` (override/merge, default override) controls whether card `system_prompt` replaces or layers on chat memory; `firstMessage` seeds turn 0 with `alternateGreetings` as swipeable variants; `postHistoryInstructions` synthesises an author's note when the user hasn't set one (user wins); card `character_book` entries merge into chat world-info name-prefixed `[from card]` (idempotent — re-runs are no-ops, user edits to merged entries survive); persona renders as `<You are NAME>\nDESCRIPTION` per-template (Qwen folds into system, Gemma folds into first user turn). `MemoryPane` shows a read-only "From card" section + the per-chat override/merge picker. **Avatars are derived-by-id, not stored as `avatarPath`** — V2_PLAN's original snippet was stale, no migration required. Persona token soft-cap at ~200 tokens warns to `DebugLog` on overflow.

### 2.4 Phase 4 — V8 Multi-server ✅ 2026-05-05

Replaced `Settings.serverURL: String` with `[ServerProfile]` + `defaultServerId` + per-role overrides (summarizer / extractor / embeddings). Migration wraps the legacy URL in a single profile named "Default". `KoboldClientRegistry` caches one client per profile; routing is `chat.serverId ?? settings.defaultServerId` for generation, `settings.<role>ServerId ?? settings.defaultServerId` for side-calls. `AppState.kobold` stays as a façade pointing at the current chat's generation client so existing callers don't need rewriting. **Side-call routing carved out `KoboldGenerating` + `KoboldEmbedding` protocols** so the engine's two side-calls can target different clients (and so the routing is testable). `RetrievalEngine` grew an injectable `storesDir` for the routing test. Settings UI Servers section: profile rows (name + URL + Test + status dot + delete), four role-assignment popups, "+ Add server", short-timeout `ServerProbe` of `/api/v1/model` + `/api/extra/version` + `/api/extra/true_max_context_length`. Per-chat picker in the chat header. `side-call:` log line at every dispatch point so misrouting is visible without inspecting network traffic. **Punted to follow-up:** sampler/template incompatibility warning between chat and the resolved server's reported model family — needs UX thinking (where does it surface? on chat open? on send?). Capability probing is lazy-on-demand only, not on app launch.

### 2.5 Phase 5 — V10 Avatars ✅ 2026-05-05

Sidebar gets a 32px circular avatar from `chat.characterId`'s character avatar; assistant turns get the same in `TurnView` (replacing the `✦` glyph; placeholder kept for character-less chats). `AvatarSource` is the id → `NSImage` resolver with library-changed cache invalidation. **Deferred:** persona avatars on user turns (right-aligned bubbles have no glyph column — defer to chat-view styling pass NEXT_STAGES §E); entity avatars in turns/sidebar (defer until V6 lands the speaker indicator they'd pair with — voices shipped without one, so this is still pending); inline image rendering (`![alt](path)` — out of scope; opens questions about clipboard/drag-out/sandboxing). Avatar size is fixed-32 in the chat surfaces (matches library cards' fixed-96, both already ignore `uiFontOffset`); revisit only if the fixed size feels wrong against an extreme font offset.

### 2.6 Phase 6 — V6 Per-character voices ✅ 2026-05-05

Largest phase to date — shipped as ~30 commits across §7.1 (engine swap), §7.2 (data model), §7.3 (attribution), §7.4 (TTS pipeline), §7.5 (UI). Headline shape:

- **Engine.** Kokoro 82M (ONNX, ~325 MB base + 523 KB per voice from HuggingFace) chosen over AVKit Premium / Piper / Coqui XTTS / cloud APIs — Apache-2.0, local-first, multilingual (9 languages, 54 voices), quality-competitive with commercial cloud TTS. AVKit stays as the fallback when the base model is missing. **Nothing voice-related lives in the .app bundle** — model + voices download to a user-configurable `voiceModelPath` (auto-detected non-system volumes surfaced as one-click options at first-run). `KokoroModelStore` re-validates on launch + mount/unmount notifications; volume-unavailable falls back cleanly to AVKit. **G2P:** subprocess to system `espeak-ng` (one-time `brew install`) — Kokoro was trained on espeak/misaki phonemes so anything else degrades quality, and GPL-3 stays out of our binary. **.pt parsing:** direct ZIP read of the single `data/0` tensor entry — no pickle parser, no pre-processing at download.
- **Two-tier toggle.** `Settings.voiceEnabled` (subsystem gate, in Settings) + `Settings.voiceActive` (runtime mute, speaker icon in chat header). Both must be true to synth. Subsystem off deinits Kokoro (~80 MB); runtime mute keeps it warm.
- **Voice library window** (separate window, not a Settings tab — 54 rows don't belong inline). Per-voice Download/Cancel/Remove via `KokoroDownloadManager` (concurrency cap 2, streamed SHA-256 verification, atomic move). Filter chips for language/gender. Base model must be downloaded before any voice download is enabled.
- **Two-tier voice fallback.** `Entity.voice ?? Chat.voice ?? Settings.defaultVoice`. `VoiceIdentifier` is `<engine>:<voice-id>` so preferences survive engine swaps. `VoicePreference.rate/pitch` are 1.0-centred multipliers shared across both engines (range validated at the UI/engine boundary, not the decoder, so an out-of-range hand-edited value still loads).
- **Per-character attribution.** `SpeakerAttribution.split` splits a turn into `[AttributedSegment]`. Two modes: **Heuristic** (walks quote boundaries, attributes each `"…"` to the entity whose name/alias appears latest in preceding text) and **Tagged** (line-prefixed `Name:` against entity names + aliases, case-insensitive, multi-word). Per-chat via `Chat.attributionMode` (default heuristic, additive Codable migration). Heuristic includes polish for first-person `I` short-circuit (resolves to character-card entity), dialogue-verb subject detection, lookback scoping at paragraph + 200 chars, lenient first-person resolver. Tag stays in spoken text — natural for either listening or reading along.
- **Pipeline.** `SpeechSynthesizing.speak(_:options:completion:)` carries the per-call voice. AVKit adapter implements `AVSpeechSynthesizerDelegate` for per-utterance completion (handlers keyed by `ObjectIdentifier(utterance)`). Kokoro adapter ties speech-level completion to the last chunk's playback completion via `FireOnce`. `Speaker` holds both engines simultaneously and dispatches by `options.voice?.engine`; nil voice prefers Kokoro. `speakSegments` groups consecutive same-engine segments into a single `speakBatch` so engines that pipeline (AVKit native, Kokoro via override) get cross-segment cadence. Monotonic queue generation discards stale completions if `stop()` was called between segments.
- **UI.** Entity card Voice row (picker + rate/pitch sliders + Preview button); chat-header Voice picker + Attribution picker + speaker mute; Settings default narrator picker. All four `NSPopUpButton` surfaces share `VoicePopupBuilder` (stable selection semantics: sectioned Kokoro/AVKit options, sentinel for nil, "Stored (unavailable)" preserves uninstalled selections). Preview button uses `Speaker.preview(voice:)` which honours the subsystem gate but bypasses the runtime mute (explicit user action). Sample text is a per-language pangram for Kokoro, English fallback for AVKit.

**Known gaps / future work:**

- **Audio trimming between chunks.** Kokoro emits ~50–100 ms of trailing silence per chunk; concatenation accumulates noticeable gaps on multi-chunk replies. Upstream `kokoro-onnx` Python uses `trim_audio` per chunk. Add a Swift RMS-windowed silence trim before scheduling each PCM buffer. Cosmetic.
- **Question lilt.** Kokoro produces flat prosody for `?`. Not fixable without retraining; documented limitation.
- **Multi-voice resolver in selector.** `KokoroSpeechSelector` knows about a single global voice; per-character routing currently flows through `Speaker` directly. The selector wiring could be extended for stricter consistency, but the runtime path works.
- **Heuristic refinement.** The §7.3 polish was tuned against a small handful of one-off chat snippets. Deferred as a research item — see §6.

---

## 3. Phase 7 — V2 Full branching ✅ shipped 2026-05-06 (§3.1–§3.5; optional §3.6 deferred indefinitely)

Treat as its own design doc — the data-model swap is small but the `turnIndex: Int` → `turnId: UUID` migration through the memory subsystem (`SceneSummary`, `Chunker`, `VectorStore`, `RetrievalEngine`, `MemoryManager`) is the bulk of the work. Plan author's earlier warning still applies: not picking this up casually.

**Settle-before-coding decisions** (recommendations agreed in conversation 2026-05-05):

1. **Storage — flat with `parentId` + explicit `activePath: [UUID]`.** `Chat.turns: [Turn]` stays; each `Turn` gains `parentId: UUID?`. `Chat.activePath: [UUID]` (root → leaf) is persisted; renderable list is `activePath.compactMap { turnsById[$0] }`. Easier to render, diff, and persist than a true tree; migration of existing `[Turn]` is mechanical (each turn's parent = previous turn, `activePath = turns.map(\.id)`).
2. **Variants vs branches — keep variants for now; collapse later.** Phase 7 ships with `Turn.variants` intact. Branching adds parent/child between Turns; swipes stay within a Turn. Collapsing variants → first-class branch siblings (the conceptually-clean answer the original plan hints at) is a bigger migration with re-bound ◀ ▶ semantics — lands as an optional later sub-step once the branching model is proven.
3. **Memory subsystem — `turnIndex: Int` → `turnId: UUID` (load-bearing).** `SceneSummary.firstTurn/lastTurn: Int?` → `firstTurnId/lastTurnId: UUID?`. Same for `MemoryChunk.firstTurnIdx/lastTurnIdx`. `RetrievalEngine`'s "within N turns of the end" recency math translates to active-path positions resolved at query time. Invasive (~5 files), but unavoidable — without it, switching branch invalidates every scene summary and every retrieval cache. Migration: legacy `Int?` indices map to `activePath[idx]` (the spine tree gives an unambiguous mapping).
4. **Regen semantics — fork is always sibling-add, never destructive.** Regen on the trailing assistant turn → appends a variant (today's behaviour, preserved). Regen on a non-trailing turn → forks a new child Turn off the parent, switches `activePath` to the new branch. Chat-storage-on-disk grows monotonically — branches don't get GC'd automatically; add a "prune dead branches" action later.
5. **UI — gutter indicator + Branches sidebar pane (list); visual minimap added in §3.5.** Per-turn gutter glyph (▷) when the turn has siblings, click to switch. Cmd-B = fork from current. Branches inspector pane lists every branch with first-line preview. Visual minimap (graph view) follows the list view as §3.5 — chat trees are small enough that a custom AppKit layered layout is feasible (~200 LOC), with Open WebUI's `Overview/Flow.svelte` as the reference for the visual + interaction language.

**Sub-step staging** (mirroring Phase 6's incremental shape):

- **§3.1** — Data model: `parentId` + `activePath`, migration of existing chats to a spine tree. No UI change. Tests-first; ~1 day. **Shipped 2026-05-06** (TDD; 21 new tests in `ChatBranchingTests`; lazy spine-migration in `Chat.init(from:)` covers both legacy on-disk chats and the in-memory round-trip case; cycle detection + connected-path + single-root validation throws `DecodingError` on bad shapes; `switchBranch(to:)` drills to deepest descendant via `activeChildId` per Open WebUI's pattern. 498/498 green.)
- **§3.2** — Memory subsystem: `turnIndex` → `turnId` through `SceneSummary`, `Chunker`, `VectorStore`, `RetrievalEngine`, `MemoryManager`. Migration tests. ~2-3 days. *Load-bearing; ugly.* **Shipped 2026-05-06** in four sub-passes (§3.2.A SceneSummary 2426c7b → §3.2.B Chunk + Chunker + VectorStore 2f3aee0 → §3.2.C RetrievalEngine.excludePredicate(chat:) → §3.2.D summarizedThrough clamp on switchBranch). Both legacy Int APIs and new UUID APIs coexist during the transition window. Original spec to derive `summarizedThrough` from `sceneSummaries.last.lastTurnId` revised: doesn't capture between-scene-break advancement; clamping on branch switch is the working compromise. Per-branch rolling summary (`chat.summary` per leaf) flagged as separate future refactor. 525/525 green.
- **§3.3** — Fork-on-regen for non-trailing turns. Sibling glyph in the gutter. Cmd-B action. ~1-2 days. **Shipped 2026-05-06** in two passes (§3.3a `Chat.appendTurn` maintains `parentId` + `activePath` across all production turn-mutation sites; §3.3b `Chat.fork` + `AppState.forkFrom` + `AppState.switchBranch` + gutter glyph + sibling popover + Cmd-B menu item, plus the necessary fan-out: rebuild iterates `activeTurns`, `isVariantStale(turnId:)` uses active-path prefix, stream/think handlers target the active leaf instead of `turns.last`). 536/536 green.
- **§3.4** — Branches sidebar pane (list view). ~1 day. **Shipped 2026-05-06.** New `BranchesPane` inspector tab (between World and Suggestions); pure `Chat.leaves` + `Chat.divergencePoint(of:against:)` helpers cover the row generation and "forked at TN" subtitles. Empty-state copy when there's only one leaf so a linear chat doesn't earn the pane's real estate. New `chatTreeChanged` notification posted from `forkFrom` / `switchBranch` / turn-delete so the pane (and future minimap) redraws on shape changes without subscribing to the noisier `chatUpdated`. 7 new pure tests; 543/543 green.
- **§3.5** — Visual tree minimap (custom AppKit layered layout, Open WebUI as reference). ~3-4 days. **Shipped 2026-05-06.** Pure `MinimapLayout` layered top-down algorithm (depth × rowHeight on Y; in-order leaf walk × colWidth on X with internal nodes centered over their children). 8 new pure tests cover empty / single / linear / fork / nested-fork / determinism / activeEdges. New `TreePane` inspector tab renders boxes-and-edges in `NSView.draw(_:)` with active-path edges thickened in accent and the active leaf solid-filled. Click a node → `AppState.switchBranch(to:)`. Trackpad pan + magnify supported via `NSScrollView.allowsMagnification`; "Fit" button rescales to viewport. Empty-state copy when the chat is linear (≤ 1 leaf) so the pane doesn't show a useless single column. 551/551 green.
- **§3.6** (optional, deferred-by-default) — Collapse variants into branches.

§3.1 + §3.2 are the unglamorous half — most of the risk lives there. §3.3 onward is where users see value. Full design — schema, migration strategy, per-sub-step contracts, decisions taken, prior-art survey (SillyTavern, KoboldAI, Open WebUI, LibreChat, Loom, plus academic refs) — lands in [`V2_PHASE7_FULL_BRANCHING.md`](V2_PHASE7_FULL_BRANCHING.md).

**Effort: ~10 days implementation after design doc.**

---

## 4. Phase 8 — V9 Group chats ✅ shipped 2026-05-06

The largest open item, and the natural follow-on to branching (group-chat retries are a tree-shaped operation). Multiple AI characters share one chat, each with their own card / persona / system prompt / voice / avatar. Turns are tagged by speaker; the user steers who speaks next or lets the system decide.

**Settle-before-coding decisions** (drafted, sign off in the kickoff session before §4.1 starts):

1. **Speaker selection.** Three plausible models — *round-robin*, *user-picks-each-turn*, *director-LLM-picks*. Lean: ship round-robin as the default with a per-chat override + a "let the model decide" toggle that swaps in the director path. Director adds N+1 generations per user turn (one to pick speaker, one to speak), which is fine for small models / fast servers and painful otherwise — make it opt-in.
2. **Per-speaker prompt assembly.** When character A generates, do B's prior turns appear as `assistant` (chat history) or `user` (input from outside)? Both have failure modes; `assistant` is more honest about the conversation shape, `user` keeps each character's voice cleaner. Lean: `assistant` with the speaker name prepended in-text (`Sarah: ...`); A/B test against `user` per model if quality regresses.
3. **Memory routing.** Each speaker has their own `system_prompt` (from their card) + their own scene summaries (per-speaker, since "what Sarah remembers" ≠ "what Anna remembers"). Entities are shared (everyone in the room knows the same world facts). Rolling summary is per-speaker.
4. **Storage shape.** Add `Chat.cast: [UUID]` (character ids in the room). Add `Turn.speakerId: UUID?` (nil for the user turn and legacy single-speaker chats; required for group-chat assistant turns). Migrate existing chats: legacy `Chat.characterId` becomes the only entry in `cast` if present.
5. **Retries via branching.** Regenerating a speaker's reply forks (Phase 7 behaviour) — preserves the alternative without losing the original's downstream context. No new mechanism needed; we just use `forkFrom` with the focused turn's id.

**Sub-step staging** (mirrors Phase 6 / 7's incremental shape):

- **§4.1** — Storage + migration ✅ shipped 2026-05-06. `Chat.cast: [UUID]`, `Chat.speakerSelection: SpeakerSelectionMode`, `Turn.speakerId: UUID?`, decode-time migration (schemaVersion v3→v4) that promotes `characterId` → first entry of `cast`, `Chat.validateGroupChat` enforcing no-duplicates / multi-cast assistant turns carry a resolvable `speakerId` / user turns never carry one. 15 new pure tests in `Phase8MigrationTests.swift` (567/567 passing).
- **§4.2** — PromptBuilder per-speaker assembly ✅ shipped 2026-05-06 (§4.2a/§4.2b/§4.2c). `SpeakerPicker` (round-robin / pooled / manual; `.director` deferred to §4.4), `Chat.pendingSpeakerId` + `consumePendingSpeaker()`, `SceneSummary.summariesBySpeaker: [UUID: String]?` lazy per-speaker scene cache, PromptBuilder wrap (cohabitant briefs via hybrid card scoping, `Sarah:` history prefix, cross-speaker `<think>` strip, group-nudge sysmsg at end-of-prompt), TokenBudget wiring, AppState send/regen/fork path stamps `Turn.speakerId` so the multi-cast invariant survives saves. 38 new pure tests across `SpeakerPickerTests` + `PromptBuilderGroupChatTests` (610/610 passing). UI to manage cast / pick speakers ships in §4.3 — until then, multi-cast is hand-edit-the-JSON only.
- **§4.3** — UI for cast management + speaker tagging ✅ shipped 2026-05-06. New "Cast" inspector pane (rows: avatar + accent dot + name + Remove; `+ Add character` popup for picking from the library). Speaker chip on each assistant turn (3pt accent ring around avatar + bold name pill above the bubble in the speaker's accent colour). Speaker picker on the input bar (visible only on multi-cast — bordered button labeled "Next: <name>" with a menu of cast members + 4 Auto modes). `SpeakerColor` deterministic palette. Inspector tab bar wrapped in a horizontal scroll view with a persistent legacy scroller so the pane shrinks below the segmented control's intrinsic width. Folded in a §4.3 promotion-gap heal: solo→multi promotion stamps existing nil-speakerId assistant turns with the chat's primary character (CastPane add path eager-stamps; `Chat.init(from:)` heals leftover broken state on next decode) so `validateGroupChat` doesn't reject a chat that grew from solo to multi-cast mid-life. 2 new pure tests in `Phase8MigrationTests` covering the heal (one obsolete throw-on-nil-speakerId test removed since auto-stamp made it unreachable; net +1, 611/611 passing). Frontend layer — smoke-tested manually with a 2-cast Lyra Moon + Captain Marin chat; round-robin alternated correctly across consecutive sends.
- **§4.4** — Director-LLM speaker selection ✅ shipped 2026-05-06. `DirectorPicker.next(chat:cast:kobold:effectiveCtx:completion:)` async LLM router routed through `template.assemble` (so Qwen3's empty `<think></think>` pre-fill suppresses the thinking trace — without it, the model burns the whole maxLength inside `<think>` and never produces a name). Targets the `.summarizer` role server (caveat: that's currently the user's main 35B model unless a smaller text-gen model is configured separately — embeddings model can't help here, it's a different architecture). 5s timeout watchdog with silent fallback to sync round-robin. Substring-match parser tolerates verbose responses ("I think Sarah should reply"); rightmost match wins. AppState send/regen path async-resolves speaker before stamping `Turn.speakerId`; sync path unchanged for non-director modes. Input-bar picker shows "Next: director will pick" header so the user knows the LLM router is active rather than misleading them with the round-robin fallback. 9 new pure tests in `DirectorPickerTests` with stub `KoboldGenerating` (620/620 passing). Smoke-tested: 2-cast Lyra + Captain chat, "How's the weather Captain?" routed to Marin in 0.6s, "And how do you see it Lyra?" routed to Lyra in 0.7s.
- **§4.5** — Polish + smoke ✅ shipped 2026-05-06. Per-turn voice routing (`Speaker.resolveSpeakerEntityId(turn:chat:characters:)` + `resolveSpeakerVoice(...)`): assistant turns with `Turn.speakerId` resolve through the speaker's character → entity-name match → entity voice as the segment-default, instead of every speaker falling through to `chat.voice`. Within-turn entity-attribution overrides still apply for cohabitants quoted in dialogue. Auto-create stub `Entity(name:type:.character, pinnedByUser:true)` for cards on `newChat(withCharacter:)` and `CastPane.addCharacterPicked` so voices can be assigned without waiting for the extractor + accepting a suggestion (`Chat.ensureCharacterEntity(_:)`). Tree minimap glyphs gain a 3pt left-edge accent strip per speaker (using `SpeakerColor` from §4.3) so the visual tree shows who said what at a glance. Diagnostic `speaker: voice-resolve` + `speaker: seg[N]` logs added per-turn so future "wrong voice" reports come with grep-able evidence (precedent for the new `feedback_diagnostic_logging` rule). Folded in a TurnView height fix: §4.3's chip layout shifted the bubble down by 18pt for the speaker name pill but didn't add it to `recomputeHeight`, which clipped the toolbar + made the textView scroll instead of expand — `speakerLabelHeight` ivar now plumbs through both sites. 12 new pure tests in `SpeakerTests` (632/632 passing). Smoke-tested: 2-cast Lyra Moon + Captain Marin chat with distinct voices assigned (af_bella + bf_lily), each speaker's reply voiced correctly, multi-segment heuristic attribution still fires for in-quote name matches.

**Phase 8 deferred polish ✅ shipped 2026-05-06.** Cast pane up/down reorder arrows on each row (chosen over native NSStackView drag-and-drop — no built-in support, cast lists are tiny, arrows more accessible — same UX outcome: change `chat.cast` order which drives round-robin / picker order). "Convert to solo chat…" button at the bottom of the Cast pane (visible only on multi-cast); confirmation alert with one button per cast member, picks the kept member, collapses cast + sets `characterId`, leaves existing turns' `speakerId`s intact (`validateGroupChat` solo-tolerance). Folded in a §4.5 solo-narrator regression: §4.5's per-turn `speakerVoice` baseline unintentionally changed solo behavior — narration started using the bound character's matched-entity voice instead of `chat.voice`. Restored via `cast.count > 1` gate in `handleStreamFinished` so multi-cast still routes per-speaker but solo falls through to chat-default as before. New `Chat.reorderCast(from:to:)` and `Chat.convertToSolo(keeping:)` mutating helpers; 9 new pure tests in `Phase8MigrationTests` (641/641 passing).

**Out of scope for Phase 8:**

- Cross-speaker memory synthesis ("everyone in the room agrees about X"). Research-shaped; not a Phase 8 problem.
- Inviting the user themselves as a multi-persona participant. Out of scope.
- Real-time speaker turn-taking like a chat room with typing indicators. Stays in turn-by-turn mode — same UX shape as today.
- Sharing chats across servers / federation. Way out of scope.

**Design doc:** drafted in the kickoff session as `V2_PHASE8_GROUP_CHATS.md` (mirroring how Phase 7 spawned `V2_PHASE7_FULL_BRANCHING.md` for the prior-art survey + per-sub-step contracts).

**Effort:** 1 day design + ~1.5 weeks build, broken across §4.1 → §4.5 commits.

---

## 5. Phase 9 — V11 Card creator + AI-assisted field population ⏳ next

The first major addition beyond the original V2 plan inventory. Goal: a dedicated card creator window callable from the menu (e.g. `File → New Character…` or `Library → New Card…`) that exposes every card field with examples shown as placeholder content, plus an opt-in "generate this field from prior fields" path that uses the model to draft suggestions the author can then edit. Author retains full control — AI-assist is a draft generator, not an autopilot.

**Step 1 — research-shaped (must precede settle-before-coding decisions).** Survey existing card formats so we know what the surface looks like before deciding what RPClient's editor should expose. References to read end-to-end:

- **SillyTavern v2** character card spec (`chara_card_v2`, embedded in card.png PNG text chunks; spec at github.com/malfoyslastname/character-card-spec-v2). Phase 3 already imports the v2 fields — read the spec for fields RPClient currently ignores or under-exposes.
- **SillyTavern v3** spec (adds `character_book` + `assets[]` + extensions; same PNG chunk format; backwards-compatible with v2 readers).
- **KoboldAI Lite** character format (V1 — flat description / personality / scenario; lighter than ST v2; commonly seen in `.json` exports from kobold.cpp).
- **Tavern AI legacy** format (predecessor to ST; some fields differ).
- **Open WebUI / Ollama Modelfile** parameters (different shape — more system-prompt-centric; useful as a "what does the LLM-deployment crowd expose" reference).
- Anything else surfaced by the research pass (Pygmalion, Risu, JanitorAI, Backyard, AI-Dungeon, NovelAI lorebook entries-as-characters).

Output of step 1: a design doc `V2_PHASE9_CARD_CREATOR.md` mirroring the Phase 7 / Phase 8 design-doc shape, containing: prior-art table (format ↔ fields ↔ notes), proposed RPClient field list (superset of supported imports + any RPClient-specific additions), per-field example library, AI-assist field dependency graph (which fields can be auto-drafted from which earlier ones — e.g. personality from description, first message from description+personality+scenario, alternate greetings from first message, etc.).

**Settle-before-coding decisions** (drafted in step 1, sign off in the kickoff session before §5.2 starts):

1. **Card format.** Stay on extended SillyTavern v2 (current shape), adopt v3 for export, or define a superset RPClient-native format that round-trips both? Lean: superset format with v2 exporter (max compatibility) and v3 exporter as opt-in once v3 readers are common.
2. **Storage.** Same `Character` Codable struct (extended), or a richer creator-side draft type that flattens into `Character` on save? Lean: extend `Character` directly — fewer types, importer code already targets it.
3. **AI-assist UX.** Per-field "Generate" button vs. unified "auto-fill missing fields" pass vs. inline ghost text the author accepts/rejects. Lean: per-field Generate, since it preserves author control and matches the user's "still changeable by the author" intent.
4. **Side-call routing.** Reuse `.summarizer` role server (decent text-gen quality; used by Phase 8 §4.4 director) vs. a new `.cardgen` role. Lean: `.summarizer` for v1; add `.cardgen` only if quality demands a dedicated model.
5. **Source of examples.** Hand-curated example library bundled with the app (used as field placeholders) vs. AI-generated examples? Bundled examples are static editor UX; AI-generated content is the dynamic-fill path. Both can coexist.

**Sub-step staging:**

- **§5.1** — Step-1 prior-art research + design doc draft. Output: [`V2_PHASE9_CARD_CREATOR.md`](V2_PHASE9_CARD_CREATOR.md). ~1 day. **Shipped 2026-05-06.** ST v2 + v3 specs surveyed end-to-end, KoboldAI Lite / RisuAI / Backyard / agnai cross-referenced. Settled decisions: extended-superset card format with v2 default + v3 opt-in export, `Character` extended directly (no draft type), per-field "Generate" with 2–3 candidate strip (literal/creative/terse triad, reactive re-conditioning), per-window server picker defaulting to active chat's server (`Settings.cardCreatorServerId`, *not* `.summarizer` — refusal-detection added since NSFW use case), bundled placeholder library + AI-generated content coexisting. Folded in scope clarifications during kickoff: unified create / edit / import-and-edit window (three `DraftOrigin` modes), Identity-tab avatar control routed through existing `Storage.normalizeAvatarData`, Examples-tab opt-in legacy-squash splitter, Advanced-tab read-only `extensions` JSON viewer, NSFW workflow notes (depth_prompt convention, post_history_instructions as UJB slot, NSFW-aware tag autocomplete).
- **§5.2** — Card model expansion (`Character` field additions, schema migration if shape changes, importer + exporter updates, round-trip tests). Pure tests. ~1-2 days.
- **§5.3** — Card creator window UI (`NSWindowController` + per-field controls organised into tabs / sections, inline validation, examples-as-placeholder, save → `AppState.characters` list). Smoke-tested as a frontend layer. ~3-4 days.
- **§5.4** — AI-assist field population. Per-field Generate button fires a side-call with the dependency-graph context (e.g., generate personality given description); response populates the field in draft state, author edits before save. Diagnostic logging from commit one (per the new feedback rule). ~2-3 days.
- **§5.5** — Polish + smoke. Multi-card flows, importer round-trips on real-world cards from the wild (ST/Kobold/etc), AI-assist chained generation across N fields. ~1 day.

**Out of scope for Phase 9:**

- Card portrait / avatar editing inside the creator. V10 already handles avatars; the creator just exposes the existing avatar source.
- Lorebook (`character_book`) editing within the creator. Phase 1's WorldInfoPane handles per-chat lore, and the importer pulls `charBook` into chat-level worldInfo. Card-bound lorebook editing inside the creator is a follow-up.
- Multi-card pack import/export (collections, ZIPs of cards).
- Marketplace integration / sharing / publishing cards externally.
- Inline character-card preview (live-render the card as the user edits) — optional polish, deferred.

**Effort:** ~1 week total, gated on the step-1 research pass producing the design doc.

**Design doc:** `V2_PHASE9_CARD_CREATOR.md`, drafted in §5.1.

---

## 6. Cross-cutting

### 6.1 Schema versioning forward-note

A `Settings.schemaVersion: Int` hook was proposed at Phase 4 kickoff; never landed because all Phase 4 / 5 / 6 changes were additive `decodeIfPresent` migrations that didn't need a versioned migration path. Add it the first time we hit a non-additive change (e.g., a field rename or type swap) — lazy is fine.

### 6.2 Migration testing convention

Standing convention: every phase that changes Chat or Settings shape ships its own migration tests alongside the data model change. Examples in-tree: `ChatSettingsVoiceTests`, `EntityVoiceTests`, `ChatCodableTests`, `Phase8MigrationTests`. A central `Tests/MigrationFixtures/` directory was originally proposed but never created — the per-phase tests have been sufficient. Spin up a fixtures directory if a future phase needs to migrate multiple legacy shapes at once.

### 6.3 Sandboxing forward-note

RPClient is unsandboxed today. If a sandboxed build (App Store) is ever desired, the user-configurable voice-model path needs security-scoped bookmark persistence rather than a raw URL string, and any future "user picks an external directory" UX inherits the same requirement. Not blocking — flagged so it isn't a surprise later.

### 6.4 What this plan does NOT do

- Memory subsystem polish — see [`NEXT_STAGES.md`](NEXT_STAGES.md) §A.
- Per-surface UI polish — the visual / interaction overhaul is its own deferred track (see §8), not folded into V2 feature phases.
- Per-character voices on by default — voice integration is opt-in per chat.
- Inline image rendering in turns. Out of scope; revisit when there's a demand signal.

---

## 7. Deferred — Voice attribution heuristic refinement

Moved out of Phase 6 on 2026-05-05 once the attribution-mode picker (§2.6) gave users a runtime escape hatch (switch any chat to Tagged when the heuristic underperforms). Phase 6 ships without this; queued for after Phase 7 / 8 unless attribution quality becomes the limiting factor in actual use.

**Why deferred:** the heuristic-polish round closed the obvious failure classes (quote-first dialogue verbs, bare `I` short-circuit, stale-mention dominance, character-card vs. entity-name mismatch). What remains is a long tail of model-specific quirks that needs *data*, not more speculative tuning. Without a corpus and an eval metric, further heuristic edits are sample-size-of-one tweaks that risk regressing earlier wins. The work is real, but it's research-shaped — better picked up deliberately than wedged between feature phases.

**Plan when picked up:**

1. Collect a corpus of recent assistant turns from real chats, captured at the input boundary of `SpeakerAttribution.split`.
2. Run the current heuristic over the corpus and dump `(turn-text, predicted-segments, attributed-voices)` triples to a fixture.
3. Hand-label the right answer for a representative sample (50–100 turns covering different chat styles, character setups, language registers).
4. Compute a confusion matrix — dominant failure modes likely include pronoun resolution, speaker-continuity loss after action verbs, overlapping first/third-person within a paragraph, model-specific quirks.
5. Decide per failure mode: heuristic tweak, gate behind tagged mode, or document as a limitation. Validate each tweak against the *full* corpus, not just the chat that motivated it — that sample-size-of-one trap is the bug class this step is trying to break out of.

**Agreed design decisions (recorded 2026-05-05).** Settled before deferral; honour when the design doc is drafted.

1. **Doc location.** Spin up a separate `V2_VOICE_HEURISTIC_REFINEMENT.md` at repo root. V2_PLAN is the index; the design doc cohabits with the code it affects.
2. **MVP scope.** Hand-collected corpus only for v1. Defer the synthetic / self-driven-chat research point. Spec the corpus format with `source: "captured" | "synthetic"` so a later synthetic pipeline can drop into the same eval harness without a schema change.
3. **Capture mechanism.** Both: opt-in debug setting (every assistant turn recorded — gets breadth) AND per-turn "save to corpus" button (user explicitly flags noticed failures — biases toward failure cases, useful for refinement). Single `CorpusRecorder` (~30 lines) handles both; capture-point is the input boundary of `SpeakerAttribution.split` so entity list + mode + `firstPersonEntityId` are recorded alongside text.
4. **Eval metric: per-character attribution accuracy.** Each character of the turn gets an attributed entity (or narrator) under the heuristic; compare char-by-char against the labelled entity. Robust to segment-boundary disagreements between heuristic and labeller — boundary differences only matter when they straddle a quote, and per-character accuracy already accounts for that. (Per-segment exact match was considered and rejected: simpler intuition but penalises minor boundary differences that don't affect what the user hears.)

**Research point — synthetic training data via self-driven chats.** A future agent session could drive the chat client itself to generate corpus turns under controlled conditions (known character setup, prompts crafted to elicit specific dialogue patterns, expected attribution baked into the prompt design). Open questions: programmatic chat-send hook (today no entry point exists outside `InputBar` + `AppState.send`); labels (author-by-construction vs agent-as-labeller, probably both with human spot-check); cost (each turn hits user's koboldcpp; ≤200 turns is trivial); determinism (low temperature + seed where possible). Stays out of v1 per the agreed scope above; the format leaves room for it.

---

## 8. Deferred — Complete UI overhaul

The app works; it doesn't yet *feel* good. After ~25 features have layered onto the same skeleton — sidebar + chat view + inspector + settings + library — the cumulative effect is visibly accreted: dense headers (chat header now carries Server + Attribution + Voice + speaker mute, all in 28 px), inspector panes that don't share a visual grammar, the Voice library window in its own one-off frame, etc. Nothing's broken; it's just clearly built feature-by-feature rather than designed.

**Why deferred:** functionality has been the right priority through V2 — branching and group chats have larger user impact than re-skinning. A UI overhaul is also exactly the kind of work that benefits from a settled feature surface; doing it before Phase 7 / 8 means re-doing the chat-view layout when branching adds a gutter glyph + sibling navigator and group chats add per-turn speaker styling. Defer until the feature surface stops moving.

**What the overhaul should cover:** every user-facing surface, not just the chat view. Sidebar (chat list rows, grouping, search, drag-drop), chat view (turn rendering, header density, input bar, status bar), inspector (pane consistency, density, hierarchy), library window (character/persona grids), Settings (tab structure, form density, the Voice section's special-casing), Voice library window (does this still need to be a separate window?), all popovers / sheets / alerts. Includes typography scale, spacing system, colour roles, motion language — the things that ad-hoc per-feature work cannot produce.

**The design doc should be grounded, not vibes.** Reference points to gather before proposing changes:

- **macOS HIG** — the platform conventions we're already half-following (NSPopUpButton bezels, accessory-bar-action buttons, sheet-on-window) and the ones we're drifting from (e.g., the chat view doesn't really match either Mail or Messages density, sits awkwardly between).
- **Modern macOS reference apps** — what does a polished AppKit app look like in 2026? Mail / Messages / Notes for the sidebar+main+inspector triptych; Xcode / Linear / Things for inspector density patterns; modern terminals (Ghostty, Wezterm) for typography scale.
- **AI-chat UX patterns** — how do other LLM clients handle dense per-turn metadata (variants, branches, speaker, regen state, edit history)? ChatGPT, Claude.ai, Open WebUI, SillyTavern — note what works and what doesn't, and *why*. Particular attention to how the better ones surface non-essential controls progressively (hover, focus, selection) rather than crowding them into the header.
- **Information density vs. air.** RPClient is a power-user tool — we lean denser than consumer-grade chat. But "dense" shouldn't mean "every feature gets its own permanent button." The design doc needs an explicit principle here, not just per-screen mockups.

**Deliverable:** `V2_UI_OVERHAUL.md` — a design doc that proposes the visual + interaction system before any code lands. Expected shape: principles → typography/spacing/colour system → per-surface mockups (sketches or annotated screenshots) → migration plan (which surfaces ship first, what risks). Likely runs longer than the other design docs (~500 lines) because it covers more surface area.

**When to pick this up:** after Phase 7 (branching) and Phase 8 (group chats) ship. Possibly earlier if a specific surface becomes a clear blocker (e.g., the chat header running out of horizontal space). The existing "chat-view UI overhaul" pointer in [`NEXT_STAGES.md`](NEXT_STAGES.md) §E is narrower in scope than this; expect that track to be folded into the overall overhaul rather than shipped separately.

---

## 9. References

- [`PLAN.md`](PLAN.md) — original MVP plan (V2 inventory in §10).
- [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md) — Memory V2 subsystem plan (Steps A–D, shipped 2026-05-03).
- [`MEMORY_AUDIT.md`](MEMORY_AUDIT.md) — authoritative record of memory-subsystem behaviour.
- [`MEMORY_HANDOFF.md`](MEMORY_HANDOFF.md) — current memory state + active issues.
- [`NEXT_STAGES.md`](NEXT_STAGES.md) — fragmented forward notes (memory polish §A; chat-view styling §E — folds into the §7 overhaul when picked up).
- `V2_PHASE7_FULL_BRANCHING.md` — Phase 7 design doc (TBD, drafting next).
- `V2_VOICE_HEURISTIC_REFINEMENT.md` — heuristic refinement design doc (TBD, see §6).
- `V2_UI_OVERHAUL.md` — complete UI overhaul design doc (TBD, see §7).
