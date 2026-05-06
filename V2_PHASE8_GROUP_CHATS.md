# RPClient V2 Phase 8 — Group chats design doc

**Status: draft, awaiting sign-off.** See [`V2_PLAN.md`](V2_PLAN.md) §4 for the parent plan entry and the five settle-before-coding decisions this doc expands on.

## Why

Today every chat is bound to (at most) one character via `Chat.characterId`. The user can switch which character a chat belongs to, but the prompt is always assembled around a single card / persona / system prompt / voice. There is no way to put two characters in the same room and let the conversation alternate between them — a core roleplay scenario.

Phase 8 makes the chat **multi-cast**. A `Chat` carries a `cast: [UUID]` of character IDs; each assistant `Turn` carries a `speakerId: UUID?` resolving to a member of the cast. Per-turn prompt assembly switches "the character" on the fly so each speaker pulls their own card / persona / scene memory / voice. Retries fork the tree (Phase 7 mechanism, no new infra).

Half the work is already done by prior phases:

- **Per-character voices** (Phase 6) — voice routing already keys off character ID, so adding a second speaker inherits per-character TTS for free.
- **Avatars** (V10) — same: avatars are looked up by character ID at render time.
- **Entity store** (V2 Step C) — shared world facts already live outside the per-character lorebook, naturally room-scoped.
- **Branching tree** (Phase 7) — regenerate-as-fork is the same primitive whether the prior turn was the only speaker's reply or one of three.

The new mechanism is the **orchestration layer**: speaker selection, per-speaker prompt assembly, and the UI for managing the cast.

## 1. Scope

**In scope (sub-steps §4.1 → §4.5):**

- Storage shape: `Chat.cast: [UUID]`, `Turn.speakerId: UUID?`, decode-time migration, validation.
- Per-speaker prompt assembly inside `PromptBuilder` — each speaker pulls their own card / persona / lorebook / scene summaries.
- Speaker selection: round-robin (default), pooled, manual, plus an opt-in director-LLM picker.
- UI surface: Cast inspector pane, speaker chip on each assistant turn, input-bar speaker picker, speaker-aware Branches pane / Tree minimap.
- Lazy per-speaker scene summaries — summarise on first read by that speaker, share entities room-wide.

**Out of scope (this phase):**

- **Cross-speaker memory synthesis.** "Everyone in the room agrees about X" / "what Sarah knows about Anna separately from her card" — neither prior-art tool models theory-of-mind, and it's research-shaped. Phase 8 ships per-speaker lazy summaries + shared entity store; cross-speaker reconciliation is a later, optional feature.
- **User as multi-persona participant.** Single user persona per chat. Multiple user personas in one chat is a different feature (DM-like routing).
- **Real-time turn-taking.** Stays turn-by-turn — no typing indicators, no concurrent streams. Same UX shape as today.
- **Atomic multi-speaker rounds.** Each speaker reply is its own tree node. We do not generate `[A, B, C]` as a single transaction the way SillyTavern's group regenerate does (§5.1 explains why).
- **Cross-server federation / shared chats.** Way out of scope.
- **APPEND card mode** (every cast member's full card in every speaker's prompt). Default to SWAP-with-brief-cohabitants (§4.1). Full APPEND can land later as an opt-in if regressions appear.
- **Pruning unused cast members.** Adding/removing a character from the cast is supported, but historical turns from a removed character stay in the tree (their `speakerId` still resolves to the character record, which lives in the entity store regardless of cast membership).

## 1.5 Prior art

Surveyed at the source-code level. Two production references; one shows the pattern, the other shows a non-pattern.

**SillyTavern** (`public/scripts/group-chats.js` + `public/scripts/openai.js`) is the closest production match — true multi-character group chat with turn-taking. Four selection modes (`group_activation_strategy` constants `NATURAL` / `LIST` / `MANUAL` / `POOLED`); per-turn the active speaker becomes "the character" for the normal single-char generate path. Card scoping is a real product knob (`group_generation_mode`: `SWAP` shows only the active card, `APPEND` concatenates all cards). History formatting keeps `assistant` role for every character with a name prefix in content (`group-chats.js` calls `Sarah: …` style); the user remains `user`. A "group nudge" system message — default `'[Write the next reply only as {{char}}.]'` — is appended at end-of-prompt to keep the model from impersonating siblings. Storage is a JSONL chat file plus a sibling `group` definition file with `members: string[]` (avatar filenames as IDs); per-message attribution is by `original_avatar` + `name` strings. Retries are flat `swipes: string[]` arrays and group-regenerate is **atomic** — it deletes back to the user message and re-runs the speaker round, because their swipe model can't represent partial round re-rolls.

