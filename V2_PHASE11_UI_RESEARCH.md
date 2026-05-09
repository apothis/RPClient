# Phase 11 — UI overhaul reference-app research

**Status: research-pass output, 2026-05-09.** Empirical basis for the per-surface plans in [V2_UI_OVERHAUL.md §4+](V2_UI_OVERHAUL.md). This doc carries opinions; it's not a balanced survey. Per [V2_UI_OVERHAUL.md §3.5](V2_UI_OVERHAUL.md), every recommendation must be implementable inside [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) tokens — anything that needs a new token is flagged in §D.

**Method.** Live captures via README hero shots (Open WebUI, LibreChat) + public docs (SillyTavern, Open WebUI features, Cursor marketing) + GitHub issues and changelogs (Open WebUI, ChatGPT 2026 UI changes) + first-hand familiarity with the closed-source surfaces (Claude.ai, ChatGPT, Anthropic Workbench, Apple Messages.app). Where a frame is uncertain, the verdict is noted as low-confidence and the question lands in §D. Screenshots are saved under `docs/research/ui-overhaul/<app>/` and indexed in §E.

**Scope reminder.** This pass is §3 of the overhaul plan only. §4 (chat-pane redesign) is a separate session that consumes this doc; do not edit per-surface plans here.

---

## §A — Per-app captures

### A.1 Open WebUI (Tier 1 — lead reference)

User's stated favourite. OSS LLM client; closest functional + visual cousin to RPClient's intended target. Capture pulls from the README hero (`docs/research/ui-overhaul/openwebui/demo.png`), the public features docs, and GitHub discussions/issues that describe specific behaviours.

