# RPClient — what's next

Self-contained handoff doc. Open this in a fresh context to decide what to work on after the long-term memory subsystem (Steps A–D) shipped.

---

## State of the app (as of 2026-05-03)

A working native macOS roleplay client for koboldcpp. AppKit, programmatic UI, no Xcode (`./build.sh` + `./run.sh`). Core flows are in place:

- **Generation**: SSE streaming, Stop/Regen/Continue, Gemma + Qwen 3 templates, full sampler controls.
- **Chats**: persistent on disk, editable turns, multi-chat sidebar, per-chat sampler/template/author's-note overrides.
- **Memory subsystem (V2 done)**: pinned memory, scene summaries, rolling summary, structured entity store with selective injection, salience-ranked eviction, vector retrieval over chat history, fact-extractor with auto cadence + per-chat priority topics + suggestion queue, tail-reinforce, prompt-cache-aware layout. Shipped Steps A–D of [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md).
- **Telemetry**: prompt-cache ratio, TTFT, prompt-process time, tok/s, per-layer token usage, ctx fill bar.
- **TTS**: basic AVSpeechSynthesizer per chat.

What's still missing relative to [`PLAN.md`](PLAN.md) "non-goals" — these were V2 territory:

- SillyTavern character cards
- Branching / swipes (alternative continuations)
- Multiple servers
- Lorebook / world info UI (data model exists in `Models/WorldInfoEntry.swift`, no UI)
- Per-character voices
- Image / avatar rendering

---

## Pick one — options grouped by area

Each item has a rough size estimate (½ day / 1 day / 2-3 days / week+) and what it unlocks. None of these is forced — pick based on what's currently friction.

### A. Memory subsystem — polish & tuning (deferred from V2)

Captured in detail in [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md) "Open questions". The memory layers ship working but the user has explicitly asked for **a single focused tuning session**, not piecemeal patches.

| # | Item | Effort | Notes |
|---|---|---|---|
| A1 | **Holistic layer-interaction audit.** Map every fact's lifecycle across the six layers (pinned, scene, rolling, entities, retrieval, tail). Identify duplication, orphan paths, and "canonical layer when they disagree" rules. | 1 day write-up + ½ day fixes | Prerequisite for further polish; current behavior is a stack of accreted decisions, not a designed flow. |
| A2 | **Extractor under-emission of new attributes on known entities.** Small models read "entity is in Already Known" as "everything is known" and skip new attributes (age, clothing, etc.). First-pass mitigation already landed; needs eval to confirm + possibly stronger framing (split "facts to skip" vs "entities to enrich"). | ½ day eval, ½–1 day improvement | Catches the most common quality-of-extraction complaint. |
| A3 | **Memory-tab post-migration cleanup.** Pre-Step-C chats have facts duplicated in Memory + Entities. Add a one-click "this looks good — clear migrated lines from Memory" button that detects `[type] name — text` shape and removes only those. | ½ day | Removes the visible UX wart for users who upgraded. |
| A4 | **Selective-injection signal quality.** Substring match catches "Sage" the herb when the entity is "Sage" the character; misses pronoun-only references. Word-boundary matching is the easy win; per-entity `injectionMode` (always/keyword/never) is the proper fix. | 1 day | Quality bump on long chats with overlapping name tokens. |
| A5 | **Entity merge UI.** One-click merge for entities the user accidentally split (e.g. "Sage" and "Sage the Healer"). Today the workaround is editing aliases and deleting one card. | ½ day | Pure ergonomics. |
| A6 | **Suggestion fatigue.** Exact-string dedup misses paraphrased re-emissions. Embedding-similarity dedup is feasible (we have embeddings already). | 1 day | Worth it only if duplicates start annoying the user. |
| A7 | **Cross-chat persistent memory** (research §9.9). Same character carrying facts across chats. Out of scope until the within-chat story is solid. | 3-5 days | Unlocks "RP world" feel; large surface area. |
| A8 | **Multi-character voice/style block** (research §9.8). Per-entity voice/style, injected when the character is on stage. | 1-2 days | Independent of the entity work; could land any time. |