**Open WebUI** (`src/lib/components/chat/Chat.svelte`) is **not** a group-chat tool. Its multi-model affordance is parallel responses to one user turn — N models all answer the same prompt for comparison, never aware of each other. There is no "next speaker," no turn-taking, no cast. Its tree storage (`history.messages[id] = { parentId, childrenIds[], ... }` + `currentId`) is the same shape RPClient already uses post-Phase-7 — useful as a reference for how parallel-sibling retries work, **not** as a model for group conversation. Memory is a flat user-level `Memories` table injected into every chat.

**What we borrow (mostly from SillyTavern):**

- **Mode menu**: round-robin (their `LIST`), pooled (their `POOLED`), manual (their `MANUAL`). Skip "talkativeness RNG" (their `NATURAL`) — RPClient is a deliberate scene tool, not a chatroom simulator.
- **`assistant` role + `Sarah:` content prefix** for every speaker. Same role for self vs. others; cross-speaker reasoning blobs (think tags, etc.) get stripped on history assembly.
- **The "group nudge" system message verbatim.** It's tiny, easy to miss, and the load-bearing trick that keeps a model from drifting into impersonation. Inserted at end-of-prompt each turn, parameterised on the active speaker's name.
- **Per-speaker character-lorebook scope.** When character A generates, only A's lorebook (and any room-shared lore) fires. Maps cleanly onto RPClient's existing `WorldInfoEntry` machinery once we route by speaker ID.

**Where we go beyond prior art:**

- **Single-speaker turn = single tree node.** SillyTavern can't represent partial round re-rolls because its swipes are flat per-message arrays; RPClient's tree lets you regenerate just speaker 2 of `[1, 2, 3]` and keep `[1]` frozen as ancestor. See §5.
- **Stable-ID speaker attribution.** SillyTavern attributes by string name; rename a character and old messages still say the old name in the prompt. RPClient stores `Turn.speakerId: UUID?` and resolves to display name at prompt-build time.
- **Lazy per-speaker scene summaries.** Neither tool does this. SillyTavern shares scene/scenario across the room (`chat_metadata.scenario`); Open WebUI has nothing equivalent. RPClient summarises on first read by a given speaker — see §4.3.
- **Director-LLM speaker selection** (opt-in, §4.4 sub-step). Genuinely novel. SillyTavern's `NATURAL` mode is heuristics + RNG, not an LLM call; Open WebUI doesn't have the concept. No prior art to copy — design as greenfield.

**What we explicitly skip:**