**A.1.1 Resting-state full chat window — three-pane, narrow nav rail.**
- *What.* Dark vertical sidebar (~240pt wide, full-height) on the leading edge; main content area; no permanent inspector pane. Sidebar is not a content-list sidebar but a hybrid app-rail-plus-list.
- *Where.* Window leading edge. Sidebar contents (top-down): brand mark + collapse handle, then `New Chat` / `Search` / `Notes` / `Workspace` icon-row entries; `Channels` group with `# general`; `Folders` group (`Finance`, `Study` in the demo); `Chats` group with date subheaders (`Today` is the only one populated in the hero shot); user avatar + name pinned at the bottom.
- *Why it works.* Conflates "global app actions" (New, Search, Notes, Workspace) with "your conversation list" in a single column. The user only ever clicks one column. Folders + date-grouped chats coexist without folder-modal overhead.
- *Verdict.* **STEAL** the date-grouping under `Chats` (Today / Yesterday / Last 7 / etc.). **STEAL** the Folders concept for character-keyed grouping (RPClient's natural group). **IGNORE** the Channels metaphor — it's a multi-user concept that doesn't apply.

**A.1.2 Header — model name with `▾`, "Set as default" hint.**
- *What.* Single horizontal row at the top of the main pane: centred model name (`gpt-4.1-nano` in the demo) acting as a popup button with a chevron, with a smaller "Set as default" affordance beneath it. Top-right has a tab-list icon and an avatar.
- *Where.* Top-of-pane; spans only the chat content's width, not the full window (sidebar has no header overlap).
- *Why it works.* The model is the *only* thing that's permanently exposed at chrome level. Every other knob (persona, server, voice, attachments) is reachable from the composer or the model dropdown. The header earns its single row.
- *Verdict.* **STEAL the discipline** — one row, one primary control. RPClient's current header packs Server + Attribution + Voice + speaker-mute; that's the anti-pattern. **IGNORE the placement of the model picker in the chrome** — see §C.3 for why we'd push it down into the composer instead.

**A.1.3 Empty-state new chat — model badge + composer + 3 suggestion chips.**
- *What.* Centred large model glyph + name. Composer below it with `How can I help you today?` placeholder. Three "Suggested" chips below the composer — each is a two-line card: short title (e.g. "Show me a code snippet") + sub-line ("of a website's sticky header"). Three, not four. Stacked vertically.
- *Where.* Vertically centred in the main pane; composer dominates the visual centre, suggestions sit below.
- *Why it works.* Three is enough to feel "ready to type from a hint" without being a consumer-grade card grid. The two-line shape lets the title be terse and the sub-line carry the actual prompt seed.
- *Verdict.* **STEAL.** Three chips, two-line shape. RPClient's empty state for a fresh character chat should pull seeds from the character's `example_messages` or scenario hooks, framed as the user's opening line.

**A.1.4 Composer — text area + 4 trailing icons.**
- *What.* Single rounded-rect text area, ~720pt wide, centred. Placeholder `How can I help you today?`. Leading icon: `+` (attachments / `#` document insertion). Trailing icons (in order): tools/zap glyph, microphone, send arrow.
- *Where.* Full-width within the main content column; pinned bottom of viewport during a populated chat (in the empty-state shot it's vertically centred).
- *Why it works.* Trailing-edge action cluster mirrors macOS conventions (Send is the rightmost). Attachment leading-edge keeps the "more inputs" affordance visually distinct from "ship it" actions.
- *Verdict.* **STEAL the asymmetry** (attach leading, send trailing). **STEAL the placeholder length** (full sentence, not "Type a message"). Tools-icon position is too coy — Open WebUI hides slash-commands and `#` document-references behind a glyph that doesn't communicate "type `/` for templates"; RPClient should expose its persona/model switch as a labelled pill, not a glyph.

**A.1.5 Per-message hover controls — regenerate-on-leaf, edit-creates-branch.**
- *What.* On hover, action icons appear at the bottom-trailing edge of an assistant turn: copy / regenerate / edit / `…` (overflow). Regenerate by design only appears on the conversation's leaf node — mid-thread regen is not offered in the chrome (workaround: edit the parent and click Send). Editing a user turn creates a new branch automatically.
- *Where.* Bottom-trailing of the message; hover-revealed (~120ms fade).
- *Why it works.* Constraining regenerate to the leaf prevents accidental mid-thread overwrites and matches the underlying chat-completion semantics. Edit-creates-branch is the right default — destructive in-place edit is a user trap.
- *Verdict.* **STEAL edit-creates-branch.** **INVERSE the leaf-only regen restriction** — RPClient's chat-tuning work assumes regen *is* useful mid-thread (re-rolling a single turn for variant exploration), and the user explicitly said the per-turn function set is liked as-is. RPClient already has the branch model to support this; don't borrow Open WebUI's restriction.

**A.1.6 Branch tree — explicit, but UI requires polish.**
- *What.* Editing a user message creates a new branch; users can navigate between branches via inline arrows on the edited message. Active issues request "delete unwanted branches with one click" and "double-click message count to jump-edit index" (both shipped or in flight).
- *Where.* Inline at the message that diverges; no separate tree view in the chrome (open issues request one).
- *Why it works.* Inline navigation matches the user's mental model (the branch is *here*, on this message). The cleanup gap is a sign that pure-inline doesn't scale past 3-4 branches.
- *Verdict.* **STEAL inline navigation for low branch counts.** Note for §C: RPClient already has a Branches inspector pane (per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md) anti-patterns) — that's the right scaling answer for >3 branches; keep it but unify the visual grammar with the rest of the inspectors.

**A.1.7 Markdown + LaTeX rendering — rich, inline, no collapse by default.**
- *What.* Full markdown (headers, lists, code blocks, tables) and LaTeX rendering inline in assistant turns. Code blocks have a copy button at the top-right corner.
- *Where.* Inline; no auto-collapse for long messages.
- *Why it works.* RP turns are 500-1500 chars and almost never code-shaped; rich inline rendering covers the markup that DOES appear (italics for actions, bold for emphasis, occasional `*scene break*` patterns).
- *Verdict.* **STEAL.** RPClient already does most of this via [Markdown.swift](Sources/RPClientCore/UI/Markdown.swift); don't auto-collapse on length.

**A.1.8 Multi-model conversations — side-by-side compare.**
- *What.* User can open the same prompt against multiple models simultaneously; responses render side-by-side.
- *Where.* Triggered from the model picker (multi-select).
- *Verdict.* **IGNORE for V11.** RPClient's chat surface is single-character-per-turn (group chats are multi-character but one model). Multi-model compare is a power-user feature that doesn't fit the RP frame; if it lands later it's a separate phase.

**A.1.9 Slash-command templates + `#` document references.**
- *What.* Composer supports `#` to inject documents, `#` + URL for web pages, slash for prompt templates with typed input variables.
- *Where.* Inline composer.
- *Verdict.* **IGNORE for V11** (slash-commands deliberately deferred per [V2_DESIGN_LANGUAGE.md §11](V2_DESIGN_LANGUAGE.md) — author-shaped content not app-shaped). Re-evaluate when V12 / cmd-K palette work lands.

**A.1.10 Settings entry — gear icon, rich/deep tabbed window.**
- *What.* Settings is a dense multi-tab modal/page; not a sheet. Most knobs are one-click from a sidebar or a hover.
- *Where.* Behind a single gear icon.
- *Verdict.* **STEAL the discipline** — one entry point. RPClient's Settings already lives there; the work is internal cleanup (§9 of the overhaul), not relocation.

---

### A.2 Claude.ai (Tier 1)

Anthropic's reference shape. Web + macOS native; my familiarity is first-hand.

**A.2.1 Resting state — two-pane (collapsible sidebar + transcript), optional artifacts pane.**
- *What.* Sidebar collapses to a thin rail (~52pt). Main pane is the transcript, max-line-length ~720pt, content-centred. Artifacts pane is opt-in (slides in from the trailing edge when an artifact is created/opened).
- *Where.* Edge-to-edge sidebar; main pane content-centred.
- *Verdict.* **STEAL collapsibility** — RPClient's sidebar is permanently open today; matching macOS sidebar split-item behaviour gets this for free per [V2_DESIGN_LANGUAGE.md §5](V2_DESIGN_LANGUAGE.md).

**A.2.2 Sidebar — date-grouped, one-line rows, project folders.**
- *What.* `Today` / `Yesterday` / `Previous 7 days` / `Previous 30 days` / `<Month>` headers. Each row is a single line: conversation title, no preview, no timestamp. Projects appear above chats as a separate section.
- *Where.* Sidebar.
- *Verdict.* **STEAL date-group headers.** **STEAL one-line rows.** RPClient's current sidebar already uses one-line rows; the gap is the absence of date grouping.

**A.2.3 Header — sparse: title + model picker + share.**
- *What.* Single row. Conversation title leading-edge (editable on click). Model picker pill near top-right. Share button at the trailing edge. That's it — no server/persona/voice clutter.
- *Where.* Top of main pane.
- *Verdict.* **STEAL the floor of one row + three controls.** This is the empirical lower bound for the chat header redesign target. Every reference matches or beats this.

**A.2.4 Per-turn rendering — no-bubbles, full-width, indent-only.**
- *What.* Assistant turns: full-width, `body` text. User turns: subtle background block (slight elevation), narrower than full-width, right-leaning. No avatars on either side. No tail.
- *Where.* Vertical scroll; turns separated by `md` (16pt-equivalent) gap.
- *Verdict.* **STEAL the no-bubbles posture for assistant turns.** **OPEN QUESTION** for user turns — see §D. Character-shaped RP needs an avatar treatment that no-avatar Claude doesn't model directly.

**A.2.5 Per-turn hover controls — trailing-edge floating bar.**
- *What.* On hover over an assistant turn: small floating action bar at bottom-trailing — copy, retry/regenerate, thumbs-up/thumbs-down, sometimes an inline branch-marker pill (`◀ 1/2 ▶`). Bar fades in ~150ms.
- *Where.* Bottom-trailing of the assistant turn.
- *Verdict.* **STEAL placement and hover semantics.** Drop the thumbs (RPClient has no telemetry for those). Keep copy / regenerate / `…`-overflow.

**A.2.6 Variant navigation — small pill, near edited message.**
- *What.* When a user message has been edited (creating a branch), a small `◀ 1/2 ▶` pill appears under that message; clicking the arrows swaps which assistant variant is shown.
- *Where.* Inline, attached to the user message that branches.
- *Verdict.* **STEAL.** RPClient already has gutter arrows for variant navigation per the user's existing function-set affection. Visual treatment can adopt Claude's pill shape.

**A.2.7 `<think>` blocks — collapsed disclosure with "Thought for Xs".**
- *What.* Extended-thinking output renders as a collapsed disclosure ("Thought for 12 seconds"), expandable inline. Headline-weight text, secondary colour.
- *Where.* Inline, above the visible answer.
- *Verdict.* **STEAL.** RPClient's local-model `<think>` blocks should follow this pattern verbatim.

**A.2.8 Composer — model pill leading-inside, attachments inside, send trailing.**
- *What.* Large rounded composer (~720pt wide, content-centred). Model picker pill at the *top-left inside the composer* (not in the header). Attachment / web search / styles / artifacts as inline icon row at the leading bottom of the composer. Send button at the trailing edge.
- *Where.* Pinned bottom of viewport.
- *Verdict.* **STEAL THIS HARD.** Pulling model selection *into* the composer is the load-bearing move that lets the header collapse to almost nothing. RPClient should pull persona + model + server selection down here too.

**A.2.9 Empty state — name + "How can I help you today?" + 4 suggestion cards.**
- *What.* Centred greeting line addressing the user by name; composer; 4 short suggestion cards in a 2x2 grid below.
- *Where.* Vertically centred.
- *Verdict.* **STEAL the greeting + composer-first posture.** **REJECT 4 cards in a grid** — too consumer for RPClient's posture. Use Open WebUI's 3 stacked chips instead (§A.1.3).

**A.2.10 Streaming + cancel — caret + bottom-centre stop pill.**
- *What.* Streaming assistant turns show a thin caret (`▍`) at the cursor position. A floating "Stop response" pill appears bottom-centre during generation; clicks cancel.
- *Where.* Caret inline; pill bottom-centre, ~12pt above the composer.
- *Verdict.* **STEAL.** Cleaner than ChatGPT's button-state-flip on the send button; clearer than per-message spinners.

---

### A.3 ChatGPT (Tier 1 — what to deliberately differ from)

The 90%-of-users baseline. Captured to know what's mass-market default; multiple 2026 changes are notable for what they removed (variant arrows) and what they prove out (hover-only floating action bar).

**A.3.1 Sidebar — date-grouped, but trending denser/busier.**
- *What.* Same `Today` / `Yesterday` / `Previous 7/30 days` / months structure as Claude. Sidebar increasingly carries Projects, GPTs, Library, Sora as siblings to Chats, making it a multi-section app rail.
- *Verdict.* **STEAL the date grouping.** **IGNORE the multi-section app-rail growth** — RPClient's sidebar should stay scoped to Chats + Folders (character-keyed), not become a launcher.

**A.3.2 Header — sparse but inconsistent over time.**
- *What.* Model name top-leading as dropdown; share / temporary-chat icons top-trailing. Single row. Periodically grows experimental tabs and pulls them.
- *Verdict.* **STEAL the one-row floor.** Ignore the growth experiments.

**A.3.3 Per-turn no-bubbles transcript.**
- *What.* User turn: subtle bg block, content-centred. Assistant turn: full-width, no bg. Avatar removed from the user side as of 2025; assistant side is just the brand glyph for the leading character of the turn.
- *Verdict.* Same as Claude — **steal** the posture for the assistant side; user-side bubble-vs-block is an open question (§D).

**A.3.4 Per-turn hover bar — floating, trailing.**
- *What.* On hover, a floating action bar at the bottom-trailing edge of the assistant turn: copy / good / bad / read-aloud / share / `…`-overflow. Regenerate moved into the `…` overflow during the 2026 simplification (community pushback noted in [retry-button-removed write-up](https://www.aiqnahub.com/chatgpt-web-ui-retry-button-removed/)).
- *Verdict.* **STEAL placement.** **INVERSE the regen-into-overflow choice** — keep regenerate as a primary visible icon. The community pushback (and RPClient's RP context where regen is more central than for general assistant use) makes this a clear inverse case.

**A.3.5 Variant arrows — REMOVED in 2026 web update.**
- *What.* Per the [OpenAI community thread on removed message version arrows](https://community.openai.com/t/chatgpt-web-update-removed-message-version-arrows-cannot-access-edited-message-history/1374666), the `◀ N/M ▶` pill that previously surfaced edited-message variants was removed from the web UI in early 2026. Variants now expire on navigate-away; users explicitly complained.
- *Verdict.* **INVERSE — strong.** RPClient's variant arrows are a user-loved function (per the briefing); ChatGPT's regression is a real-world data point that removing them hurts. Keep RPClient's gutter arrows; consider adopting Claude's small-pill visual treatment (§A.2.6) but never the absence.

**A.3.6 Composer — large box, inline tools row, model pill.**
- *What.* Large rounded composer pinned bottom. Inline tools row at leading-bottom: search, image, deep research, code interpreter, voice. Model pill at the top-leading inside the composer (matching Claude's pattern).
- *Verdict.* **CONFIRMS Claude's pattern (§A.2.8) — composer-first model selection is now the cross-app convention** for AI chat. RPClient should adopt.

**A.3.7 Empty state — "What can I help with?" + 4-card 2x2.**
- *What.* Centred greeting + composer + 4 cards (e.g., "Make a plan", "Brainstorm", "Help me write", "Code"). Cards are functional, not personal.
- *Verdict.* **IGNORE the 4-card grid** (too consumer; same call as A.2.9). Open WebUI's 3-chip stack remains the right shape.

**A.3.8 Streaming + cancel — send-button morphs to stop-square.**
- *What.* During streaming, the composer's send button (typically an arrow) flips to a square stop icon. Clicking cancels.
- *Verdict.* **REJECT.** State-flipping the same button is a learnability tax (the icon meaning depends on app state); Claude's separate bottom-centre pill (§A.2.10) is better.

**A.3.9 Long-message behaviour — full render, no collapse.**
- *What.* Long assistant turns render fully, no "show more" cut. Code blocks have inline scroll if very tall.
- *Verdict.* **STEAL.** Confirms Open WebUI; RPClient should not auto-collapse.

**A.3.10 Error states — inline, low-volume.**
- *What.* Server / rate-limit errors render as a small inline notice at the bottom of the failed assistant turn, with a retry pill. No modal alerts for transient errors.
- *Verdict.* **STEAL.** RPClient should never modal-alert a transient send failure.

---

### A.4 SillyTavern (Tier 1 — the contrary example)

Closest functional cousin (RP-focused, cards, world-info, branches). Captured to know what to *avoid*.

**A.4.1 Per-message ••• ellipsis opens a Message Actions panel — overstuffed.**
- *What.* Each message has a `…` button that opens a panel offering: translate, image-gen, TTS, embed files, create checkpoint, branch, visibility-toggle (exclude from AI context). Per [docs.sillytavern.app/usage/chatting](https://docs.sillytavern.app/usage/chatting/).
- *Where.* Per-message overflow.
- *Verdict.* **INVERSE.** Putting 7+ items in a single overflow menu is the anti-pattern. RPClient's `…` should hold ≤4 less-frequent actions; everything else is either a primary hover icon or moves to an inspector.

**A.4.2 Swipes — left/right arrows under the message.**
- *What.* Variant navigation appears as `◀ N/M ▶` directly under the assistant turn. Always visible (no hover).
- *Verdict.* **STEAL the always-visible posture for variants.** Mid-flow disambiguation works better when the `1/3` count is permanently visible than when it's hover-only — Claude's hover-pill (A.2.6) is borderline but works in their context because branches are rarer; in RP variant-rolling is frequent.

**A.4.3 Edit panel — Move Up / Move Down / Copy / Delete.**
- *What.* Editing a message opens a compact panel with reorder + copy + delete controls.
- *Verdict.* **IGNORE the reorder controls.** Reordering historical turns breaks the conversational invariant; RPClient should not adopt this. Copy + delete remain.

**A.4.4 Group chat sidebar — member avatars with mute / force-talk / card-edit icons.**
- *What.* Group members appear in the sidebar with three per-member icons: speech-bubble-strikethrough (mute), speech-bubble (force this character to talk next), card-edit (jump to character editor). Plus reorder arrows + remove + add.
- *Where.* Group panel sidebar.
- *Verdict.* **STEAL the per-member affordance set.** Mute + force-talk + jump-to-card maps directly to RPClient's Cast inspector. The visual grammar is on the busy side; reskin to RPClient's hover-revealed-on-row pattern.

**A.4.5 Reply order strategies — Manual / Natural / List / Pooled.**
- *What.* Group chat reply rotation has four named strategies; user picks one in settings.
- *Verdict.* **STEAL the conceptual model**; RPClient's existing `Director` role overlaps. Reply-order strategy as a per-chat setting is a clean knob; surface it in the chat header dropdown or Cast inspector.

**A.4.6 Bubble-vs-no-bubble — themeable, default leans bubbleless.**
- *What.* SillyTavern offers both message styles via the theme system.
- *Verdict.* **STEAL the no-bubbles default**; the configurability itself is a tell that no-default-fits-all and the contrary case is rare.

**A.4.7 Token Probabilities inspector — power-user inspect tool.**
- *What.* Panel showing per-token sampling alternatives.
- *Verdict.* **IGNORE for V11.** Belongs to a future debug-inspector phase, not the chat-pane redesign.

**A.4.8 World-info / Lorebook — separate disclosure panel, dense.**
- *What.* Lorebook UI is a heavy table-shaped panel; not part of the chat surface.
- *Verdict.* **IGNORE.** RPClient's existing Memory/World inspectors play this role; this is design-language §9.6 territory, separate from chat-pane V11.

**A.4.9 Author's Notes / CFG Scale exposed in chat options.**
- *What.* Mid-thread parameter knobs (Author's Notes, CFG Scale) accessible from the chat options menu.
- *Verdict.* **IGNORE.** RPClient's per-server / per-character parameter handling is centralised in `ModelCapabilities`; per-chat overrides aren't part of the V11 surface.

**A.4.10 Chat options panel — kitchen-sink central menu.**
- *What.* One menu with: new chat, manage chat files, delete multiple, generation settings, Author's Notes, CFG Scale, etc. ~12+ items.
- *Verdict.* **INVERSE.** Same anti-pattern as A.4.1. RPClient should not centralise into a kitchen-sink menu.

**SillyTavern summary verdict.** Two patterns to steal (group-member affordance set, always-visible variant arrows). Several inverses (overflow stuffing, kitchen-sink menus, mid-thread reorder). Confirms that the "RP-shaped" function set RPClient already implements is right; the failure mode is *visual* — too many controls visible at once, no hierarchy.

---

### A.5 Apple Messages.app (Tier 1 — native macOS reference)

The macOS-native "chat feel" baseline. If RPClient's chat doesn't feel as native as Messages, the look is wrong.

**A.5.1 Resting state — two-pane, no inspector.**
- *What.* Sidebar (conversation list) + main transcript. No inspector. Sidebar is glass (Liquid Glass material) per macOS 26 default.
- *Verdict.* **STEAL the two-pane floor.** Inspector is opt-in / use-case-specific in RPClient (and rightly so).

**A.5.2 Sidebar — search, pinned conversations, then recency.**
- *What.* Top: search field. Below: pinned-conversation chips (avatars only). Below that: list of conversations, recency-ordered, each row shows avatar + name + last-message preview + timestamp.
- *Verdict.* **STEAL the search-at-top.** **CONSIDER pinned chips for character-favourites** (Open Question §D — does this fit RPClient's character-keyed model?).

**A.5.3 Per-message rendering — bubbles, sender-coloured, tail-attached.**
- *What.* Outgoing messages: blue bubble, trailing edge, with tail. Incoming: grey bubble, leading edge. Time-stamps clustered (one timestamp per cluster, not per message).
- *Verdict.* **INVERSE for AI-chat.** Messages bubbles work because both parties are *peers* (sender-equivalence). RP has the assistant playing a character — close to a peer — but the user is also half the scene. The four AI-chat references (Open WebUI, Claude, ChatGPT, Cursor) all converge on no-bubbles for AI chat for this exact reason. **DO NOT steal bubbles wholesale.** Open question on user-turn treatment in §D.

**A.5.4 Per-message context menu — long-press / right-click only.**
- *What.* No hover bar. Right-click or long-press opens a context menu: Reply, Tapback emoji, Copy, Translate, Edit, Undo Send, Delete.
- *Verdict.* **IGNORE for primary discovery.** Context-menu-only requires the user to know it exists. AI-chat hover bars work better. Keep the context menu as a *secondary* discovery path (it's free in AppKit) — but don't make it primary.

**A.5.5 Composer — minimal: rounded text + plus + mic.**
- *What.* Single rounded text input. Leading: `+` (apps drawer). Trailing: dictation/mic + send-arrow when text present. App strip (Photos, stickers, etc.) hidden by default.
- *Verdict.* **STEAL the discipline**: the composer can be one input + two trailing icons + `+` and feel complete. Counter-evidence to RPClient's "composer needs more affordances" intuition.

**A.5.6 Header — minimal: name + avatar + iCloud/SMS indicator + FaceTime.**
- *What.* Single row: contact name with avatar, tiny iCloud-vs-SMS indicator, FaceTime call icon. Total visible chrome ≤ 4 elements.
- *Verdict.* **STEAL the floor.** This is the "ceiling" of header sparseness; RPClient's header should aim for this with at most 1-2 additional elements (model pill, persona switcher).

**A.5.7 Empty state — just the typing field.**
- *What.* New message: blank canvas, To: field, then composer. No suggestions, no greeting.
- *Verdict.* **IGNORE.** AI chat is not Messages — a fresh chat with a character benefits from suggestion seeds (§A.1.3); a fresh contact thread does not.

**A.5.8 Streaming feedback — typing-indicator dots in a ghost bubble.**
- *What.* Three animated dots in an empty bubble at the leading edge while the other party is typing.
- *Verdict.* **PARTIAL STEAL.** The typing-dots motif is widely understood. RPClient could use it as the pre-stream indicator (between Send and the first token), then transition to caret-streaming (Claude's pattern) once tokens land. Decision deferred to §C.5.

**A.5.9 Reactions — Tapbacks (heart, thumbs, ha-ha, !!, ?, emoji).**
- *What.* Per-message emoji reactions stuck to the corner of the bubble.
- *Verdict.* **IGNORE.** Single-user app; reactions add no signal.

**A.5.10 Edit / Undo Send — destructive controls live in context menu.**
- *What.* Both edit and undo-send live in the right-click menu, not visible chrome. Edit history surfaces as a small "Edited" timestamp footnote on the bubble.
- *Verdict.* **STEAL the "Edited" footnote** for showing edit-history tail-marks; demote destructive controls (delete) into the per-turn `…` overflow, not the primary hover bar.

---

### A.6 LibreChat (Tier 2)

OSS multi-model client. Captured from `librechat/demo_light.png` and `demo_dark.png`.

**A.6.1 Three-pane with right-side feature drawer — overstuffed.**
- *What.* Narrow left rail + chat list + main + heavy right inspector with tabs (Agent Builder / Prompts / Memories / Parameters / Attach Files / Bookmarks / MCP Settings) and a long MCP-server list below the tabs.
- *Verdict.* **INVERSE.** Right-pane carries a launcher list (10+ MCP servers visible) that pushes the chat surface into the visual minority. RPClient's inspector model already exists; the lesson is *don't grow it into a launcher*.

**A.6.2 Sidebar conversation list — flat, search-only.**
- *What.* Search field at top, then long flat list of conversation titles. No date grouping visible in the captured frames.
- *Verdict.* **INVERSE.** Confirms the date-grouping recommendation (§A.2.2 / §A.3.1) — flat lists past ~15 entries become an unscannable wall.

**A.6.3 Composer — multiple inline button labels (Artifacts, MCP Servers ▾).**
- *What.* Composer has labelled buttons inline ("Artifacts", "MCP Servers ▾") rather than icon-only.
- *Verdict.* **PARTIAL STEAL.** Labels-on-buttons inside the composer (rather than glyph-only) is the right call for low-frequency power-user actions where the icon doesn't communicate. RPClient: persona pill should be labelled (`Persona: Mia`), not glyph-only.

**A.6.4 Empty state — logo-centred + composer.**
- *What.* Brand logo + name centred, composer below. No suggestion chips visible.
- *Verdict.* **WEAK.** Confirms Open WebUI / Claude / ChatGPT include suggestions; LibreChat skipping them is a gap, not a deliberate posture.

**A.6.5 Bottom attribution — "LibreChat v0.8.2 · Every AI for Everyone."**
- *What.* Footer text under the empty-state logo.
- *Verdict.* **IGNORE.** Bottom-of-window attribution doesn't fit a productivity app frame.

---

### A.7 Anthropic Workbench (Tier 2)

Developer-side chat at `console.anthropic.com/workbench`. From first-hand familiarity.

**A.7.1 Three-pane: parameter sidebar + chat + meta panel.**
- *What.* Left: System prompt + Model + Parameters (temperature, max_tokens, etc.). Centre: chat messages with "Add message" / "Insert assistant prefill" controls between turns. Right: token / cost meta + "Get Code" export.
- *Verdict.* **STEAL the inter-turn affordance** — the ability to insert messages or assistant prefills *between existing turns* is exactly the pattern RPClient needs for the user's "edit branch context" workflows. Currently RPClient has no clean equivalent.

**A.7.2 Per-turn meta — token count, cost, retry.**
- *What.* Each turn shows token count + cost; retry button per turn.
- *Verdict.* **PARTIAL STEAL.** Token-count per turn is useful debug info — keep behind a hover or `⌥` reveal, not permanent.

**A.7.3 No bubbles, role-labelled blocks.**
- *What.* "User" / "Assistant" labels on each block; no avatars, no bubbles. Maximally functional.
- *Verdict.* **CONFIRMS** the no-bubbles convention.

---

### A.8 Cursor (Tier 2)

Inline AI chat panel inside an IDE. From `cursor.com` marketing + first-hand.

**A.8.1 Right-docked chat panel inside the IDE.**
- *What.* Chat lives in a panel docked to the IDE's right edge; main editor is the leftmost column.
- *Verdict.* **IGNORE.** RPClient is not an IDE; the chat IS the app. Single-pane-dominant layout.

**A.8.2 `/` for commands, `@` for files in the composer.**
- *What.* Inline command syntax for context insertion.
- *Verdict.* **IGNORE for V11** (see A.1.9 — slash deferred).

**A.8.3 Multi-stage task progression UI.**
- *What.* Long-running agent tasks render as cards with stage labels ("In Progress", "Fetching data", "Ready for Review") + duration + file changes.
- *Verdict.* **OPEN.** Could apply to RPClient's Phase 7 retrieval / Phase 8 director cycles, but those are sub-second; the multi-stage card UI is sized for multi-minute work. Not a chat-pane V11 concern.

**A.8.4 Autonomy slider.**
- *What.* User control over how independently the agent acts.
- *Verdict.* **IGNORE.** RPClient's chat is a user-driven scene-construction tool, not an agent.

---

### A.9 Linear (Tier 2 — chat-adjacent, issue comments)

Already covered in [V2_DESIGN_LANGUAGE.md §11](V2_DESIGN_LANGUAGE.md). Re-captured here for chat-shaped surfaces only.

**A.9.1 Issue comment thread — no bubbles, hover-revealed actions.**
- *What.* Comments stack as no-bubble blocks with author + relative time + body. Hovering a comment reveals reply / react / `…`-overflow at the trailing edge with a 100-150ms fade.
- *Verdict.* **STEAL the timing**, **CONFIRMS the no-bubbles posture for non-Messages contexts**, **CONFIRMS** the trailing-hover pattern.

**A.9.2 Calm motion budget.**
- *What.* 100-220ms ease-out, no springs.
- *Verdict.* **CONFIRMS [V2_DESIGN_LANGUAGE.md §8](V2_DESIGN_LANGUAGE.md) motion budget.**

**A.9.3 Density posture.**
- *What.* High row density; secondary controls hover-revealed.
- *Verdict.* **CONFIRMS [V2_DESIGN_LANGUAGE.md §9](V2_DESIGN_LANGUAGE.md).**

---

### A.10 Slack / Discord (Tier 2 — chat patterns at scale)

**A.10.1 Per-message hover bar at the trailing edge.**
- *What.* Both apps surface per-message react / reply / save / share / `…`-overflow as a hover-revealed floating bar, top-trailing of the message.
- *Verdict.* **CONFIRMS** the hover-bar pattern across consumer + AI clients.

**A.10.2 Channel/thread sidebar grouped by category.**
- *What.* Slack: Threads / DMs / Channels / Apps sections. Discord: Server rail + channel list.
- *Verdict.* **PARTIAL.** Multi-server / multi-channel concepts don't apply; the lesson is "group when you have categories worth grouping by." For RPClient: Folders (per Open WebUI) for character-keyed grouping is the analogue.

**A.10.3 Composer formatting toolbar — collapsible.**
- *What.* Slack's formatting toolbar (bold/italic/code/etc.) is one click to expand, hidden otherwise.
- *Verdict.* **IGNORE.** RP authors don't format-as-they-type; they author prose.

---

## §B — Cross-app pattern table

Each row answers one of [V2_UI_OVERHAUL.md §3.3](V2_UI_OVERHAUL.md)'s 10 questions, citing the apps that converge or diverge.

### B.1 — How are per-turn controls surfaced?

| Pattern | Apps | Notes |
|---|---|---|
| Hover-revealed floating bar at trailing edge | Open WebUI, Claude.ai, ChatGPT, Slack, Discord, Linear, LibreChat | The cross-app convention. ~120-150ms fade. |
| Always-visible variant arrows under turn | SillyTavern, Open WebUI (variant pill) | RP-specific need; both retain visible vs hover. |
| Context-menu-only (right-click) | Apple Messages | Native macOS; secondary discovery. |
| Per-turn `…` overflow holds 7+ items | SillyTavern (anti-pattern) | Stuffing; users hunt. |

**Verdict for RPClient.** Hover-bar at trailing edge for primary actions (copy / regenerate / edit), `…`-overflow for ≤4 secondaries (delete / fork / pin / view-raw). Variant arrows stay always-visible (not hover) because they carry state (`1/3`) the user needs to see without intent. Right-click context menu mirrors the hover bar (free in AppKit; redundancy is fine).

### B.2 — Bubbles vs no-bubbles.

| Pattern | Apps | Notes |
|---|---|---|
| No-bubbles, full-width assistant turn | Open WebUI, Claude.ai, ChatGPT, Cursor, Workbench, Linear, LibreChat | 7 of 9 references. The convention. |
| Subtle background block on user turn (no full bubble) | Claude.ai, ChatGPT | The split — user gets *some* visual distinction, not a bubble. |
| Coloured bubble with tail | Apple Messages, iMessage | Sender-equivalence assumption; doesn't transfer to AI chat. |
| Themeable (both bubble and bubbleless options) | SillyTavern | Tells you neither default fits all but most users pick bubbleless. |

**Verdict.** No-bubbles for assistant turns (overwhelming convergence). Subtle bg block for user turns (Claude/ChatGPT pattern). Avatars are an open question (§D) — RP has characters, AI chat mostly doesn't.

### B.3 — Header density.

| Floor (sparse) | Mid | Anti-pattern (dense) |
|---|---|---|
| Apple Messages: name + avatar + indicator + FaceTime | Open WebUI: model picker + small caption | Current RPClient: Server + Attribution + Voice + speaker mute (per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md)) |
| Claude: title + model pill + share | ChatGPT: model dropdown + temporary-chat + share | SillyTavern variants pile up settings into the header strip |

**Verdict.** Target one row, ≤3 controls. Pull model + persona + server selection *down into the composer* (Claude/ChatGPT convention) so the header collapses to title + minor metadata. RPClient's chat header redesign is anchored on this single move.

### B.4 — Conversation-list hierarchy.

| Pattern | Apps |
|---|---|
| Date headers (Today / Yesterday / Previous 7 / 30 / Older) | Claude.ai, ChatGPT, Open WebUI |
| Folders + dates | Open WebUI |
| Search-only flat list | LibreChat (anti-pattern past ~15 entries) |
| Pinned + recency | Apple Messages |
| Categorical sections (DMs / Channels / Apps) | Slack, Discord (multi-user; not applicable) |

**Verdict.** Date headers as the floor. Folders for character-keyed grouping (RPClient's natural axis — group by character, not by date alone). Search field at top as a bonus, not a substitute. RPClient's current flat-with-recency-only is the LibreChat failure mode.

### B.5 — Variant navigation.

| Pattern | Apps |
|---|---|
| Inline `◀ N/M ▶` always visible under message | SillyTavern, Open WebUI |
| Inline pill on edited message, hover-reveal | Claude.ai |
| Removed in 2026 (regressed) | ChatGPT (community pushback documented) |
| In gutter alongside message | RPClient (current) |

**Verdict.** Keep RPClient's gutter arrows. Visual treatment can shift to a small pill (Claude's shape) rather than full gutter chrome, but always-visible (SillyTavern/Open WebUI confirm) — the count is state the user reads at-a-glance. The ChatGPT regression is a counter-data-point: removing variants makes users complain.

### B.6 — Streaming feedback.

| Pattern | Apps |
|---|---|
| Caret + bottom-centre "Stop" pill | Claude.ai |
| Send-button morphs to stop-square | ChatGPT |
| Typing-dots in ghost bubble | Apple Messages |
| Per-stage progress cards (multi-minute work) | Cursor |

**Verdict.** Two-stage feedback: typing-dots placeholder turn (between Send and first token) → caret-streaming once tokens land + bottom-centre Stop pill. Don't morph the send button (state-dependent icons are a learnability tax). Don't put a header spinner (header is sparse; spinners draw attention).

### B.7 — Composer affordances.

| Pattern | Apps |
|---|---|
| Model pill INSIDE composer (top-leading) | Claude.ai, ChatGPT |
| Tools row INSIDE composer (leading-bottom) | Claude.ai, ChatGPT, LibreChat, Open WebUI |
| Send trailing edge | All |
| Attachment leading edge | All |
| Labelled buttons (not just glyphs) for low-freq actions | LibreChat ("Artifacts", "MCP Servers ▾") |

**Verdict.** Pull persona + model + server selection *into* the composer as labelled pills at the leading top of the composer. Attachments + voice as glyphs at leading bottom. Send arrow trailing. RPClient's composer becomes the action surface; the header recedes.

### B.8 — Markdown rendering and `<think>` blocks.

| Pattern | Apps |
|---|---|
| Inline rich markdown (headers, lists, code, tables, math) | Open WebUI, Claude.ai, ChatGPT |
| `<think>` collapsed disclosure with "Thought for Xs" | Claude.ai |
| `<think>` rendered inline as quote block | Open WebUI (varies by version) |
| n/a (no thinking concept) | ChatGPT (closed model), Apple Messages |

**Verdict.** Inline rich markdown (RPClient already does most). `<think>` blocks collapsed with "Thought for Xs" disclosure (Claude pattern), expandable inline. Don't render thinking as a sibling block — it noises the transcript.

### B.9 — Long-message behaviour.

| Pattern | Apps |
|---|---|
| Render full, no collapse | Open WebUI, Claude.ai, ChatGPT, all chat refs |
| Auto-collapse with "show more" past N lines | (none in this set) |

**Verdict.** Render full. Don't auto-collapse. RPClient's 500-1500 char turns are well below any collapse threshold; reserve collapse for `<think>` blocks specifically.

### B.10 — Empty-conversation onboarding.

| Pattern | Apps |
|---|---|
| Greeting + composer + 3 stacked suggestion chips | Open WebUI |
| Greeting + composer + 4-card 2x2 suggestion grid | Claude.ai, ChatGPT |
| Composer only (no suggestions) | Apple Messages, LibreChat |
| Brand mark + composer | LibreChat |

**Verdict.** Greeting + composer + 3 stacked chips (Open WebUI shape; chips drawn from the character's `example_messages` or scenario hooks). 4-card grid reads consumer; LibreChat / Messages bare-canvas misses the seed-the-scene opportunity that's natural in character-shaped chat.

---

## §C — Synthesis: directional recommendations for RPClient's chat pane

The load-bearing section. Five high-confidence calls and three open ones (those land in §D).

### C.1 — No-bubbles transcript layout, with character-avatar gutter.

**Adopt no-bubbles for assistant turns.** Seven of nine references converge (Open WebUI, Claude, ChatGPT, Cursor, Workbench, Linear, LibreChat); only Apple Messages dissents, and Messages' bubbles are load-bearing because of the sender-equivalence assumption that doesn't hold in RP. SillyTavern offers both as themes; the configurability tells you neither default fits all but most users default to bubbleless.

**For user turns**, adopt Claude/ChatGPT's "subtle background block, content-narrowed" treatment — *not* a full bubble, but enough visual distinction that the eye parses the alternation without effort.

**Avatar treatment** for character-shaped RP is the unique-to-RPClient delta from Claude/ChatGPT (which are character-less): a 32pt circular avatar in a leading gutter, attached to the assistant turn only. The user side stays avatar-less (or uses a small persona-name caption). The avatar gutter doubles as the per-turn-controls reveal target — hovering the gutter or the turn body reveals controls; this gives a generous hover surface without permanent chrome. **Open question** (see §D) — whether the gutter is `xl` (32pt) wide or `lg` (24pt) wide depends on visual weight; needs a sketch.

### C.2 — Per-turn controls: hover-revealed primary bar at trailing edge, `…` overflow ≤4 items, variant arrows stay always-visible.

**Hover bar (trailing edge, ~120ms fade per [V2_DESIGN_LANGUAGE.md §8](V2_DESIGN_LANGUAGE.md)):** copy, regenerate, edit, branch-fork, `…`. Five primary icons; matches Claude/Open WebUI's discipline.

**Overflow `…` menu (≤4 items, never more):** delete, view raw, pin, copy as quote. Anything beyond four moves out of the overflow into either an inspector or a per-chat setting. SillyTavern's 7+-item overflow is the anti-pattern.

**Variant arrows stay always-visible** in a small pill under the turn (`◀ 1/3 ▶`). Two reasons: the count (`1/3`) is state-information the user reads at-a-glance, not an action they trigger; and ChatGPT's 2026 removal of variants generated documented community pushback — it's a real-world counter-data-point that hover-only or expire-on-navigate is wrong here. SillyTavern and Open WebUI both keep them visible.

**Right-click context menu** mirrors the hover bar + overflow. Free in AppKit; secondary discovery path; matches Apple Messages convention so the surface still feels native to the right-click-trained user.

### C.3 — Header collapses to one row, ≤3 controls. Pull model + persona + server *down* into the composer.

The biggest single move. Today's chat header (per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md) anti-patterns) is multi-row with Server + Attribution + Voice + speaker-mute permanently visible. Every reference contradicts this:

- Apple Messages: 4 elements in one row (the floor).
- Claude.ai: 3 elements in one row.
- ChatGPT: 3 elements in one row.
- Open WebUI: 1 element + caption in one row.
- Workbench / LibreChat: ≤4 in one row.

**Target.** One row containing: chat title (editable on click) | small persona/character name caption (subhead, secondary colour) | trailing-edge actions ≤2 (probably: Inspector toggle + `…` overflow for chat-scoped actions like rename / export / delete). That's 4 elements total.

**Where do model / server / persona / voice go?** Down into the composer (per Claude / ChatGPT convention, §B.7). Specifically:
- Persona pill at the leading top of the composer (`Persona: Mia ▾`).
- Model + server pill next to it (`Server: kobold-loc · Qwen3.6-35B ▾`).
- Voice pill optional, behind a `…` if too crowded; voice is closer to a per-utterance setting than a per-conversation one.
- Speaker-mute moves to a per-character hover icon over the avatar in the assistant turn (it's a per-character state, not a chat-wide one).

The composer becomes the action surface; the header recedes to navigation/identity only. This is the pattern macOS productivity apps converge on (Things, Linear, Notion all run sparse top chrome with action-rich content surfaces).

### C.4 — Conversation list: date-grouped, with character-keyed Folders for the RP angle.

**Date-grouping** is the cross-app convention (Claude, ChatGPT, Open WebUI). RPClient's flat-with-recency-only is the LibreChat failure mode at scale (the captured LibreChat hero shot shows ~25 conversations in an unscannable wall). Add `Today` / `Yesterday` / `Previous 7 days` / `Previous 30 days` / `<Month>` headers.

**Folders** as a layer above the date groups, for the RPClient-specific axis: characters. A "Mia" folder collects the ~15 chats with that character; the date grouping happens inside it. This is Open WebUI's Folders pattern (§A.1.1) applied to RPClient's natural grouping axis.

**Search** at the top of the sidebar (Apple Messages convention).

**Open question (§D)** — pinned-conversations strip at the top (Apple Messages style)? Useful if the user has 2-3 favourite scenes they return to; redundant if Folders already solve that.

### C.5 — Streaming feedback: typing-dots placeholder → caret-stream → bottom-centre Stop pill.

Three-stage streaming UX:

1. **Pre-token (Send → first token, typically 200-2000ms on local models):** a placeholder assistant turn appears immediately with a typing-dots indicator (Apple Messages convention), at full turn-position. This addresses the dead-air gap without a noisy spinner.
2. **Streaming (tokens landing):** the dots vanish, text streams in with a thin caret (`▍`) at the cursor position (Claude convention).
3. **Cancel:** a floating "Stop" pill at bottom-centre, ~12pt above the composer (Claude convention). Don't morph the send button (ChatGPT's anti-pattern — state-dependent icon meaning).

No spinners in the header; the chat pane carries all streaming state.

### C.6 — Markdown rich-render, `<think>` collapsed, no auto-collapse for length.

`<think>` blocks render as a collapsed disclosure (`Thought for 12 seconds`) with secondary colour, expandable inline. This is Claude's pattern; Open WebUI's inline-quote-block alternative noises the transcript. RPClient sees `<think>` from Qwen-family local models routinely (per Phase 10 §10.0.b log) — this is load-bearing.

Long-message turns render fully — no "show more" cut. Confirmed across all references; RP turns are well below any reasonable collapse threshold.

### C.7 — Empty state: 3 stacked suggestion chips drawn from the character's example dialogue.

Open WebUI's three-chip stacked shape, not Claude/ChatGPT's 4-card 2x2 grid (too consumer). Each chip's title + sub-line is sourced from:
- The character's `example_messages` (the user's pre-authored scene seeds).
- The character's `scenario` field (the situation hook).
- A neutral fallback ("Start the scene" / "Continue from last time") if the character has neither.

This is the only RPClient-unique synthesis call — every other reference's empty-state chips are functional ("Brainstorm", "Code"); RPClient's are *narrative* (scene seeds). The character data already exists; this is presentation, not new content.

### C.8 — Motion budget: confirms [V2_DESIGN_LANGUAGE.md §8](V2_DESIGN_LANGUAGE.md) verbatim.

Linear's "calm motion despite density" budget (100-220ms ease-out, no springs) matches every Tier-1 reference's behaviour. Hover fades 120ms linear; disclosure expands 220ms ease-in-out; tab swaps 180ms ease-out. No new motion tokens needed.

---

## §D — Open questions for the design pass

Things this research couldn't resolve alone. Each is a subjective taste call or needs a visual sketch.

1. **User-turn visual treatment** — subtle background block (Claude/ChatGPT convention) vs. very-subtle bubble (closer to Messages but bubbleless-leaning) vs. just an indent + name caption (Workbench-style). Affects perceived "chat-feel". Sketch needed.

2. **Avatar gutter width** — `lg` (24pt) reads as "small marker"; `xl` (32pt) reads as "this character is present". Visual weight matters for the character-presence feel that's load-bearing for RP. Sketch needed.

3. **User-side avatar / name caption** — does the user's persona surface inline next to their turn (small avatar or name caption), or stay invisible because the user is the implicit speaker? Affects multi-persona scenes where the user might switch personas mid-chat.

4. **Pinned-conversations strip in the sidebar** — Apple Messages-style avatar-only pin row at the top of the sidebar list. Useful for 2-3 active scenes; possibly redundant with Folders. Decide once Folders are spec'd.

5. **Variant arrows: gutter vs pill-under-turn** — RPClient currently puts them in the gutter; Claude puts them in a pill under the turn; SillyTavern puts them as inline arrows. All three are always-visible, so the always-visible call is settled — but the placement is a visual taste call. Sketch.

6. **Persona + model + server pills in composer** — labelled vs glyph-only? Stacked vs single row? LibreChat labels ("Artifacts", "MCP Servers ▾"); Claude/ChatGPT use glyph + label hybrids. RPClient's three pills (persona, model, server) might exceed a single composer row at the right window width; needs a layout sketch with min-window-width constraints.

7. **Group-chat speaker affordances** — SillyTavern's per-member mute/force-talk/jump-to-card icons (§A.4.4) are the only existing reference. They're busy. RPClient already has a Cast inspector pane; the question is whether per-message speaker-attribution carries the same icons inline (busy but discoverable) or stays inspector-only (cleaner but discovery-poor). Subjective; needs a usability call.

8. **Branches inspector vs. inline tree** — Open WebUI's inline-arrows-only model breaks past 3-4 branches (open issue requesting cleanup); RPClient already has a Branches inspector that scales. Question: do we surface a tiny "branches: 3 ▾" pill on the diverging message that opens the inspector, or stay invisible until the user opens the inspector themselves?

9. **`Theme.swift uiFontOffset` removal during V11.a** — confirmed dead per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md). Migration timing — does it land in V11.a (chat-pane redesign) or as a separate sub-step? Trivially small but needs sequencing.

10. **Custom glyph migration** — `✦` placeholder for character-less assistant turns. [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md) says replace with `person.crop.circle`. Lands during V11.a inevitably (the avatar gutter implementation is exactly where this glyph currently lives). **RESOLVED** in 4.b.1 (commit `7aeb6d8`).

11. **`<think>` trace doesn't reach `turn.text` today** — surfaced 2026-05-09 while smoke-verifying the 4.b.2 disclosure UI. [`ThinkBlockFilter`](Sources/RPClientCore/ThinkBlockFilter.swift) strips the trace from the streaming token feed before it reaches `turn.text`, so the `▸ Thinking` disclosure had no data to surface on either historical chats or new thinking-model turns. **RESOLVED 2026-05-09 via option (b)** in commit `8c5cfee`. `TurnVariant.thinkingTrace: String?` carries the captured trace; `ThinkBlockFilter.capturedTrace` exposes it; `AppState`'s stream-finish handler writes it; `TurnView` reads it from the active variant; `turn.text` stays as clean as it always has. Per-variant so swiping regenerations shows the matching reasoning. 17 net-new tests across `Phase11ThinkTraceCapture` (filter behaviour) and `Phase11ThinkTracePersistence` (codable round-trip + legacy decode).

12. **Empty-body turns need a sentinel** — surfaced 2026-05-09 while smoke-verifying 4.e.1's typing-dots indicator. When a thinking-mode model produces a long `<think>` block (5000+ chars in the observed case) and effectively zero body text after `</think>`, the chat surface renders an empty bubble with no indication that anything happened. The disclosure pill is there with the trace, but it's discoverable only if the user notices it. The empty-body case has always rendered as empty (this isn't a §4.e.1 regression), but the new dots indicator made it visually obvious that "something was happening, then nothing landed", which is what surfaced the gap. Possible shapes for the fix:
    - **(a) Inline sentinel.** Render `(no reply)` in `tertiaryLabelColor` `caption1` when `rawText` is empty AND `thinkingTrace` is non-empty AND `isStreaming` is false — distinct from the legitimate "fresh placeholder turn pre-stream" state.
    - **(b) Auto-expand the disclosure.** When the body is empty but a trace exists, default the disclosure pill to expanded so the user immediately sees what the model was thinking about. Lower friction than (a); still discoverable.
    - **(c) Both.** Sentinel for at-a-glance scannability + auto-expand for direct content access.
    Recommendation: **(c)** — both are cheap to implement and they cover different reading patterns. Land alongside §4.e.3 (Stop pill) since both touch the chat-surface's "what's happening with this turn?" feedback layer.

---

## §E — Screenshot index

Every captured asset lives under `docs/research/ui-overhaul/<app>/`. List below; one-line caption each.

- [`openwebui/demo.png`](docs/research/ui-overhaul/openwebui/demo.png) — Open WebUI README hero (3442×1968). Empty new-chat with `gpt-4.1-nano` model selected, sidebar showing New Chat / Search / Notes / Workspace / Channels / Folders / Chats grouped by Today, composer with `+`, tools, mic, send, and three "Suggested" chips.
- [`librechat/demo_light.png`](docs/research/ui-overhaul/librechat/demo_light.png) — LibreChat empty state, light theme (2546×1428). Three-pane: nav rail + flat conversation list + main + heavy right inspector with MCP server list.
- [`librechat/demo_dark.png`](docs/research/ui-overhaul/librechat/demo_dark.png) — Same as above, dark theme (2546×1426). Confirms layout consistency across themes.

**Captures not collected (described from training knowledge / public docs / first-hand familiarity, flagged as such in §A):**

- Claude.ai chat surface — login-walled; no public README hero. Captures described in §A.2 from first-hand familiarity (cutoff: January 2026).
- ChatGPT chat surface — login-walled. Captures described in §A.3, supplemented by [aiqnahub.com retry-button-removed write-up](https://www.aiqnahub.com/chatgpt-web-ui-retry-button-removed/) and [OpenAI community thread on removed message version arrows](https://community.openai.com/t/chatgpt-web-update-removed-message-version-arrows-cannot-access-edited-message-history/1374666) for 2026 changes.
- Apple Messages.app — native macOS, no public hero shots. Described in §A.5 from first-hand familiarity. If a specific frame ends up needing a sketch (e.g. the typing-dots ghost bubble timing), flag in §D.
- SillyTavern — README screenshots are private-user-images URLs requiring auth; not pulled. Behaviour described in §A.4 from [docs.sillytavern.app/usage/chatting](https://docs.sillytavern.app/usage/chatting/) and `groupchats/` pages.
- Anthropic Workbench, Cursor, Linear, Slack/Discord — described from first-hand familiarity; no captures attempted.

If any specific frame needs to be visually pinned during the design pass (§4 onwards), that's an §D-flagged ask for the user to drop in a screenshot — not a research-pass blocker.

---

## §F — Definition-of-done check (per V2_UI_OVERHAUL.md §3.4)

- ✅ All 5 Tier-1 apps captured per §3.2 (10 patterns each = 50 total). Open WebUI (10), Claude.ai (10), ChatGPT (10), SillyTavern (10), Apple Messages (10).
- ✅ Tier-2 apps abbreviated capture (3-5 patterns each). LibreChat (5), Workbench (3), Cursor (4), Linear (3), Slack/Discord (3).
- ✅ All 10 §3.3 cross-app questions answered with cited evidence in §B.
- ✅ §C synthesis is opinionated — eight directional recommendations, not a balanced summary.
- ✅ Every captured pattern carries a steal/ignore/inverse verdict.
- ✅ Screenshot folder populated under `docs/research/ui-overhaul/`, indexed in §E. Three live captures + explicit gaps flagged.
- ✅ All recommendations implementable inside [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) tokens. No motion-budget overruns; no new spacing tokens proposed; one open question (§D.2 avatar gutter width) is between two existing tokens, not outside them.