**Recommendation if picking from this group**: do **A1 first** (the audit) before starting A2–A8. The audit will likely change what A2/A4 should look like. The user has flagged this explicitly.

### B. Reply/UX features that aren't memory

| # | Item | Effort | Notes |
|---|---|---|---|
| B1 | **Swipes / alternative continuations.** Generate N alternative replies for the same prompt, store all, let the user pick or step through. Standard SillyTavern feature. Touches `Turn` model + InputBar UI + persistence. | 2-3 days | High-impact for RP — being able to reroll without losing the previous take is a quality-of-life leap. |
| B2 | **Edit-then-regen.** Selecting the assistant turn, editing it inline, then regenerating from that point — common mid-RP intervention. Today's regen drops the trailing assistant turn but doesn't preserve user edits. | 1 day | Smaller than B1; complements it. |
| B3 | **Reroll a span.** Highlight a sentence in the assistant turn, regen only that span. More invasive UI; needs a custom selection model. | 3-5 days | Niche but loved by power users. |
| B4 | **Branching.** Tree-of-replies model, not linear; each turn can have multiple children. Big data-model change. Unlocks proper RP exploration but commits the storage format to a tree. | week+ | Largest of this group. Worth a design doc before touching. |

### C. Worldbuilding surfaces

| # | Item | Effort | Notes |
|---|---|---|---|
| C1 | **Lorebook / world info UI.** `Models/WorldInfoEntry.swift` already exists; no UI binds to it. Trigger words that pull entries into the prompt when matched. | 2 days | Natural V2 feature; folds into the entity store conceptually but operates per-chat. |
| C2 | **SillyTavern character cards.** Import `.png` + `.json` cards (PNG-embedded V2 spec). Maps to `Chat.system` + `Chat.memory` + `Chat.authorsNote`. | 2-3 days | Lets users pick up community cards without retyping. Needs PNG metadata parsing. |
| C3 | **Avatar / image rendering.** Per-chat avatar in the sidebar, optional inline images in turns. | 1-2 days for sidebar avatar; week+ for inline | Cosmetic but polishes the app a lot. |

### D. Test coverage & developer ergonomics

| # | Item | Effort | Notes |
|---|---|---|---|
| D1 | **PromptBuilder.entitiesBlock tests.** Step C/D shipped without unit tests for selective injection or salience eviction. Worth backfilling — they're pure functions over `Chat`. | ½ day | Cheap insurance against memory regressions. |
| D2 | **Migration tests.** `Chat.migrateMemoryToEntities` has no coverage; one-time logic that can't easily be re-run. | ½ day | Pure function, easy. |
| D3 | **Eval harness for fact extraction.** Replay-style: snapshot of a chat → run extractor → diff vs. expected facts. Keeps small-model quality from drifting silently. | 1-2 days | Pays off if A2 (under-emission) becomes a recurring fight. |
| D4 | **`fewer-permission-prompts` skill pass.** Probably a few common build/run commands could be allowlisted. | 15 min | Quality of life for the human collaborator. |

### E. Chat-view UI overhaul (Open WebUI–style)