- **APPEND-by-default card mode.** Token-cost is real (every speaker's full card on every turn × every generation). Default to a hybrid: full card for the active speaker, brief one-line summary for other cast members (§4.1). APPEND-everything stays as a possible follow-up if a model genuinely needs full cohabitant context to maintain character.
- **SillyTavern's atomic round regenerate.** See §5.1.
- **String-name attribution.** See above — stable IDs only.
- **Talkativeness RNG.** Per-character "how chatty" sliders create chaotic conversation rhythms; not the right default for scene-driven roleplay.
- **Per-character `disabled_members` list.** SillyTavern keeps disabled members in `members` and filters at selection time. RPClient just removes from `cast`; the entity store keeps the character record regardless.

## 2. Data model

### 2.1 Schema additions

```swift
struct Chat: Codable, Identifiable, Equatable {
    // ...existing fields...

    /// Phase 8 §4.1 — character IDs in the room. Empty on solo chats and on
    /// pre-Phase-8 chats whose `characterId` was nil. Single-entry on legacy
    /// chats whose `characterId` was non-nil (filled by decode-time migration).
    /// Order matters: round-robin selection cycles in declaration order, and
    /// the input-bar speaker picker presents the cast in this order.
    var cast: [UUID]

    /// Phase 8 §4.4 — speaker selection mode. Default `.roundRobin`. UI lives
    /// in the input-bar speaker picker (§4.3) with a per-chat persistence.
    var speakerSelection: SpeakerSelectionMode
}

enum SpeakerSelectionMode: String, Codable {
    case roundRobin   // cycle through cast in order
    case pooled       // everyone speaks before anyone repeats
    case manual       // user picks each turn
    case director     // §4.4 — LLM-router decides
}

struct Turn: Codable, Identifiable, Equatable {
    // ...existing fields...

    /// Phase 8 §4.1 — the character whose turn this is. Nil for user turns
    /// and for assistant turns in solo (cast.count <= 1) chats. Required to
    /// resolve to a member of `Chat.cast` when the chat is multi-speaker.
    /// Validation enforced at decode time, not on append (matches Phase 7's
    /// transient-invalid-tolerant in-memory mutation model).
    var speakerId: UUID?
}
```

`Chat.schemaVersion` bumps from `3` to `4`. The bump is what triggers the cast-seeding migration in `Chat.init(from:)`.

No new top-level type; `cast` is a flat `[UUID]` rather than a struct array because per-speaker render metadata (display name, voice, avatar) all already lives on the `Character` record and gets resolved at read time. Keeping cast as bare IDs avoids duplicating fields that drift.

### 2.2 Migration

Two cases, detected at decode time:

**(a) Pre-Phase-8 (`schemaVersion < 4`).** Decoded chat has no `cast` field (or empty). If `characterId` is non-nil, seed `cast = [characterId!]`. If `characterId` is nil, leave `cast = []` (free-form chat, stays free-form). Existing assistant turns get `speakerId = nil` — solo-chat invariant says nil is fine when `cast.count <= 1`.

**(b) Phase-8+ (`schemaVersion >= 4`).** Trust the decoded `cast` and per-turn `speakerId`s. Run validation.

After migration, bump `schemaVersion` to `4`. The migration is one-way (no down-version) — same precedent as the v2 / v3 entity-store migrations.

### 2.3 Validation invariants

Modelled on `Chat.validateBranching` (Phase 7 §3.1). Runs at decode time, throws `DecodingError.dataCorrupted` describing the first violation:

1. **Cast members exist.** Every UUID in `cast` resolves to a `Character` in `AppState.characters` at read time *if* characters are loaded — but the validation here only checks structural shape (no duplicates within `cast`). Cross-reference resolution is best-effort at render time (an unresolvable cast member shows as "Unknown" rather than crashing).
2. **Speaker-required for multi-cast assistant turns.** If `cast.count > 1`, every turn with `role == .assistant` must have `speakerId != nil` and `cast.contains(speakerId!)`.
3. **No speaker on user turns.** Turns with `role == .user` must have `speakerId == nil`. (User-side personas are separate — `Chat.personaId`.)
4. **Solo-cast tolerance.** If `cast.count <= 1`, `speakerId` is allowed to be nil on assistant turns. Pre-Phase-8 chats migrated forward this way; the validation must not flag them.

Encode-side enforcement is **not** added (matches Phase 7 precedent). In-memory mutation can transiently violate the invariant; only on-disk state must round-trip cleanly.

## 3. Speaker selection

### 3.1 Modes

Four modes, three shipped in §4.2, the fourth opt-in via §4.4:

- **`.roundRobin`** (default). Cycle through `cast` in declaration order. Picks the cast member at `(lastAssistantPosition + 1) % cast.count`, where `lastAssistantPosition` is the index in `cast` of the most recent assistant turn's `speakerId`. If no prior assistant turn exists (e.g. first reply after the user's opening message), picks `cast[0]`.

- **`.pooled`**. Tracks "spoken since last user turn" — picks anyone in `cast` who hasn't spoken yet in this round. Once everyone has spoken, the round resets (next user turn restarts the pool). When the pool is empty mid-round, falls back to round-robin starting from where we left off. Mirrors SillyTavern's `POOLED` mode but without the "exclude immediately-prior speaker" heuristic — explicit user input drives the next pool, not RNG.

- **`.manual`**. The input-bar speaker picker (§6.3) sets `pendingSpeakerId` on `Chat`; that consumes on next assistant generation, falling back to round-robin if unset. UI defaults the picker to the round-robin pick so the user sees what would happen by default and can override.

- **`.director`** (opt-in, §4.4). A small side-call LLM is asked "given this conversation tail, who should speak next? Respond with one of: {Anna, Sarah, Lila}." The router model defaults to the same role override used for the summarizer (`Settings.summarizerServerId` / `.summarizerModelId`), so the user picks a small fast model once and it covers both. The call returns one cast member's name; on parse failure or timeout, falls back silently to round-robin.

### 3.2 The "group nudge"

