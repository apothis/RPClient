# RPClient V2 Phase 7 — Full branching design doc

**Status: draft, awaiting sign-off.** See [`V2_PLAN.md`](V2_PLAN.md) §3 for the parent plan entry and the five settle-before-coding decisions this doc expands on.

## Why

Today's chat is a flat `[Turn]`. Swipes (Phase 2) added in-Turn alternatives — `Turn.variants: [TurnVariant]` — but only for the trailing assistant turn. There is no way to fork the conversation at an earlier point; "regenerate from turn N" is destructive (the current path forward is lost) and the swipe model can't represent it.

Phase 7 makes the chat history a tree. Forking from any turn becomes non-destructive — old paths remain discoverable. The data model swap is small (one `parentId` field, one `activePath` array). The hard part is the memory subsystem, which today indexes everything by `turnIndex: Int` and needs to switch to turn IDs so the retrieval / scene-summary machinery survives a branch switch.

## 1. Scope

**In scope (sub-steps §3.1 → §3.4):**

- Data-model migration of existing chats to a "spine tree" (parent = previous turn, single active path equal to the existing turn order).
- Memory-subsystem migration from `turnIndex: Int` to `turnId: UUID` across `SceneSummary`, `Chunker`, `Chunk`, `VectorStore`, `RetrievalEngine`, and the relevant `AppState` invalidation paths.
- Fork-on-regen semantics for non-trailing assistant turns (trailing-turn regen still appends a variant — see §4).
- Gutter glyph + Cmd-B + Branches inspector pane.

**Out of scope (this phase):**

- Collapsing `Turn.variants` into first-class branch siblings — kept as an optional §3.5 once the branching model is proven. Variants stay within a Turn; branches sit between Turns. The user-facing label can hide the distinction; the storage layer still has both.
- "Prune dead branches" / branch garbage collection. Storage grows monotonically with forks. Add a cleanup action later if it becomes a concern.
- Visual minimap (true tree visualisation). The gutter glyph + sidebar pane is the MVP UI — see §5.4.
- Cross-branch operations (e.g., "merge facts learned in branch A into branch B's memory"). Each branch has its own scene summaries / retrieval set; switching branches narrows the retrievable chunk set to those whose endpoints lie on the new path. Cross-branch synthesis is a research item, not engineering.
- Per-turn provenance tracking (which world-info entries / memory facts fired for this turn). Useful debugging affordance — see KoboldAI United's `wi_highlighted_text` per-action — but a separate concern from branching. Add when there's a debug story for it.
- Throttled timestamped backups on every chat save. SillyTavern does this and it's a real correctness win once chats grow trees of branches; we don't have it today and Phase 7 doesn't add it. Flag for follow-up — the larger blast radius of a bad migration on a branching chat raises the value.

## 1.5 Prior art

Surveyed at the source-code level (not just docs) before finalising this design. Three tiers of relevance:

**Snapshot-per-branch** (what we explicitly don't do). SillyTavern's `public/scripts/bookmarks.js` (swipes inline + checkpoints + branches via deep-clone-and-truncate, single-parent `main_chat` pointer, flat chat-list UI, no tree). KoboldCpp Lite (`klite.embd`, 6-deep stack of full `gametext_arr` snapshots, memory global). KoboldAI United (`koboldai_settings.py`, `actions[idx].Options[]` per slot with `{Pinned, Previous Selection, Edited}` flags). Big-AGI (`store-chats.ts`, `branchConversation` = `duplicateDConversation` truncate-and-clone). Oobabooga (per-turn `versions[]` for swipes; "Branch" button slices history into a new chat). All defensible at their scale and complexity ceiling; all run out of road for shared-prefix storage and per-branch memory.

**In-place tree with parent pointers** (what we do — production references exist).

- **Open WebUI** (`src/lib/components/chat/{Messages,Chat}.svelte`, `Overview/Flow.svelte`) is the closest production match. Single document per chat, `history.messages[id] = { parentId, childrenIds[], ... }` + `history.currentId` for the active leaf. Sibling pager (◀ N/M ▶) on every message; **also** a real SvelteFlow-based tree minimap. Memory is global, not per-branch. Regenerate and edit both **fork** (append sibling under same parent — never destructive). Worth borrowing: when switching siblings, auto-drill to that subtree's deepest descendant rather than landing on the sibling itself (`Messages.svelte:179`). Worth not borrowing: maintaining both `parentId` *and* `childrenIds` has caused data-integrity bugs (Issue #15189) — pick one source of truth and derive the other.
- **LibreChat** (`packages/data-schemas/src/schema/message.ts`, `api/server/utils/import/fork.js`) stores `parentMessageId` per message in MongoDB; children computed on read. "Fork" = deep-copy into a NEW conversation (so it's snapshot-shaped at the API level even though messages are tree-shaped at the storage level), with three scope modes: `DIRECT_PATH` / `INCLUDE_BRANCHES` / `TARGET_LEVEL`. The three-mode taxonomy is a useful UX vocabulary even though we apply it to in-place views, not to fork-as-new-conversation. Their fork UX is widely reported as confusing (Discussion #2908) — three modes without good visual feedback.
- **ChatGPT** (closed, but the export format leaks the model): `mapping: { id: { parent, children[], message } }`. Real tree internally; UI is sibling pager only, no minimap. Edit forks.
- **TypingMind** (closed, docs at `typingmind.com/docs/chat-management/fork-chats`): "Fork chat from here" + per-message version threads on edit/regenerate.

**Per-branch state via inheritance** (what's novel for us — the only direct prior art is research-tool-shaped).

- **Loom** (`socketteer/loom`, `model.py`) — single-user Tk desktop app for "cyborg" writing. Flat `tree_node_dict[id] = { parent_id, children, text, meta }` + a **frames** mechanism: per-node dict updates that cascade through ancestry. "The state of the tree is the accumulation of all frames from its ancestry, applied in chronological order." That's exactly the conceptual anchor for our per-branch memory state — we just transpose it from arbitrary node metadata to scene summaries / chunks indexed by turn IDs. Loom also ships a real visual tree minimap (visualize mode) and a "read mode" that linearises the active path. Nothing about Loom is directly portable to AppKit, but the data-model decisions are validating.
- **Academic** (referenced for completeness, not actionable): *Conversation Tree Architecture* (arxiv 2603.21278) describes per-node local context windows with parent→child flow rules. *ContextBranch* (arxiv 2512.13914) formalises checkpoint/branch/switch/inject primitives. *Task Memory Engine* (arxiv 2504.08525) does per-node prompt synthesis on the active path. All describe variants of what we're building; none ship as code.
- **SillyTavern-Timelines** (community extension, not core ST) merges identical messages across checkpoint files at matching depths into one DAG node — unified tree across snapshots. Worth studying if we ever want a "show me all branches across this character" overview, but not Phase 7.

**What we borrow:**

- Open WebUI's `parentId` + `currentId` model (almost identical to our `parentId` + `activePath`-leaf). Production-validated.
- Open WebUI's **drill-to-deepest-descendant** when switching siblings — already in our `switchBranch(to:)` design via `activeChildId` walk.
- **Cycle detection from day one** — both Open WebUI (`Messages.svelte:92`) and LibreChat (`fork.js:184, :256`) have explicit guards. Cheap to add at decode time; expensive when missing.
- **Single source of truth for the parent/child relation.** Our `Turn.parentId` only — children derived via the turn-by-id index. Open WebUI's redundant `childrenIds` is the cautionary tale.
- **Loom's "frames" as the design metaphor** for per-branch memory: each branch sees the accumulation of ancestry-applicable state (scene summaries with `lastTurnId` on path, chunks whose endpoints are on path), nothing else. Phase 7's per-branch memory is "frames specialised for memory" — same shape, narrower scope.
- **Fork-on-edit as the default**, not a separate affordance. Open WebUI / ChatGPT / TypingMind all do this. Our regen-on-non-trailing-turn is the same pattern.

**Where we go beyond prior art:**

- **Per-branch rolling summary / scene memory.** Nobody in production does this. Loom does it for arbitrary node metadata via frames; we do it specifically for the rolling-summary + chunk-store machinery. Plan extra smoke-testing — there's no working reference for the gnarly bits in §3.2.
- **Native AppKit tree UI, including a visual minimap.** Open WebUI's minimap uses SvelteFlow (mature, off-the-shelf). AppKit has no equivalent, so we build a custom layered top-down layout in CoreGraphics + `NSView` (§3.5). Chat trees are narrow enough (typically <500 nodes, low branching factor) that a generic graph-layout library would be overkill. Open WebUI's `Overview/Flow.svelte` is the reference for the visual + interaction language.

**What we explicitly skip:**

- ST's "checkpoint" (snapshot but stay in current chat) — multi-user-web-app affordance; for a single-user macOS app, "mark a point" and "navigate back to it" are the same operation, which is just a branch.
- ST/Kobold's full-file-copy snapshot storage — fine at their scale, wasteful when one user can run dozens of branches per chat over years.
- Kobold's global memory across branches — we can do better, and our turn-id-indexed memory does.
- LibreChat's three fork-scope modes as user-facing options — useful as internal vocabulary, but exposing all three caused real UX confusion. Pick one default behaviour (in-place fork that drills to leaf), surface the others only if a need emerges.

## 2. Data model

### 2.1 Schema additions

```swift
struct Turn: Codable, Identifiable, Equatable {
    let id: UUID
    var role: TurnRole
    var text: String
    var edited: Bool
    var ts: Date
    var variants: [TurnVariant]
    var activeVariant: Int

    // Phase 7 additions
    var parentId: UUID?              // nil only on the root turn (turn 0)
}

struct Chat: Codable, Identifiable, Equatable {
    // existing fields...
    var turns: [Turn]                // unchanged: still the storage of all turns
    var activePath: [UUID]           // Phase 7: ordered root → leaf
                                     // renderable list = activePath.compactMap { turnsById[$0] }
}
```

`Chat.turns` stays as the storage. **It's no longer the renderable list** — that's now derived from `activePath`. Existing call sites that walk `chat.turns` need triage during §3.1: either they want "all turns ever" (chunker for re-indexing? probably not) or "the visible chat" (most callers — switch to `chat.activeTurns`).

Helper API on `Chat` (added in §3.1):

```swift
extension Chat {
    /// Renderable in-order list of turns following the active path.
    /// Use this everywhere the old `chat.turns` was treated as "the visible chat."
    var activeTurns: [Turn] { activePath.compactMap { turn(id: $0) } }

    /// Stable lookup by id. O(1) via a derived dict; rebuilt on `turns` mutation.
    func turn(id: UUID) -> Turn?

    /// Position of `turnId` along `activePath`, or nil if not on the current path.
    /// The replacement for "turn index" in the new world.
    func activePosition(of turnId: UUID) -> Int?

    /// All turns whose `parentId` matches this turn's id. Used for sibling
    /// glyph rendering and the Branches pane.
    func children(of turnId: UUID) -> [Turn]

    /// Switch to the branch identified by `turnId`. Truncates `activePath`
    /// at the parent of `turnId`, pushes `turnId`, then walks down its
    /// most-recently-active descendant chain.
    mutating func switchBranch(to turnId: UUID)
}
```

The `turn(id:)` lookup wants to be O(1). Stash a derived `[UUID: Int]` index on `Chat`; rebuild on any mutation that changes `turns`. Not persisted — recomputed on decode.

### 2.2 Migration

`Turn.parentId` decodes via `decodeIfPresent` → `nil` for legacy chats. `Chat.activePath` decodes via `decodeIfPresent` → `nil`. In `Chat.init(from:)`, after `turns` is decoded:

```swift
if activePath == nil {
    // Legacy "spine" chat: assign each turn's parent = previous turn,
    // activePath = turn order.
    for i in turns.indices {
        if turns[i].parentId == nil {
            turns[i].parentId = i > 0 ? turns[i - 1].id : nil
        }
    }
    activePath = turns.map(\.id)
}
```

Idempotent: a chat that's already been migrated keeps its `parentId`s and `activePath` untouched. A chat that's been hand-edited to remove `activePath` re-derives the spine.

**Validation in decode** (defensive — these shouldn't happen but if they do we want a clear failure mode):

- Every turn's `parentId`, when non-nil, points to a turn that exists in `turns`.
- `activePath` is a connected chain — each `activePath[i+1]`'s `parentId == activePath[i].id`.
- Exactly one turn has `parentId == nil` (the root).
- **No cycles.** Walking the `parentId` chain from any turn must reach the root in finite steps. A trivial check at decode time: count the `parentId` walks; if any walk exceeds `turns.count`, there's a cycle. Both Open WebUI and LibreChat have explicit cycle guards in production (`Messages.svelte:92`, `fork.js:184/256`); cheap to add at decode and prevents whole classes of infinite-loop bugs in `switchBranch` / `children(of:)` / scene-summary resolution.

If validation fails, throw a `DecodingError` with enough context to diagnose (which turn, which rule). Don't silently repair — corrupted branching state is something the user should hear about.

### 2.3 Active-path semantics

`activePath` is the user's "current view" of the chat. It's persisted explicitly so re-opening a chat lands on the same branch the user was reading. It's NOT derived from any "most recent" rule — those games (last-modified-turn-wins, etc.) get confusing fast in a tree.

Rules:

- **Root is always the same turn** — turn 0 (or the seeded greeting from a character card). Forking happens below the root.
- **Active path always reaches a leaf.** When you switch to a turn that has descendants, walk down the most-recently-active descendant chain to a leaf (each Turn remembers `activeVariant: Int` for swipes; we add `activeChildId: UUID?` for branches in §3.1).
- **Forks lengthen `activePath`.** Trailing-turn regen → variant added inside Turn (path unchanged). Non-trailing regen → new child Turn forked off the parent → `activePath` truncates after the parent and pushes the new turn.
- **Switching branches rewrites `activePath`** from the divergence point onward. The pre-switch path is recoverable via `Turn.activeChildId` updates if we want it; for §3.1 we just rewrite without preserving "last seen" state per fork point. Add stickiness later if the UX needs it.

`Turn.activeChildId: UUID?` on each Turn (§3.1 addition) records the most recently selected child so descend-to-leaf is deterministic. Defaults to `children(of: turn).first?.id` when unset. Persisted.

## 3. Memory subsystem migration

The biggest part of Phase 7. Today everything in memory uses `turnIndex: Int` into `chat.turns`. Branching breaks indices: turn 5 in branch A is not turn 5 in branch B. Every consumer of `turnIndex` has to switch to `turnId: UUID` and resolve the index lazily against the current active path.

### 3.1 Index → ID migration map

| Today | After Phase 7 |
|---|---|
| `SceneSummary.firstTurn: Int?` | `firstTurnId: UUID?` |
| `SceneSummary.lastTurn: Int?` | `lastTurnId: UUID?` |
| `Chunk.firstTurnIdx: Int` | `firstTurnId: UUID` |
| `Chunk.lastTurnIdx: Int` | `lastTurnId: UUID` |
| `Chunk.id` derived from `chatId-firstIdx-lastIdx` | derived from `chatId-firstUUID-lastUUID` |
| `VectorStore.invalidate(turnIndices: Set<Int>)` | `invalidate(turnIds: Set<UUID>)` |
| `VectorStore.clampToTurnCount(_:)` | `clamp(toTurnIdsPresent: Set<UUID>)` |
| `RetrievalEngine.preFilter(turnsCount:summarizedThrough:)` recency math | takes `chat: Chat`, computes positions via `activePosition(of:)` |
| `Chunker.chunks(for chat:)` walks `chat.turns` | walks `chat.activeTurns` |
| `AppState` scene-break uses `prevLast: Int` | uses `prevLastId: UUID?` resolved via `activePosition` |

### 3.2 SceneSummary

```swift
struct SceneSummary: Codable, Equatable {
    var text: String
    var firstTurnId: UUID?
    var lastTurnId: UUID?
}
```

**Decode tolerates legacy `Int?` keys** (`firstTurn`, `lastTurn`). Resolution requires the chat's `turns` array, which `SceneSummary` doesn't have at decode time. Two-pass:

1. Custom `SceneSummary` decoder reads either old or new keys; if it sees old `Int?`, stashes them in a private `legacyFirstTurn`/`legacyLastTurn` ivar (transient, not encoded).
2. After `Chat.init(from:)` finishes decoding `turns` + `activePath`, post-process: for each scene whose UUIDs are nil but whose legacy ints are set, resolve `legacyFirstTurn → activePath[idx]`. Save back into `firstTurnId`/`lastTurnId`. The post-processed shape is what re-saves; legacy ints are dropped after one round-trip.

The chat at decode time is a "spine tree" (pre-branching), so `activePath[idx]` is unambiguous. Out-of-bounds legacy ints → leave UUIDs as nil (matches today's tolerance for `[String]` legacy summaries).

`AppState.maybeBreakScene` (the writer, in `AppState.swift:1087`) switches from:

```swift
let prevLast = c.sceneSummaries.last?.lastTurn ?? -1
let firstTurn = max(0, prevLast + 1)
let lastTurn = max(firstTurn, c.summarizedThrough - 1)
```

to:

```swift
let prevLastId = c.sceneSummaries.last?.lastTurnId
let prevLastIdx = prevLastId.flatMap { c.activePosition(of: $0) } ?? -1
let firstIdx = max(0, prevLastIdx + 1)
let lastIdx = max(firstIdx, c.summarizedThrough - 1)
let firstTurnId = c.activePath[safe: firstIdx]
let lastTurnId = c.activePath[safe: lastIdx]
```

`summarizedThrough: Int` becomes **derived, not persisted.** Today it's a single counter on `Chat` that doesn't know about branches — switching from a long branch to a short branch and back would either lose the value (if clamped) or read out of bounds (if not). The right model: derive it from `chat.sceneSummaries.last?.lastTurnId` resolved against the current active path. If the latest scene summary's `lastTurnId` is on the active path at position N, then `summarizedThrough = N + 1` (next unsummarized turn). If not on the active path (latest summary is from a different branch), walk backwards through `sceneSummaries` to the most-recent one whose `lastTurnId` IS on the current path. If none, `summarizedThrough = 0`. Naturally per-branch by construction; nothing to clamp on branch switch. Drop the persisted `Chat.summarizedThrough` field entirely and replace with a computed property `Chat.summarizedThrough(forActivePath:)`. Migration: ignore the legacy persisted value on decode.

### 3.3 Chunker / Chunk / VectorStore

```swift
struct Chunk: Codable, Equatable {
    let id: String
    let chatId: UUID
    let firstTurnId: UUID
    let lastTurnId: UUID
    var text: String
    var embedding: [Float]?
    var embeddedAt: Date?
    var contextBlurb: String?

    init(chatId: UUID, firstTurnId: UUID, lastTurnId: UUID, text: String) {
        // ...
        self.id = "\(chatId.uuidString)-\(firstTurnId.uuidString)-\(lastTurnId.uuidString)"
    }
}
```

**Migration of persisted `<chatId>.vec.json`:** chunk decoder tolerates both old (`firstTurnIdx`/`lastTurnIdx`: Int) and new (`firstTurnId`/`lastTurnId`: UUID) keys. Like SceneSummary, the resolution requires the chat's `turns`. Two options:

(a) **Lazy migration.** On chat load, after `Chat` is decoded, the `VectorStore`'s legacy-Int chunks get resolved against `activePath` and re-persisted. Old chunks become unreachable until that resolution runs. Cost: ~one extra VectorStore.save per chat on first load post-upgrade.

(b) **Drop legacy chunks.** `VectorStore.load` treats legacy-Int chunks as expired and discards them. Re-embedding repopulates over the next few turns. Cost: a brief retrieval-quality drop after upgrade.

**Lean: (a).** Chunks are expensive to recompute (each one is a side-call embedding); preserving them is worth the small migration cost. The migration runs once per chat per upgrade.

`Chunker.chunks(for chat:)` walks `chat.activeTurns`, not `chat.turns`. Window/stride logic unchanged; `firstTurnIdx`/`lastTurnIdx` becomes `firstTurnId`/`lastTurnId` (the IDs of the turns at those positions in the active path).

`VectorStore.invalidate(turnIds:)` drops chunks whose `firstTurnId`...`lastTurnId` range covers any modified turn. "Range" for branching: a chunk's range is the inclusive set of turn IDs it was indexed against — those are recoverable from the chunk's `firstTurnId`/`lastTurnId` *if and only if* both endpoints lie on the current active path (then walk activePath between them). For chunks whose endpoints are off-path (chunk indexed against branch A while we're on branch B), the chunk is still useful when we switch back to A but irrelevant now — see §3.5.

`VectorStore.clamp(toTurnIdsPresent:)` drops chunks whose endpoint IDs are no longer in `chat.turnsById` at all (truly deleted turns). Does NOT drop chunks whose endpoints are on a different branch — those become reachable again on branch switch.

### 3.4 RetrievalEngine recency math

```swift
// Today
static func preFilter(turnsCount: Int, summarizedThrough: Int) -> (Chunk) -> Bool {
    let recencyCutoff = turnsCount - recencyExclusion
    let verbatimCutoff = summarizedThrough
    return { chunk in
        chunk.lastTurnIdx >= recencyCutoff
            || chunk.lastTurnIdx >= verbatimCutoff
    }
}

// After Phase 7
static func preFilter(chat: Chat, summarizedThrough: Int) -> (Chunk) -> Bool {
    let pathCount = chat.activePath.count
    let recencyCutoff = pathCount - recencyExclusion
    let verbatimCutoff = summarizedThrough
    return { chunk in
        guard let lastIdx = chat.activePosition(of: chunk.lastTurnId) else {
            // Chunk's endpoint is off the current branch — exclude it from
            // the recency/verbatim filter (i.e., it survives, gets scored
            // by similarity like any other historical chunk).
            return false
        }
        return lastIdx >= recencyCutoff || lastIdx >= verbatimCutoff
    }
}
```

The pre-filter today *excludes* chunks (returns true to drop them). Off-path chunks should remain retrievable — they represent prior conversation in a different branch, which is exactly the kind of memory retrieval is for. They get scored by cosine similarity like any other historical chunk and only surface if they're a strong match. This is the right behaviour by default; flag if it bites in practice.

### 3.5 Branch-aware invalidation policy

The default invalidation rule today: "edit a turn → drop chunks that overlap." Under branching:

| User action | Invalidate? |
|---|---|
| Edit text of turn T | Drop chunks whose range covers T (whether or not T is on the active path — the edit changes what was said). |
| Switch active branch | Don't drop anything. Off-path chunks just stop being recency-eligible. |
| Fork a new branch (regen non-trailing) | Don't drop anything. The new branch hasn't produced any chunks yet. |
| Delete a turn outright | `clamp(toTurnIdsPresent:)` drops chunks pointing to it. |

Edits-on-non-active-branch are uncommon (the UI doesn't really invite them — you have to switch to the branch first). But the rule is the safe default: chunk text changed → drop chunk → re-embed.

## 4. Regen semantics — fork is always sibling-add

Today, `AppState.regenerate()` operates on the trailing assistant turn:

- If `Turn.variants.count < cap`, append an empty variant + stream into it. `activeVariant = variants.count - 1`.
- The old variant remains accessible via swipe-left.

After Phase 7:

- **Trailing assistant turn → variant add (today's behaviour preserved).** No new branching needed; swipes already give us alternatives. Don't fork unnecessarily — that'd inflate tree depth for what users perceive as the same operation.
- **Non-trailing assistant turn → fork.** New child Turn created, parent = the non-trailing turn's `parentId`. `activePath` truncates after parent, pushes the new turn. Streaming proceeds into the new turn. Old path (the previous child + its descendants) remains discoverable.
- **User turn → not regenerable.** (Same as today — there's nothing to regenerate.)

UI label: a single "Regenerate" affordance on assistant turns. The user doesn't need to distinguish "swipe" from "fork" mentally — the data layer handles it. Cmd-Shift-R (destructive replace) is retired entirely under branching: there's no need to destroy when forking is free.

**Cmd-B (explicit fork from current turn).** Forks the *parent* of the focused turn — i.e., creates a new sibling of the focused turn, sets it as active, and starts streaming into it. Makes "I want a different reply here" a single keystroke without the swipe-or-regen choice. Disabled on the root turn (no parent to fork from).

## 5. UI surface

### 5.1 Gutter glyph

Each turn whose `Turn.parentId`'s children count is > 1 gets a glyph in the gutter (left margin of the turn). Click → popover with siblings (first-line preview + relative timestamp). Selecting a sibling = `chat.switchBranch(to: siblingId)`.

Choice of glyph: `arrow.triangle.branch` (SF Symbol) at the secondary label colour, 12 px. Subtle by default, slightly emphasised on hover. NOT shown when a turn has no siblings — keep the gutter clean for the common case.

### 5.2 Branches sidebar pane

New inspector pane "Branches" (alongside Memory, World Info, Entities). Lists every leaf in the chat's tree, plus the divergence point and first-line preview of each. Click → switches to that branch.

Layout sketch:

```
Branches (4)
─────────────────────────────────────
● Active        T6 — "She nodded slowly."
                forked at T3

  Branch B      T5 — "He turned away."
                forked at T3

  Branch C      T8 — "—"
                forked at T5

  Branch D      T4 — "Wait!"
                forked at T2 (root)
```

Each row shows: leaf turn id (short), first ~40 chars of leaf text, divergence-point summary. The active branch is marked with `●`.

Sort: newest leaf first (most recently active). Active branch always pinned to top regardless of recency.

Branches with no leaf preview text (mid-stream interrupted, etc.) show "—" in the preview slot; clicking still works.

### 5.3 Cmd-B fork action

Global keyboard shortcut. Forks the parent of the currently focused turn (if any), starts streaming into the new sibling. If no turn is focused, fall back to forking the parent of the trailing turn (i.e., behaves like "give me an alternative for the most recent reply").

### 5.4 What this UI does NOT do

- **(Visual minimap shipped in §3.5, not deferred.)** §3.4's Branches sidebar pane is the list view that lands first; §3.5 adds the graph view as the upgrade. AppKit lacks a SvelteFlow equivalent so we build the layout ourselves (~200 LOC, layered top-down — chat trees are small enough that a graph-layout library would be overkill). See §3.5 for details.
- **No drag-drop branch reorganisation** (re-parenting a subtree). Out of scope; the cases where this is useful are rare enough that "delete + regen on the right parent" is acceptable.
- **No branch naming.** Branches are identified by leaf preview only. Add naming if a user explicitly asks for it.
- **No "compare two branches side by side" view.** Out of scope.

## 6. Sub-step contracts

### §3.1 — Data model + path helpers ✅ shipped 2026-05-06

**In:** `Turn.parentId: UUID?`, `Turn.activeChildId: UUID?`, `Chat.activePath: [UUID]`. Migration in `Chat.init(from:)`. Helpers `Chat.activeTurns`, `turn(id:)`, `activePosition(of:)`, `children(of:)`, `switchBranch(to:)`, plus internal turn-by-id index. Validation in decode.

**Tests (TDD):** at least the following pure tests in `ChatBranchingTests`:

- Legacy chat (no `parentId`, no `activePath`) decodes to a spine tree: every turn's parentId is the previous turn's id, activePath equals the original turn order.
- Round-trip preserves `parentId` and `activePath`.
- `activeTurns` returns turns in `activePath` order.
- `turn(id:)` is O(1) (verified by checking the index dict exists and is queried, not by timing).
- `activePosition(of:)` returns the right index for path turns, nil for off-path turns.
- `children(of:)` returns siblings sorted deterministically (creation order — by `ts`).
- `switchBranch(to:)` truncates and rebuilds activePath correctly; descends via `activeChildId` when unset (uses first child).
- Validation throws on disconnected `activePath`, dangling `parentId`, multiple roots.
- Migration is idempotent: applying twice is a no-op.

**Out:** UI changes (zero — data layer only). Memory subsystem migration (separate sub-step). Fork affordances.

**Effort:** ~1 day. Most of it is the helper API + migration tests; the type additions are a few lines.

### §3.2 — Memory subsystem migration

**In:** `SceneSummary.firstTurnId`/`lastTurnId`, `Chunk.firstTurnId`/`lastTurnId`, `VectorStore.invalidate(turnIds:)` + `clamp(toTurnIdsPresent:)`, `Chunker.chunks(for:)` walks `activeTurns`, `RetrievalEngine.preFilter(chat:summarizedThrough:)`, `AppState.maybeBreakScene` ID conversion. Two-pass legacy decoding for both SceneSummary and Chunk. Migration of persisted `<chatId>.vec.json` files (lazy on first load post-upgrade).

**Tests (TDD):**

- Legacy SceneSummary JSON (`firstTurn: 3, lastTurn: 7`) decodes, then post-migrate resolves to UUIDs from a spine-tree chat. Round-trip after migration drops the legacy keys.
- Legacy Chunk JSON (`firstTurnIdx: 3, lastTurnIdx: 7`) decodes; post-migrate resolves to UUIDs. Chunk.id is recomputed from new UUIDs and stable across reloads.
- `VectorStore.invalidate(turnIds:)` drops chunks whose range covers any of the given IDs (range computed via active-path resolution).
- `VectorStore.clamp(toTurnIdsPresent:)` drops chunks whose endpoint IDs are not in `chat.turnsById`.
- `RetrievalEngine.preFilter` excludes chunks within recency window when both endpoints are on path; off-path chunks pass the filter (don't get excluded by recency).
- Chunker walks active path: a chat with two branches generates chunks only for the active branch's turns.
- `AppState.maybeBreakScene` produces SceneSummaries with correct `firstTurnId`/`lastTurnId` matching the active path positions.

**Out:** Branch-switch invalidation (none — chunks survive branch switches; only edits/deletes invalidate). The UI doesn't change.

**Effort:** ~2-3 days. Files touched: ~8. Migration test fixtures the riskiest part.

### §3.3 — Fork-on-regen + gutter glyph + Cmd-B

**In:** `AppState.regenerate()` branches by trailing-vs-not. New `AppState.forkFrom(turnId:)` API for explicit fork. Gutter glyph in `TurnView` when `chat.children(of: turn.parentId).count > 1`. Cmd-B keyboard shortcut → `forkFrom(turnId:)` of focused turn's parent (or trailing turn's parent as fallback). Sibling popover on glyph click.

**Tests:**

- Pure: `Chat.fork(parentId:newTurnId:)` produces a new sibling, updates `activePath` correctly. (Method on Chat for testability; AppState wraps with streaming.)
- Pure: `Chat.switchBranch(to:)` round-trip — switch away and back lands on the same path.
- Smoke: regen on trailing turn appends variant (today's behaviour, regression test).
- Smoke: regen on non-trailing turn forks; UI shows the new branch.
- UI smoke: gutter glyph appears when siblings exist, doesn't appear otherwise.

**Out:** Branches sidebar pane (next sub-step). "Prune dead branches" action. Branch naming.

**Effort:** ~1-2 days.

### §3.4 — Branches sidebar pane

**In:** New `BranchesPane` in the inspector. Walks `chat.turns` to find leaves (turns with no children), renders the rows per §5.2. Click → `chat.switchBranch(to: leafId)`. Subscribes to `currentChatChanged` and a new `chatTreeChanged` notification (post on fork / branch switch / turn delete).

**Tests:**

- Pure: `BranchesView.leaves(of: chat)` returns all leaf turns in the tree.
- Pure: `BranchesView.divergencePoint(of: leafId, against: activePath)` returns the lowest common ancestor between the leaf's path-to-root and the current active path.
- UI smoke: pane appears in inspector tab list; clicking a row switches the chat.

**Out:** Visual minimap. Branch reorganisation. Branch naming. Compare-branches view.

**Effort:** ~1 day.

### §3.5 — Visual tree minimap

**In:** A graph view of the chat's full tree, rendered in a new "Tree" tab in the inspector (alongside Branches, Memory, Entities, World Info). Each node = a Turn, drawn as a small rectangle with role glyph + first-line preview (truncated to ~24 chars). Edges follow `parentId`. Active path highlighted (thicker edge, accent colour); active leaf glows. Clicking a node calls `chat.switchBranch(to: nodeId)` and drills to that subtree's leaf (same drill-to-deepest-descendant rule as `switchBranch(to:)`). Hover surfaces a tooltip with the full first sentence + timestamp. Pan / zoom (trackpad gestures); fit-to-window button.

**Layout algorithm:** for chat trees (typically <500 nodes, low branching factor — most users won't have more than ~20 leaves per chat), a layered top-down layout works fine. Each node's `y` = its depth from root × row-height. Each node's `x` = its position in an in-order tree walk × col-width, with horizontal compression to keep siblings near each other. Implementable in ~200 LOC of CoreGraphics + a custom `NSView`. AppKit doesn't have a SvelteFlow equivalent so we build it; the chat-tree case is narrow enough that a graph-layout library would be overkill.

**Tests:**

- Pure: `MinimapLayout.layout(chat:rowHeight:colWidth:)` returns a `[UUID: CGPoint]` for any tree shape; covers a single linear chain, a single fork, a deeply nested fork-of-forks, and an empty chat.
- Pure: layout is stable — re-running on the same tree produces identical positions (deterministic).
- Pure: active-path detection — given a Chat, returns the set of edge pairs `(parentId, childId)` that are on the active path.
- Smoke: minimap renders against a real branched chat; clicking a node switches branches; pan/zoom works.

**Out:** Animated transitions when switching branches (would be nice, defer to UX polish). Drag-drop to re-parent (out of scope per §1). Saving minimap as image (no clear use case).

**Reference for "what good looks like":** Open WebUI's `Overview/Flow.svelte`. Their layout is SvelteFlow-driven; ours is custom-AppKit but the visual + interaction language should match (top-down layered, click-to-switch, hover preview).

**Effort:** ~3-4 days. The layout math is a half-day; the rest is `NSView` rendering, hit-testing, gesture wiring, and making it look right at different zoom levels.

### §3.6 (optional, deferred-by-default) — Collapse variants into branches

**Status: deferred unless we hit a real reason.** The data model lives with both `Turn.variants` (within-Turn alternatives) and parent/child between Turns. The conceptually clean version collapses these — every "alternative" is a sibling Turn. But it means re-binding ◀ ▶ swipe semantics to branch-sibling navigation, migrating every persisted chat with multi-variant Turns to multi-Turn siblings, and rewriting the trailing-turn regen behaviour. Big migration for not-much-user-visible-payoff — users haven't complained about the variant/branch distinction, and the storage layer hiding it from them works.

Decision when picked up: write a separate design doc (`V2_VARIANT_COLLAPSE.md`); don't bundle it with §3.1-§3.5.

## 7. Migration test strategy

Per §5.2 of [`V2_PLAN.md`](V2_PLAN.md), each phase that changes Chat / Settings shape ships its own migration tests. Phase 7 needs more than usual because:

- Chat shape changes (parentId, activeChildId, activePath).
- SceneSummary shape changes (Int? → UUID?).
- Chunk shape changes (Int → UUID).
- Persisted vec.json files need lazy on-load migration.

**Per-shape migration tests** in `ChatBranchingTests`, `SceneSummaryTests`, and `ChunkMigrationTests`:

- Legacy → new JSON round-trip.
- Legacy decode → mutate → re-save → re-decode preserves the migration.
- Mixed legacy / new fields tolerated.
- Validation failures throw with informative messages.

**One end-to-end fixture** (`Tests/MigrationFixtures/v6-spine-chat.json`, the directory we said we'd create lazily — Phase 7 is the lazy moment): a complete pre-Phase-7 chat with several scene summaries and a populated vec.json file. Test loads it via the production path (`AppState.openChat` or equivalent), asserts the in-memory shape, re-saves, asserts the on-disk shape matches the new schema. This catches anything the per-shape tests miss because they don't exercise the full load pipeline.

## 8. Decisions taken

All five originally-open questions resolved (signed off 2026-05-06). Recorded here so future-self / future-agent can trace why the implementation looks the way it does.

1. **`Turn.activeChildId` is persisted.** One UUID per Turn; descend-to-leaf is deterministic across sessions. Better UX than re-deriving "most recent child" on every load (loses stickiness when the user switches branches across sessions and expects to land where they left off).
2. **Cmd-B forks the focused turn's parent** — creates a sibling of the focused turn. Matches the gutter glyph + Branches pane semantics ("alternative to this turn"). Disabled on the root turn (no parent to fork from).
3. **Off-path chunks remain retrievable.** Cross-branch memory is exactly what retrieval is for — a sufficiently-similar past chunk should surface even if it lives on a branch the user isn't currently reading. Pre-filter only excludes by recency, and recency only applies when the chunk's endpoint is on the current path.
4. **`summarizedThrough` becomes derived, not persisted** — see §3.2 for the algorithm. Per-branch by construction; nothing to clamp on branch switch.
5. **Migration is lazy** (per chat on first open). Fast app launch, no work for chats the user never re-opens. Re-save eagerly after migration so we don't carry mixed-shape data on disk indefinitely.

## 9. Out-of-scope items to revisit later

- **Branch garbage collection.** Storage grows monotonically with forks. If a chat accumulates many dead branches, add a "Prune unused branches older than N days" action to the chat menu.
- **Branch naming.** Could be useful for long-running chats with several active explorations. Add when a user asks for it.
- **Cross-branch fact synthesis.** Each branch has its own scene summaries / facts. Synthesising "what's true across all branches" is research, not engineering — flag it if it ever becomes a need.
- **Variant collapse (§3.5).** As above.
- **Visual minimap.** As §5.4.

---

**Implementation sequence after sign-off:** §3.1 → §3.2 → §3.3 → §3.4. Each lands as its own commit (or small commit cluster) with passing tests + V2_PLAN status update. Smoke-test against a real branched chat before committing §3.3 and §3.4.