The user explicitly likes the way Open WebUI looks in the chat section and wants the chat view re-styled in that direction. Reference: [openwebui.com](https://openwebui.com), [docs.openwebui.com](https://docs.openwebui.com).

**Concrete properties of Open WebUI's chat view that distinguish it from the current RPClient look:**

| Property | Open WebUI | RPClient today |
|---|---|---|
| Column layout | Fixed max-width (~768px), centered with generous side gutters | Fills full chat-view width |
| User message | Right-aligned bubble, soft gray fill, rounded corners, no border | Bordered box with `controlBackgroundColor` fill, full-width |
| Assistant message | **No bubble** — plain prose, left-aligned, full column width, just markdown rendering with breathing room | Bordered box with `textBackgroundColor` fill, same shape as user |
| Avatar | Small assistant avatar/glyph at top-left of each assistant turn | None |
| Vertical rhythm | Large gap between turns (~32px), generous internal padding | Tight stack |
| Typography | ~16px body, comfortable line-height (~1.6), system font with care | Theme.font(13) default, dense |
| Code blocks | Distinct dark surface, language label + copy button at top-right, syntax highlighting | Markdown renderer styles them but no copy button / language pill |
| Message toolbar | Hover-revealed row under each message: copy, edit, regen, thumbs up/down, read-aloud, continue. Quiet when not hovered. | Always-visible Edit/Delete buttons embedded in the box |
| Streaming cursor | Subtle blinking caret at the end of the streaming token | Tokens append; no cursor |
| Empty state | Big centered greeting + suggested prompts | Empty chat list state only |
| Input bar | Pill-shaped, centered, soft shadow, mic + attach + send glyphs | Multi-row form with Send/Regen/Continue/Stop buttons |

**Files this touches** (all in `Sources/RPClientCore/UI/`):

- [`ChatViewController.swift`](Sources/RPClientCore/UI/ChatViewController.swift) — column constraints, vertical spacing, empty-state view, scroll behaviour.
- [`TurnView.swift`](Sources/RPClientCore/UI/TurnView.swift) — the big one. Split visual treatment by role: user gets a bubble, assistant doesn't. Hover toolbar replaces always-on edit/delete. Streaming caret. Markdown styling tweaks.
- [`Markdown.swift`](Sources/RPClientCore/UI/Markdown.swift) — code-block surface, language label, copy button, prose line-height.
- [`InputBar.swift`](Sources/RPClientCore/UI/InputBar.swift) — pill shape, glyph-only buttons with toolbar tooltips, centered alignment.
- [`Theme.swift`](Sources/RPClientCore/UI/Theme.swift) — bump default body size; add semantic colors (bubble fill, prose foreground, code surface, hover toolbar).
- [`ChatViewController.swift`](Sources/RPClientCore/UI/ChatViewController.swift) (again) — empty-state with suggested prompts when chat has no turns.

**Suggested phased approach** (each phase ships a working app):

| Phase | Scope | Effort |
|---|---|---|
| E0 | **Layout pass.** Centered max-width column, generous turn spacing, larger default body font. No role-specific styling yet. Just makes the chat breathe. | ½ day |
| E1 | **Role-specific turn treatment.** User = right-aligned bubble; assistant = plain prose, full column width, no border. Subtle assistant glyph at top-left. | 1 day |
| E2 | **Hover toolbar on each turn.** Copy / Edit / Regen / Continue / Delete reveal on mouse-enter, fade out on leave. Replace the current always-visible Edit/Delete. | 1 day |
| E3 | **Code block polish.** Surface color, language label, copy button. Touches `Markdown.swift`. | ½ day |
| E4 | **Streaming caret + small details.** Blinking caret at the streaming tail; smooth scroll-to-bottom; "scroll to latest" floating button when scrolled up. | ½ day |
| E5 | **Input bar redesign.** Pill shape, glyph buttons, send/stop merge into a single state-aware glyph. | ½ day |
| E6 | **Empty-state.** Big greeting + a row of suggested prompts pulled from `Settings` (e.g. last 4 used) when current chat has zero turns. | ½ day |

**Total: ~4-5 days for the full overhaul.** E0 alone delivers most of the visual relief; the user can stop after any phase and the app stays usable.

**Things to be careful of:**

- **Inspector pane and ctx bar should not feel out of place** after the chat is restyled. The right-side inspector panes (Memory, Entities, Suggestions, etc.) currently match the older dense style. Either restyle them in the same pass (large undertaking) or accept a deliberate split between "polished chat surface, dense control surface" — pick a posture before E0.
- **Dark mode parity.** Open WebUI's polish is dark-mode-first. Verify each phase in both light and dark; AppKit's semantic colors usually do the work but the bubble fill and code surface need explicit treatment.
- **Markdown re-render cost.** Plain-prose assistant turns may render via `NSAttributedString`; if streaming reflows the whole turn each token, performance gets worse than the current bordered-box layout. Test E1 with a long streaming reply before declaring the phase done.
- **Don't break editing.** Inline edit-in-place is the current behaviour and is good. Any new hover-toolbar Edit must drop into the same edit mode, not a sheet/modal.

### F. Multi-server / infrastructure

| # | Item | Effort | Notes |
|---|---|---|---|
| F1 | **Multiple servers / per-chat server.** Today there's one `Settings.serverURL`. Per-chat would let the user run a small local model for chat and a beefier remote for summarize/extract. | 2 days for per-chat picker; more for runtime swap | Useful as the user's local stack grows. |
| F2 | **Per-character voices** (TTS). Today TTS is a single voice per chat. Map entities → voices for narrated multi-character scenes. | 1-2 days | Low-priority but a unique feature. |
| F3 | **Search across chats.** Cmd-F across all chat histories, surface in a result list with click-to-jump. | 1 day | Becomes important once the user has dozens of chats. |
| F4 | **Export / import.** JSON or markdown export of a chat (including entities, summaries, AN) and re-import. | 1 day | Backup story, sharing story. |

---

## Recommended starting points (pick one, not all)

The user's last directive was "let's leave the memory stuff for now" plus "I really like the way Open WebUI looks in the chat section". Given that, the strongest non-memory candidates are:

1. **E0 → E1 (chat-view UI overhaul, first two phases)** — explicitly requested. Layout pass + role-specific turn treatment together deliver most of the visual relief in ~1.5 days. Stop here unless the user wants the full sweep through E2–E6. **Default recommendation if no other preference.**
2. **B1 (swipes)** — biggest user-visible quality-of-life win for an RP client. Plays well with existing `Turn` storage and the regen path; touches persistence + InputBar + chat view but no architectural shifts. Worth doing **after** E1 because the hover toolbar (E2) is the natural surface for swipe-prev/swipe-next controls.
3. **C1 (lorebook UI)** — closes the last "data model exists, no UI" gap. Smaller than swipes.
4. **D1 + D2** — backfill tests for Step C/D before any further changes. Defensive. Low effort. Sensible to slot in alongside whatever else is happening.

If the user's next session opens with "what's next?" and no other signal, propose **E0 + E1** first.

---

## Operational notes for a fresh context

- **Build**: `./build.sh` (release + ad-hoc codesign into `RPClient.app`).
- **Launch**: `./run.sh` — runs in-place via terminal so it inherits Local Network permission. **Do not** `open RPClient.app` (ad-hoc re-signing revokes TCC; model probes silently fall back to 4 K).
- **Tests**: `swift run RPClientCoreTests` (homegrown TestKit, not XCTest — Xcode isn't installed).
- **Source layout**: `Sources/RPClientCore/` (library: models, prompt, memory, UI panes), `Sources/RPClient/` (executable shim).
- **Docs to read first** (in priority order):
  1. [`PLAN.md`](PLAN.md) — original architecture + non-goals (now V2 candidates).
  2. [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md) — current memory subsystem design + open questions.
  3. [`MEMORY_RESEARCH.md`](MEMORY_RESEARCH.md) — the §9.x research that drove memory decisions.
  4. This file.
- **Memory architecture tl;dr**: see "How the layers interact" in [`MEMORY_V2_PLAN.md`](MEMORY_V2_PLAN.md). Six layers; Memory tab and Entities tab serve different roles (Memory = always-on, above cache boundary; Entities = selective, below boundary, salience-ranked). Memory tab is intentionally retained — see "Is the Memory tab still needed?" in the same doc.

### Recommended opening prompt for the new context

> Open `NEXT_STAGES.md`. The memory subsystem (Steps A–D) is shipped; the user wants to leave it alone for now and has asked for an Open WebUI–style chat-view overhaul. Start with phase **E0 + E1** (layout pass + role-specific turn treatment) unless I redirect. Build with `./build.sh && ./run.sh`. Tests: `swift run RPClientCoreTests`.