Stolen verbatim from SillyTavern (`public/scripts/openai.js:114`). Per turn, `PromptBuilder` appends a system message at end-of-prompt:

```
[Write the next reply only as {{char}}.]
```

with `{{char}}` substituted to the active speaker's display name. This is the load-bearing trick that keeps the model from impersonating siblings — small, cheap, well-validated upstream. Localised under the existing template machinery so non-English templates can override the wording.

### 3.3 Speaker-not-responding

A speaker that returns empty text (after content-filter strip) is **not** retried automatically. The empty turn is appended as-is and the user sees the empty bubble; round-robin advances on the next generation. Matches both upstreams (SillyTavern's `NATURAL` mode also accepts empty `activatedMembers`; Open WebUI doesn't have the concept). If a model consistently refuses for a given speaker, the user notices and can swap the cast member or edit the system prompt.

## 4. Per-speaker prompt assembly

### 4.1 Card scoping — hybrid SWAP-with-brief-cohabitants

For each generation:

- The **active speaker's card** loads in full: `description`, `personality`, `scenario`, `system_prompt`, `mes_example`, `creator_notes`. Same path as solo-chat today (`PromptBuilder` reads `AppState.characters[chat.speakerId!]`).
- **Other cast members** contribute a one-line brief assembled from `Character.name` + the first sentence of `Character.description` (truncated to ~60 tokens). Concatenated under a `[Other characters present:]` block at end-of-system-prompt.

Example (3-cast chat, Anna speaking):

```
<system>
You are Anna. {Anna's full card description...}

{Anna's persona, scenario, system_prompt as today}

[Other characters present:]
- Sarah: A cautious diplomat from the eastern reaches.
- Lila: A young thief with a sharp tongue.
[Write the next reply only as Anna.]
</system>
```

Why this default rather than full SWAP or full APPEND:

- **Full SWAP** (active card only, no cohabitant info): the model has to infer the existence of other speakers from the conversation alone. Works for short chats, drifts into solipsism on long ones — the model forgets Sarah is in the room.
- **Full APPEND** (every full card every turn): token-expensive (3 cards × ~800 tokens each = 2.4k of system prompt every turn × every regen). Wasteful when the model only needs to know "who is Sarah" at a high level.
- **Hybrid**: ~150 tokens of cohabitant briefs per turn — survives long chats, doesn't blow the budget.

Configurable per chat as a follow-up if needed (`Chat.cardScopingMode: .swap | .hybrid | .append`); default `.hybrid`. §4.1 ships `.hybrid` only and treats the field as implicit (no UI yet).

### 4.2 History formatting

Every assistant turn in the history renders as `assistant` role with a content prefix:

- The active speaker's own prior turns: prefixed with their name, `Anna: …`.
- Other speakers' prior turns: prefixed with their name, `Sarah: …`. Same role.
- The user's turns: `user` role, no prefix.

Same role for self vs. others matches SillyTavern's `setOpenAIMessages` path. The name prefix is what gives the model the disambiguation hook; without it, two `assistant` messages in a row collapse into "the model continuing itself."

**Cross-speaker reasoning stripping.** RPClient's think-block filter today strips `<think>…</think>` from assistant text on display but preserves it in storage. For prompt assembly: when speaker A is generating and the history includes speaker B's `<think>…</think>` content, strip B's reasoning before injecting. (B's own reasoning is rationale for B, not signal for A; injecting it leaks model-internal state across personas.) The active speaker's *own* prior reasoning stays in.

**Gemma-specific risk.** Gemma's chat template has a known fold-tendency on consecutive `model` turns. The `Sarah:` prefix mitigates it but doesn't eliminate it. §4.5 smoke-test must cover 2- and 3-speaker chats on Gemma specifically. If folding regresses, the fallback is templating other speakers as `user` role with the prefix (less honest about conversation shape, cleaner per-character voice) — but only if measured.

### 4.3 Memory routing

Three layers, each scoped differently:

- **Per-character lorebook (`WorldInfoEntry` for the speaker's card).** Private to that speaker's turn. When Anna generates, only Anna's character-attached lorebook entries fire. Maps onto SillyTavern's `getCharacterLore(this_chid)` pattern but routed by `chat.speakerId` rather than the global "current character."
- **Shared entity store (`Chat.entities`).** Room-scoped; everyone sees the same world facts. No change from today — entities are already chat-scoped, not character-scoped.
- **Scene summaries (`Chat.sceneSummaries`).** **Lazy per-speaker.** Storage shape stays as today: a single `[SceneSummary]` array on `Chat`. But each `SceneSummary` carries a new optional field `summariesBySpeaker: [UUID: String]` (default empty); when speaker A is about to read scene N, `PromptBuilder` checks for `summariesBySpeaker[A]`; if present, use it; if absent, summarise from raw turns *for A* and cache the result back into `summariesBySpeaker[A]`. Original `text` field becomes the "narrator's view" / fallback for solo chats, written by the existing summarizer pass.

Lazy = each speaker pays the summarizer side-call exactly once per scene per speaker. Acceptable cost (one extra side-call when a speaker is brought into the room for the first time after a scene completes); the alternative (eager) would N× every scene-break summarizer pass and the alternative (shared) loses the "what Sarah remembers" framing the user wants.

§4.1 just adds `summariesBySpeaker: [UUID: String]?` to the `SceneSummary` model with a defaulting decoder. The lazy fill logic lands in §4.2 with the rest of `PromptBuilder`.

### 4.4 Tail-reinforce + extraction priorities

`tailReinforceMemory` (the §9.6 last-300-tokens reinforcement) stays per-chat, not per-speaker. It targets the chat's user message reading; the speaker doesn't change which user turn gets the reinforcement.

`factExtractionPriorities` stays per-chat. The §9.3 extractor is a room-level pass — entities are shared, so extraction priorities are too.

## 5. Retries + branching interaction

### 5.1 Single-speaker turn = single node

Each assistant `Turn` represents one speaker's reply. A round of `[Anna, Sarah, Lila]` is **three sequential turns**, not one. This is the core divergence from SillyTavern (whose group regenerate is atomic over the whole round because their swipe model can't represent partial re-rolls).

Consequence: **regenerating speaker 2 of `[Anna, Sarah, Lila]` forks at Sarah's turn** via `Chat.fork(parentId: anna.id, newTurn: newSarah)`. Lila's turn from the original branch stays as a child of the original Sarah turn — **off-path on the new branch, still reachable via the Branches pane**. The new branch has no Lila reply yet; the next generation on the new branch picks the next speaker per the active selection mode (round-robin would pick Lila; pooled would pick Lila if she hadn't spoken in the new branch's round).

This gives the user fine-grained control: re-roll one speaker without losing the others, or re-roll the whole round by switching to a fresh fork from the user message and regenerating from there. The cost is one user-facing concept (the fork happens at the speaker's turn, not at the round boundary) — which matches Phase 7's existing fork-at-any-turn UI, no new surface.

### 5.2 Orphaned downstream turns

When the user forks at Sarah's turn, Lila's prior reply (under original-Sarah) is **not auto-replayed** on the new branch. Reasoning: Lila's reply was generated with original-Sarah in context; under new-Sarah it would be incoherent. The Branches pane shows "Original branch — Lila's reply preserved at TN+1" and the user can switch back if they want it.

This is an explicit choice. Auto-replaying would be harder UX (the user has to wait for re-generation of every downstream turn) and would discard the original Lila text. The user can manually copy Lila's reply across branches via the existing edit affordance if they want it.

### 5.3 Cmd-B fork on group chats

Cmd-B today (Phase 7 §3.3) forks from the focused turn. In a group chat it works identically: focus a speaker's turn, Cmd-B forks at that turn, the new branch has no descendants. Next generation picks the next speaker per the active selection mode.

## 6. UI surface

### 6.1 Cast inspector pane

New pane in the Inspector (third tab after "Chat" and "Branches"). Lists current cast members as horizontal cards: avatar, name, "Remove" button. Below the list, a "+ Add character" button opens a Library-window picker (re-using the picker pattern from Phase 6 / V10). Drag-to-reorder updates `Chat.cast` order, which is the round-robin / picker order.

A "Convert to solo chat" button at the bottom of the pane reduces `cast` to a single member (user picks which one) — destructive, prompts for confirmation, doesn't affect existing turns' `speakerId`s (they remain valid pointers; turns from removed cast members keep their speaker attribution but the speaker no longer cycles into round-robin).

### 6.2 Speaker chip on each assistant turn

Replaces today's "AI" / "model" label on assistant turn bubbles. Renders the speaker's avatar (24px) + name. Click → focuses the cast pane on that member. Colour-accented per-speaker (deterministic colour from character UUID hash) so the user can scan a long chat and see who spoke when at a glance.

For solo chats (`cast.count <= 1`), the chip falls back to the existing "AI" label rendering — no visual change for legacy chats.

### 6.3 Input-bar speaker picker

Small popup-button to the left of the send button: shows the *next* speaker per the current `speakerSelection` mode, with a chevron to override. Click reveals a menu: cast members + "Auto (round-robin)" + "Auto (pooled)" + "Auto (director)". Picking a specific cast member sets `Chat.pendingSpeakerId` (consumed on next generation, then cleared). Picking an Auto mode updates `Chat.speakerSelection` and clears `pendingSpeakerId`.

For solo chats, hidden — no clutter.

### 6.4 Speaker-aware Branches pane / Tree minimap

Branches pane (Phase 7 §3.4) row label gets the speaker's avatar + name appended for assistant-turn leaves: `Branch B — Sarah, T12 (forked at T9)`. Tree minimap (Phase 7 §3.5) glyphs colour-tint per speaker using the same hash colour as the speaker chip. Lands in §4.5.

### 6.5 What this UI does NOT do

- No drag-to-reorder of turns within a cast (the speaker order is fixed by `cast` list order; reordering cast reorders round-robin).
- No "mute character" toggle (remove from cast instead).
- No per-character chat-template override (template is per-chat as today; if two cast members need different templates, the user should run two solo chats — out of scope).
- No "have everyone respond to this user message in parallel" (Open WebUI's pattern). Stays turn-by-turn.

## 7. Sub-step contracts

### §4.1 — Storage + migration

**Goal:** schema additions + decode-time migration of legacy chats. Pure tests. No UI, no prompt assembly, no selection logic.

**Scope:**

- Add `Chat.cast: [UUID]`, default `[]`.
- Add `Chat.speakerSelection: SpeakerSelectionMode`, default `.roundRobin`.
- Add `Turn.speakerId: UUID?`, default `nil`.
- Add `SpeakerSelectionMode` enum.
- Decode-time migration: `schemaVersion < 4` and `characterId != nil` → seed `cast = [characterId!]`. Bump `schemaVersion` to `4`.
- `Chat.validateGroupChat(...)` static method (mirrors `validateBranching`). Throws on:
  - duplicate UUIDs in `cast`,
  - `cast.count > 1` and any assistant turn has `speakerId == nil` or `!cast.contains(speakerId!)`,
  - any user turn has `speakerId != nil`.
- Validation called from `Chat.init(from:)` after migration.

**Tests (TDD-first):**

1. Decoding a v3 chat with `characterId` set seeds `cast = [characterId]` and bumps version to `4`.
2. Decoding a v3 chat with `characterId == nil` leaves `cast = []` and bumps version to `4`.
3. Decoding a v4 chat with explicit `cast` round-trips identically (no re-migration).
4. Decoding a v4 multi-cast chat with a missing `speakerId` on an assistant turn throws.
5. Decoding a v4 chat with `speakerId` not in `cast` throws.
6. Decoding a v4 chat with `speakerId` set on a user turn throws.
7. Decoding a v4 solo chat (`cast.count == 1`) with `speakerId == nil` on assistant turns succeeds (back-compat).
8. Encode-then-decode round-trip preserves `cast`, `speakerSelection`, and `speakerId`s.
9. `Chat.validateGroupChat(...)` invoked directly produces the expected error descriptions for each failure case.

**Smoke (post-tests):** open the macOS app, open a legacy single-character chat, confirm it renders identically and the JSON-on-disk now has `cast: ["{characterId}"]` after the next save. ~1 day.

### §4.2 — PromptBuilder per-speaker assembly + selection

**Goal:** `PromptBuilder` produces a per-speaker prompt; selection logic (round-robin, pooled, manual) decides who's next.

**Scope:**

- Add `Chat.pendingSpeakerId: UUID?` (consumed on next assistant generation).
- New `SpeakerPicker` type with `next(in chat: Chat) -> UUID?`. Implements `.roundRobin`, `.pooled`, `.manual`. (Director is §4.4.)
- Wrap `PromptBuilder.build(for:)` so when called on a multi-speaker chat, it:
  - Resolves `Character` for the speaker (not `chat.characterId`).
  - Pulls the speaker's persona (uses existing `chat.personaId` as a global user-side persona — same as today).
  - Loads cohabitant briefs (§4.1 hybrid scoping).
  - Formats history with name prefixes (§4.2).
  - Strips cross-speaker reasoning blocks.
  - Appends the group-nudge system message.
  - Routes per-speaker character lorebook + lazy scene summary fill (§4.3).
- `SceneSummary.summariesBySpeaker: [UUID: String]?` field added with defaulting decoder (forward-compat for the lazy fill).

**Tests (TDD-first):**

1. `SpeakerPicker.roundRobin` cycles through cast in order across consecutive assistant turns.
2. `SpeakerPicker.pooled` picks each cast member exactly once per round, resets on user turn.
3. `SpeakerPicker.manual` returns `pendingSpeakerId` if set, falls back to round-robin if not.
4. `PromptBuilder` for a 2-cast chat produces two distinct prompts depending on `speakerId`, each loading the respective full card.
5. Cohabitant briefs render the other cast members' first-sentence descriptions, capped at ~60 tokens each.
6. The group-nudge system message appears at end-of-prompt with the correct speaker name substituted.
7. History formatting prefixes each prior assistant turn with its speaker's name; the active speaker's own prior reasoning is preserved while other speakers' reasoning is stripped.
8. Lazy scene-summary fill: requesting a scene for speaker A populates `summariesBySpeaker[A]` and returns the cached value on subsequent reads.

**Smoke:** create a 2-cast chat in the running app, send a user turn, verify both speakers can generate sensible replies in succession via round-robin (UI override comes in §4.3 — for now, manually edit `Chat.pendingSpeakerId`). ~2-3 days.

### §4.3 — UI: Cast pane + speaker chip + input-bar picker

**Goal:** the user can manage cast and steer who speaks via the UI. Pure glue + AppKit; smoke-test rather than unit-test as a frontend layer.

**Scope:**

- Cast pane in Inspector (§6.1).
- Speaker chip on assistant turn bubbles (§6.2).
- Input-bar speaker picker (§6.3).
- Library-window picker re-use for "+ Add character."
- Hash-derived per-speaker accent colour (deterministic from `Character.id`).

**Tests:** smoke-only — open a chat, add a second character, confirm speaker chips render correctly across cast, manual speaker override picks the chosen member, removing a cast member doesn't crash old turns. Flag honestly: no unit tests for this sub-step. ~2 days.

### §4.4 — Director-LLM speaker selection

**Goal:** opt-in `.director` mode that asks a small model "who speaks next?".

**Scope:**

- Add `.director` case to `SpeakerSelectionMode`.
- `DirectorPicker` makes a side-call to the summarizer-role server (`Settings.summarizerServerId`), prompt: "Given this conversation, who speaks next? Respond with one of: {names}." Parses one cast member's name out of the response.
- On parse failure / timeout / network error, falls back silently to `.roundRobin`. Logs the failure to the existing health-tick log so the user can see it's degrading.
- UI: enable the `.director` option in the input-bar picker. Show a small "(experimental)" tag.
- Per-chat toggle persists via the existing `Chat.speakerSelection`.

**Tests:**

1. `DirectorPicker.next(in:)` with a stub LLM client returning "Sarah" picks Sarah.
2. Stub returning unparseable output falls back to round-robin pick.
3. Stub timing out (>5s) falls back to round-robin.
4. Logs include the side-call duration on success and the failure reason on fallback.

**Smoke:** flip a 3-cast chat to `.director`, send a few user turns, confirm speaker selection feels coherent. ~1-2 days.

### §4.5 — Polish + speaker-aware Branches/Tree + Gemma smoke

**Goal:** speaker-awareness in the Phase 7 visual UIs; final smoke test on Gemma.

**Scope:**

- Branches pane row labels include speaker avatar + name on assistant-turn leaves.
- Tree minimap glyph colour-tint per speaker (uses the same hash colour as the speaker chip).
- Verify Phase 6 voice routing still attributes correctly when speakers alternate (each speaker's `Character.voice` overrides chat-default; entity-level voice override still fires).
- Smoke: 2-cast and 3-cast chats on Gemma 3, confirm no impersonation drift across 30+ turns. If drift appears, document the regression and propose either (a) fall-back to `user`-role formatting for non-active speakers (§4.2 fallback path) or (b) more aggressive nudge-prompt wording.

**Tests:** unit tests for the speaker-aware label rendering helper. Smoke for the Gemma run; document numbers in the commit message. ~1 day.

## 8. Migration test strategy

Same shape as Phase 7 §7. For each schema bump, ship a fixture chat in `Tests/RPClientCoreTests/Fixtures/` representing the prior schema version, plus a test that decodes it and asserts the post-migration shape. Specifically:

- `chat_v3_solo.json` — pre-Phase-8 single-character chat. After decode: `cast == [characterId]`, `schemaVersion == 4`, all assistant turns have `speakerId == nil` (legacy back-compat).
- `chat_v3_freeform.json` — pre-Phase-8 chat with `characterId == nil`. After decode: `cast == []`, `schemaVersion == 4`.
- `chat_v4_group_2cast.json` — Phase-8 2-cast chat with mixed speaker turns. Round-trips identically.
- `chat_v4_invalid_speaker.json` — Phase-8 chat where an assistant turn's `speakerId` doesn't resolve to a cast member. Decode throws with the documented error.

Each test goes in `Phase8MigrationTests.swift` (new file). The fixture format mirrors what real chats look like on disk (no abbreviation) so a future schema migration that touches an unrelated field doesn't break Phase-8 fixtures and vice versa.

## 9. Decisions taken

For traceability after the fact:

1. **Round-robin is the default.** Pooled and manual are first-class alternatives; director is opt-in (§3.1). Talkativeness RNG is rejected.
2. **Speaker turn = single tree node.** No atomic multi-speaker rounds (§5.1). Diverges from SillyTavern; matches Phase 7's fork-at-any-turn UI.
3. **`assistant` role + `Sarah:` content prefix** for every speaker, with cross-speaker reasoning stripped (§4.2). Same-role-for-all matches SillyTavern; reasoning stripping is RPClient-specific.
4. **Hybrid card scoping** as default (§4.1) — full active card + one-line cohabitant briefs. SWAP and APPEND are open extensions, not shipped in §4.2.
5. **Lazy per-speaker scene summaries.** `SceneSummary.summariesBySpeaker: [UUID: String]?`, filled on first read by each speaker (§4.3). Entities and tail-reinforce stay shared.
6. **Stable-ID speaker attribution.** `Turn.speakerId: UUID?`, never the display name. Display name resolved from `Character` at render / prompt time (§2.1). Diverges from SillyTavern.
7. **Group-nudge system message** stolen verbatim from SillyTavern (§3.2). Localised under templates.
8. **No UI for cohabitant scope mode** in §4.2. Hybrid is hard-coded; SWAP / APPEND become user-facing only if measured regression appears.
9. **Schema bump to v4.** Triggers cast-seeding; one-way migration (§2.2).
10. **Decode-time validation only.** No encode-side enforcement; transient in-memory invalids are tolerated (§2.3). Matches Phase 7.
11. **`personaId` stays per-chat, not per-speaker.** User-side persona is single. Multi-persona-user is out of scope.

## 10. Out-of-scope items to revisit later

- **Cross-speaker memory synthesis** ("everyone agrees X happened"). Research-shaped; not engineering. Possibly addressable via a periodic side-call that reconciles per-speaker scene summaries into a shared chat-wide narrator scene summary.
- **Theory-of-mind layer** ("what Sarah knows about Anna" separately from Anna's card). Genuinely novel; no prior art. Worth considering as a Phase 8.5 if user feedback says cohabitant briefs feel too thin.
- **APPEND-everything card mode** as a user-facing toggle. Add only if measured regression on hybrid for specific cards demands it.
- **Atomic multi-speaker round generation** (one user message → all cast members reply in turn, queued). Possible quality-of-life add: hit "send" once and the system runs N speakers without manual prompting. Out of scope for §4.x but a natural follow-up.
- **Per-speaker chat templates.** If two cast members need different templates (rare), the workaround today is two solo chats. Adding per-speaker template selection is a 1-day change but adds significant prompt-pipeline complexity; defer unless requested.
- **Pruning unused cast members from history.** A "remove and rewrite" operation that deletes turns from a removed character. Risky / destructive; not needed for the MVP.
- **Director that picks 0 or N speakers.** Today director picks exactly one. Letting it return "no one — hand back to user" or "Anna and Sarah both" is a more capable router but a different UX shape.
- **Per-character chat-template override** (different system formatting per speaker). Templates are per-chat; this is a deeper refactor.
- **Backup-on-save throttled snapshots** (carried forward from Phase 7's deferred list). Group chats raise the blast radius of a bad migration further; the backup story is now overdue. Flag as a Phase-9 item.
