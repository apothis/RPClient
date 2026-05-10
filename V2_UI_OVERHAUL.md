# V2 UI Overhaul

**Status: research landed (2026-05-09); chat-pane design pass §4 spec'd.** Per V2_PLAN.md §8 — the deferred complete-UI-overhaul doc, foundation laid by [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) (2026-05-07). This doc is the **per-surface migration plan** that builds on top.

§3 research output: [V2_PHASE11_UI_RESEARCH.md](V2_PHASE11_UI_RESEARCH.md). §4 below consumes it; §5+ stubs remain pending (each surface gets its own design pass after chat-pane lands).

---

## 1. Scope, posture, north-star

### 1.1 In scope
- **Chat pane first** (the load-bearing surface, the part that needs the most), **with the chat header folded in** since they share a controller. Everything else — sidebar, inspector, library, Settings, popovers / sheets — comes after.
- Visual + interaction redesign (typography, spacing, color, materials, motion) per the existing [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) tokens.
- Behavioural polish: layout stability under resize / reload, transition smoothness, no glitchy redraws.
- Per-turn controls: keep their *function* (regen, edit, branch, copy, swipe variants, etc.) — the user explicitly likes them. Open to look + placement changes.

### 1.2 Out of scope
- Functional features (those live in their own Phase docs — Phase 10 § ServerProbe, Phase 7+ branching tweaks, etc.). This overhaul is presentation + interaction polish.
- Migration of Theme.swift's `uiFontOffset` setting to macOS Dynamic Type — that's catalogued in [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md) as an anti-pattern; addressed during the per-surface passes when a surface that uses it is being overhauled, not as a separate sub-step.
- Any redesign of the Card Creator window — Phase 9 §5.3 already shipped it as the gold-standard surface that aligns with the design language. The overhaul *measures against* it; it doesn't re-do it.
- iOS / iPadOS — RPClient is macOS-only.

### 1.3 North-star
Per the user's guidance:
- **Modern.** Reads like a 2026 macOS productivity app, not a 2018 cross-platform Electron port. Liquid Glass materials where the depth metaphor is real; system semantic colors; SF Symbols.
- **Chat-feel, not form-feel.** Today the chat surface reads as form chrome around a transcript. Target: the transcript IS the surface; chrome recedes. Reference apps in §3 are picked specifically for this — Open WebUI, Claude.ai, ChatGPT, Messages.app.
- **Polished.** No glitchy redraws on resize, no layout jumps when a turn lands, no scroll-position loss on send, no awkward control collisions when the inspector toggles. Motion budget: [Design Language §8](V2_DESIGN_LANGUAGE.md) (100-220ms, ease-out, no springs).
- **Per-turn controls retained.** Hover/focus reveal patterns from Open WebUI, Claude.ai, Notion. Visible-on-hover, keyboard-reachable.

---

## 2. Inheritance from V2_DESIGN_LANGUAGE.md

The design language is the **platform truth** — typography scale, spacing tokens, color tokens, materials, motion budget, density posture, application contract for new surfaces. This overhaul doc inherits all of it and **does not propose changes to those tokens**. If a surface re-design needs a new spacing value or a new typography token, the design language doc gets a PR first, *then* the surface absorbs the change.

What this overhaul adds on top:
- **Per-surface anatomy** — the specific layout structure of each redesigned surface (chat pane, header, sidebar, etc.).
- **Migration sequencing** — which surfaces ship first, what risks, what's cross-surface coupled.
- **Reference-app evidence** — the §3 research output, captured as the empirical basis for proposed structures.
- **Rejection log** — patterns we considered and rejected, with rationale (so re-litigation has a paper trail).

The Card Creator (Phase 9 §5.3) is the proof-of-contract reference. If a proposed redesign requires a primitive the creator already has (forms, sections, popups, sheets), reuse the pattern. If it requires something new, the new pattern enters the design language doc as an addition, then the surface uses it.

---

## 3. Phase 11.0 — Reference-app research pass (LANDED 2026-05-09)

**Output:** [V2_PHASE11_UI_RESEARCH.md](V2_PHASE11_UI_RESEARCH.md). 5 Tier-1 apps captured (Open WebUI, Claude.ai, ChatGPT, SillyTavern, Apple Messages) + 5 Tier-2 (LibreChat, Workbench, Cursor, Linear, Slack/Discord). All 10 §3.3 questions answered in the research doc's §B; opinionated synthesis in §C feeds §4 below; 10 open questions in §D, two of which are now resolved (see §4.0 below) and the rest carried forward into §4 sub-steps.

The original spec for the research pass follows below for archival purposes — kept so re-litigation has a reference.



**Goal.** Capture concrete empirical evidence from a focused set of comparable apps' chat surfaces, structured so the per-surface plans (§4+) can cite specific patterns + rationale. Output is a research document filed alongside this plan, not changes to this plan itself.

The Card Creator's design language work was grounded in research (Linear, Things, Notion, Vercel, Raycast — see [V2_DESIGN_LANGUAGE.md §11](V2_DESIGN_LANGUAGE.md)). This research pass extends that posture to chat-surface-specific patterns, which the design language deliberately did NOT cover (the creator wasn't a chat surface).

### 3.1 Reference apps to capture

**Tier 1 — primary references (chat-shaped, must capture).** Per the user's guidance, Open WebUI is the lead reference. The others are picked because each handles a specific axis well.

| App | Why | What to focus on |
|---|---|---|
| **Open WebUI** | User's stated favourite. OSS LLM client. Closest functional + visual match to RPClient's intended target. | Per-message hover controls, message rendering (markdown, code blocks, thinking blocks), regen/branch UI, sidebar grouping, settings discoverability, model switcher placement, multi-turn variant navigation. |
| **Claude.ai** (web + macOS native client if installed) | Anthropic's reference shape for an AI chat. Polished, deliberate density, current. | Per-turn hover controls (regen / copy / edit), message-corner action menu, attachment rendering, sidebar collapse, "long thinking" indicator. |
| **ChatGPT** (macOS native app + web) | The reference model 90% of users have seen. Worth capturing precisely so we know what to deliberately differ from. | Composer behaviour, model picker, conversation list grouping, share sheet placement, voice mode entry point. |
| **SillyTavern** | Closest functional cousin (RP-focused, cards, world info, branches). The CONTRARY example — what to *avoid* (over-dense, over-customisable). | How they handle the same per-turn surface RPClient has (regen / swipe / continue / delete / branch). What's busy vs. what works. Cast / world-info disclosure patterns. |
| **Apple Messages.app** | The macOS-native reference for "chat feel." If our chat doesn't feel at least *as* native as Messages, the look is wrong. | Message bubble vs no-bubble (Messages uses bubbles; AI clients mostly don't — note the trade-off), composer bar, scroll-position behaviour on send, header density (one row vs ours' multi-row). |

**Tier 2 — secondary references (capture lighter, ~5-10 minutes each).**

| App | What we want |
|---|---|
| **LibreChat** | Another OSS multi-model client. How they handle multi-provider switching, conversation forking. |
| **Anthropic Workbench** (https://console.anthropic.com/workbench) | Developer-side chat. Dense parameter sidebars, per-turn token meta. |
| **Cursor** | Inline AI chat panel. How a chat pane fits *inside* a productivity tool. |
| **Slack** / **Discord** | Channel-list + message-stream patterns. Sidebar hierarchy, unread treatment. |
| **Linear** (already in design language §11) | Calm motion, per-row hover controls, density, command palette. Re-capture only the chat-adjacent surfaces (issue comments). |

**Tier 3 — explicitly NOT for this pass (out of scope).**
- Mobile chat apps (iMessage on iPhone, Telegram, WhatsApp). Mobile patterns don't translate cleanly to mac density.
- Pure-form productivity tools we already mined (Things, Notion, Stripe Dashboard) — covered by the existing design language; capturing again is redundant unless they have chat-specific surfaces we missed.

### 3.2 Per-app capture protocol

For each Tier-1 app, capture the following structured set. For Tier-2, abbreviated capture (just the highlights).

**Capture method.** Where possible, take **annotated screenshots** of the live app. Where the app is web, the Claude_in_Chrome tooling can navigate, screenshot, and inspect — use it. Save screenshots to `docs/research/ui-overhaul/<app-name>/` as PNGs with descriptive filenames (e.g. `openwebui-message-hover-controls.png`). Annotate inline in the research doc, not on the image (so the doc stays editable; the image stays canonical).

**For each app, capture:**

1. **Resting state — full chat window.** What's permanently visible. Note every chrome element + its size. This is the "earned-permanence" inventory.
2. **Per-message hover state.** Float over a message — what controls appear? Where? What's their visual weight? Animation timing? (Approx; just describe.)
3. **Per-message focus / selected state.** Click into / select a message — does anything else surface?
4. **Composer bar.** Idle, focused, mid-typing, while assistant is streaming. Send button placement + state. Attachment / model-switch entry points.
5. **Conversation list (sidebar).** Empty state, populated state, grouping logic (date? folder?), search affordance, drag-reorder?, hover row state.
6. **Settings / preferences entry point + first level.** How deep is the most common knob?
7. **Variant / regen / branch UI.** Specifically: what does "regenerate" look like? Multiple variants (ChatGPT/Claude both have ◀/▶)? Branching tree (if any)?
8. **Streaming + cancel UI.** What does in-progress look like? How does the user stop?
9. **Empty state of a brand-new chat.** First impression — do we feel "ready to type" or "confused about where to start"?
10. **Error states.** Server unreachable, refusal, rate-limit. Tone + visual treatment.

**For each captured pattern, note:**
- **What.** One-sentence description.
- **Where it lives.** (Hover-revealed, permanent, in a popover, behind a `…` menu, etc.)
- **Why it works** (or doesn't). One-line opinion.
- **Steal? Ignore? Inverse?** Marked verdict.

### 3.3 Specific cross-app questions to answer

The capture is a means; these questions are the end. Each gets a section in the research doc with the cross-app evidence.

1. **How are per-turn controls surfaced?** Always-visible vs hover vs focus vs `…` menu. RPClient retains the function (user said so); the question is the *look*.
2. **Bubbles vs no-bubbles.** Messages uses bubbles (sender-oriented, color-coded). Open WebUI / Claude / ChatGPT all use no-bubbles (transcript-oriented, indent-only). Which posture is right for RP, where the assistant *is* a character (almost like a sender)?
3. **Header density.** What's permanently above the chat? RPClient currently has Server + Attribution + Voice + speaker mute (anti-pattern §10). What do the references show as the floor? The ceiling?
4. **Conversation-list hierarchy.** Date-grouped (Today / Yesterday / Last week) vs flat-with-search vs folders. RPClient is flat today — is that right for character-shaped chats (where folders-by-character would be a natural grouping)?
5. **Variant navigation.** ChatGPT uses inline `◀ 1/3 ▶`; Claude uses a small accordion; Open WebUI [verify]. RPClient currently uses ◀ / ▶ in the gutter — keep, or move?
6. **Streaming feedback.** Cursor inside the message? Spinner in the header? Bottom-of-message progress? What feels "alive" without being noisy?
7. **Composer affordances.** Just text input, or model-switch / attachment / persona-switch in the composer too? RPClient has those one click away in the chat header today — should they be promoted to the composer?
8. **Markdown rendering.** Code blocks, lists, headers, italics, `<think>` blocks. Which apps render them inline vs collapse them? (`<think>` is the obvious one — Claude collapses, Open WebUI [verify], ChatGPT n/a.)
9. **Long-message behaviour.** RPClient assistant turns can be 500-1500 chars. How do other apps handle long messages? Collapse with "show more"? Just let scroll? Render fully?
10. **Empty-conversation onboarding.** Do they show suggestion chips? Recent characters? Just a blank canvas?

### 3.4 Research deliverable

**File.** `V2_PHASE11_UI_RESEARCH.md` (mirrors `V2_PHASE9_AI_ASSIST_RESEARCH.md` / `V2_PHASE10_CHAT_TUNING_RESEARCH.md` naming).

**Shape.**
1. Scope + method note (1 paragraph) — links back to this plan §3.
2. **§A — Per-app sections** (Tier 1 first, Tier 2 abbreviated). Each section: ~10 captured patterns per app per §3.2; each pattern with What / Where / Why / Verdict.
3. **§B — Cross-app pattern table** answering each of §3.3's 10 questions. Cite which apps support which side of each question.
4. **§C — Synthesis: directional recommendations for RPClient's chat pane.** Explicitly opinionated. "Adopt no-bubbles transcript layout because [X / Y / Z apps converge on it for AI chat; Messages.app's bubbles work because of the sender-equivalence assumption that doesn't hold for character-shaped RP]." This section feeds §4.
5. **§D — Open questions** flagged for the design pass to resolve (things research couldn't answer alone — typically subjective taste calls).
6. **§E — Screenshot index** — list of every captured PNG with one-line caption.

**Definition of done for the research phase:**
- ✅ All 5 Tier-1 apps captured per §3.2 (10 patterns each, ~50 total).
- ✅ Tier-2 apps abbreviated capture (3-5 patterns each).
- ✅ All 10 §3.3 cross-app questions answered with cited evidence.
- ✅ §C synthesis section is opinionated — not a balanced summary.
- ✅ At least one verdict per captured pattern (steal / ignore / inverse).
- ✅ Screenshot folder populated, indexed in §E.

**Estimated effort.** ~½–1 day. Most of the time is the capture (Tier-1 apps need to be open + interacted with). Synthesis (§C) is the load-bearing thinking; budget ~2 hours for that alone after captures land.

### 3.5 What this research is NOT

- Not a vibe doc. "I like Open WebUI" is not a finding; "Open WebUI surfaces regen as a hover icon at the message's leading edge with a 100ms fade, distinct from the trailing `…` menu that holds copy/edit — splitting low-friction destructive-but-undoable (regen) from low-friction non-destructive (copy) reduces accidental regens" is a finding.
- Not a redesign. The research surfaces patterns; the per-surface plans (§4+) propose the actual RPClient-specific shapes.
- Not exhaustive. Tier-3 explicitly excludes mobile + pure-form tools. If something interesting surfaces there incidentally, note it; don't go hunting.
- Not unconstrained. Every recommendation in §C must be implementable within [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md)'s tokens (typography scale, spacing tokens, motion budget). If a recommendation requires an out-of-scale value or 400ms motion, flag it as an open question for the design language doc to absorb separately.

---

## 4. Phase 11.a — Chat pane redesign

**Status: SPEC'D 2026-05-09; ready to sub-step.** Highest-priority surface per the user's guidance; everything else waits. This section is the consumable design contract — sub-steps 4.a-4.j (§4.11) are what the implementation phase executes against.

### 4.0 Locked decisions from research §D + design pass

Decisions made before sub-stepping. Each carries a one-line rationale; everything implementable inside [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) tokens.

| # | Decision | Source / rationale |
|---|---|---|
| 4.0.a | **No-bubbles for assistant turns; subtle background bubble for user turns.** User-turn bubble uses `controlBackgroundColor` at `--bubble-radius` 14pt; not a Messages tail. | Resolves [research §D.1](V2_PHASE11_UI_RESEARCH.md). 7 of 9 references converge on no-bubbles; user turn gets *some* visual distinction without breaking the transcript metaphor. |
| 4.0.b | **Avatar gutter is `xl` (32pt).** Avatar is a 32pt circle in a 32pt-wide leading gutter, top-aligned to the first text line, separated from prose by `sm` (8pt). | Resolves [research §D.2](V2_PHASE11_UI_RESEARCH.md). Sketched both options in `docs/research/ui-overhaul/sketches/avatar-gutter.html`; user picked B. Character-presence > restraint, fits "chat-feel, not form-feel" north-star. |
| 4.0.c | **User-side avatar + persona caption are symmetric to assistant side** (32pt gutter, name caption above bubble), avatar background uses `secondaryLabelColor` (not the user's persona accent — too loud at 32pt). | Resolves [research §D.3](V2_PHASE11_UI_RESEARCH.md) by making the user's persona a first-class scene participant. Important for multi-persona scenes where the user switches personas mid-chat. |
| 4.0.d | **Variant navigation is a small pill under the assistant turn** (`◀ 1/3 ▶`), always visible (not hover). Replaces today's gutter-arrow chrome. | Resolves [research §D.5](V2_PHASE11_UI_RESEARCH.md). SillyTavern + Open WebUI both keep visible; Claude's pill shape is the cleanest visual; ChatGPT's removal regression is the counter-data-point. |
| 4.0.e | **Persona / model / server / voice all move OUT of the chat header and INTO the composer's leading-top area as labelled pills.** Pills order left-to-right: Persona, Model, Server, Voice. | Resolves [research §D.6](V2_PHASE11_UI_RESEARCH.md) directionally. Single composer row at default window width (≥1100pt); below that, Voice collapses into a `…` overflow pill. Min window width ≥900pt for chat pane. |
| 4.0.f | **Branches: keep both inline + inspector.** A small "branches: 3 ▸" pill appears on diverging messages opening the existing Branches inspector. No tree drawn inline. | Resolves [research §D.8](V2_PHASE11_UI_RESEARCH.md). Inline is good for low N; inspector scales; surfacing the count as a pill avoids blind discovery. |
| 4.0.g | **`Theme.swift uiFontOffset` removal lands as part of sub-step 4.j (cleanup), not as a separate phase.** macOS Dynamic Type covers the same axis. | Resolves [research §D.9](V2_PHASE11_UI_RESEARCH.md). |
| 4.0.h | **`✦` custom glyph migration to `person.crop.circle` lands as part of 4.b (TurnView re-skin)** — that's where the avatar gutter is implemented. | Resolves [research §D.10](V2_PHASE11_UI_RESEARCH.md). |

Still open, deferred for later sub-steps or follow-on phases:

- **§D.4 — Pinned-conversations strip in sidebar.** Belongs to §7 (sidebar redesign), not chat pane. Decide alongside Folders spec.
- **§D.7 — Group-chat speaker affordances inline vs. inspector-only.** Belongs to a §4.k follow-up after the single-character chat pane lands. SillyTavern's per-member icons are the only existing reference; needs a usability call against real RP scenes once 4.a-j are in place.

### 4.1 Anatomy

Single chat pane, three vertical zones (top to bottom): **Header · Transcript · Composer**. No status bar in the chat pane — global app status (server reachable, dictation active) lives in the existing app-level [StatusBar.swift](Sources/RPClientCore/UI/StatusBar.swift), which stays.

```
┌─ Chat header (1 row, ≤3 controls) ──────────────────────────┐
│  Mia · with Kevin                                  ⓘ  …      │
├─ Transcript (scroll, content max 720pt, centred) ────────────┤
│                                                              │
│   [M]  Mia · 2:14 PM                                         │
│        She glances up from her book…                         │
│        ◀ 1/3 ▶                                               │
│                                                              │
│   [K]  Kevin                                                 │
│        ╭──────────────────────────────╮                      │
│        │  Got held up at the station… │                      │
│        ╰──────────────────────────────╯                      │
│                                                              │
│   [M]  Mia · 2:14 PM                                         │
│        ▸ Thought for 2 seconds                               │
│        She closes the book without marking the page…         │
│        [⧉ ⟲ ✎ ⑂ ⋯]   ← hover-revealed                       │
│                                                              │
├─ Composer (multi-line text + leading pills + trailing send) ─┤
│  ┌──────────────────────────────────────────────────────────┐│
│  │ Persona: Kevin ▾   Model: Qwen3.6 ▾   Server: kobold ▾   ││
│  │                                                          ││
│  │  Type a message…                              📎 🎙 ➤   ││
│  └──────────────────────────────────────────────────────────┘│
└──────────────────────────────────────────────────────────────┘
```

Inspector pane (Memory / World / Cast / Branches / Tree / Suggestions) sits to the trailing edge of this whole stack as today; not redesigned here (§6 is its own phase).

### 4.2 Header anatomy (one row, ≤3 visible controls)

Replaces today's multi-row Server + Attribution + Voice + speaker-mute anti-pattern (per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md)).

| Region | Content | Tokens |
|---|---|---|
| Leading | Chat title (editable on click). Below it (subhead, secondary): `with <user persona>` so the scene framing is one-glance. | Title `headline` (13pt semibold). Subhead `caption1` (10pt, `secondaryLabelColor`). |
| Trailing | `ⓘ` Inspector toggle (toggles the trailing inspector) · `…` Chat-scoped overflow (rename / export / duplicate / delete / share). | Both `NSButton.bezelStyle = .toolbar`, `controlSize = .small`. |
| Background | Glass — sits on the same Liquid Glass plane as the AppKit toolbar (do not add an extra `NSVisualEffectView`). | Per [V2_DESIGN_LANGUAGE.md §5](V2_DESIGN_LANGUAGE.md). |
| Height | 36pt total. Single row. | `lg` outer padding implicit via toolbar metrics. |

**Removed from header:** Server picker, Model picker, Voice picker, speaker-mute. All migrate per §4.0.e (composer pills) or §4.4 (per-character mute → hover-icon over avatar).

### 4.3 Transcript: turn rendering

Max content width: **720pt**, centred in the available transcript area. Below 720pt window width, content fills 100% with `lg` (24pt) horizontal padding.

**Vertical rhythm.** `md` (16pt) gap between turns. `sm` (8pt) gap between turn header (name + timestamp) and body. `xs` (4pt) gap between body and trailing affordances (variants pill, hover bar).

**Assistant turn (no-bubbles).**
- Layout: `[32pt avatar gutter] [sm gap] [body content]`. Avatar top-aligned to the cap-height of the first body line.
- Avatar: 32pt circle, [SpeakerColor](Sources/RPClientCore/UI/SpeakerColor.swift)-derived background, 13pt semibold initial OR character image if available. Replaces `✦` glyph (§4.0.h).
- Header line: speaker name `headline` (13pt semibold, `labelColor`) · separator dot · timestamp `caption1` (10pt, `tertiaryLabelColor`).
- Body: `body` (13pt regular, `labelColor`). Italics render in `secondaryLabelColor` to carry the action-not-speech vibe natural to RP markup. Code blocks, lists, tables per existing [Markdown.swift](Sources/RPClientCore/UI/Markdown.swift).
- Trailing: variants pill (always visible, §4.5), hover bar (§4.4).

**User turn (subtle bubble, per §4.0.a/c).**
- Layout: same `[32pt gutter] [sm gap] [body]` as assistant — symmetric.
- Avatar: 32pt circle, `secondaryLabelColor` background, persona initial in `windowBackgroundColor`.
- Caption above bubble: persona name `caption1` (10pt, `secondaryLabelColor`), `xs` (4pt) margin below.
- Bubble: `controlBackgroundColor` background, 14pt corner radius, `sm` vertical + `md` horizontal padding. Inline-block layout (only as wide as content), max `--content-w`. No tail.
- Hover bar: edit + delete + `…` (no regen on user turns; that's an assistant-turn affordance).

**Indentation / alignment.** Both sides left-aligned to their gutter. The user side is *not* right-aligned (Messages convention) — that breaks the no-bubbles transcript metaphor and stops the avatar gutter from being symmetric.

### 4.4 Per-turn controls

**Hover bar** (assistant turns): `[copy] [regenerate] [edit] [branch] [⋯]`. Five primary icons, trailing edge under the body (not floating over). Reveal: `mouseEntered` on the turn row, fade-in 120ms `linear` per [V2_DESIGN_LANGUAGE.md §8](V2_DESIGN_LANGUAGE.md). Each button: 24×22pt, `NSButton.bezelStyle = .toolbar`, SF Symbol at `.medium` scale. Keyboard reachability via `tab` cycle when the row is focused.

**Hover bar** (user turns): `[edit] [delete] [⋯]` — three. No regenerate; no branch (editing creates a branch implicitly per Open WebUI semantics).

**`⋯` overflow** (≤4 items, never more): `Pin · View raw · Copy as quote · Delete` (assistant). `Pin · View raw · Copy as quote` (user). Items beyond this list move to inspector or per-chat settings.

**Right-click context menu**: mirrors the hover bar + overflow exactly. Free in AppKit; gives the right-click-trained user the same affordances. Native macOS convention.

**Variants pill** (§4.0.d): always-visible, `[◀] 1/3 [▶]`, ~`xs`+`sm` padded, capsule-shaped. Sits under the body, `xs` gap. Hidden when `count == 1`. Click `◀`/`▶` to swap variant; double-click on the count to jump-edit (Open WebUI's discovery, §A.1.6 of research).

**Branches pill** (§4.0.f): "branches: 3 ▸" appears next to the variants pill *only if* the message diverges. Click opens the existing Branches inspector pane, scrolled to this message's branch.

**Per-character mute** (replacing the chat-header mute): hover-revealed icon overlay on the assistant avatar. Click toggles voice playback for that character within this chat. Persisted per-(chat, character).

### 4.5 Streaming + cancel

Three-stage feedback per [research §C.5](V2_PHASE11_UI_RESEARCH.md):

1. **Pre-token** (Send → first token, typically 200-2000ms on local models): a placeholder assistant turn appears immediately at the next transcript position with the speaker's avatar and a typing-dots indicator (three dots, animated, `secondaryLabelColor`). Apple Messages convention.
2. **Streaming**: dots vanish; tokens stream in; a thin caret (`▍`) renders at the end of the streamed text, at `controlAccentColor`. Claude convention.
3. **Cancel**: a "Stop response" pill appears bottom-centre of the transcript area, ~12pt above the composer. Capsule shape, `controlAccentColor` border, `secondaryLabelColor` text. Click cancels the request.

**No header spinner.** **No send-button morph.** The transcript carries all streaming state.

**Group-chat round (multi-character):** placeholder turn renders for the *first* speaker the Director picks; subsequent speakers create their own placeholder turns as the Director resolves them. The Stop pill cancels the entire round, not just the active speaker.

### 4.6 Empty state

Per [research §C.7](V2_PHASE11_UI_RESEARCH.md): three stacked suggestion chips, character-sourced.

- Vertically centred in the transcript area.
- Top: large 64pt avatar of the active character.
- Below avatar: character name `title2` (17pt regular).
- Below name: scenario one-liner `body` (13pt, `secondaryLabelColor`), max 2 lines.
- Composer below.
- Below composer: 3 suggestion chips, stacked, each two-line: title `headline` + sub-line `subheadline` (`secondaryLabelColor`).

**Chip seed sources** (in priority order):
1. The character's `example_messages` field — extract the first user line of each example pair, framed as the chip title; the assistant's first line becomes the sub-line preview.
2. The character's `scenario` field — broken into 2-3 hooks if present.
3. Static fallbacks: "Start the scene" / "Continue from where we left off" (only if no `example_messages` / `scenario`).

Click a chip: prefills the composer with the chip's full text; user can edit before sending.

### 4.7 Markdown + `<think>` rendering

**Markdown:** unchanged from current — keep [Markdown.swift](Sources/RPClientCore/UI/Markdown.swift) behaviour. Inline rich rendering for headers, lists, tables, code blocks, italics, bold, links, math.

**Italics in RP context:** re-tinted to `secondaryLabelColor`. RP authors use `*action*` semantics; the secondary tone reads as "narration aside, not dialogue" without losing the italics. Speech (unmarked) stays at `labelColor`.

**`<think>` blocks:** collapsed disclosure, per Claude pattern. Renders as an inline pill: `▸ Thought for X seconds` in `caption1` (10pt) `secondaryLabelColor` with `controlBackgroundColor` background, 6pt radius, `xs/sm` padding. Click expands inline (animated 220ms `easeInOut` per [V2_DESIGN_LANGUAGE.md §8](V2_DESIGN_LANGUAGE.md)) to show the thinking content in `secondaryLabelColor` body text. Sub-second thinking (<1.0s) suppresses the disclosure entirely — too noisy.

The `<think>` open/close transition must NOT cause the transcript to scroll-jump (§4.8).

### 4.8 Layout stability rules

The "polished, not glitchy" north-star concretised. These are bug-free invariants the implementation enforces:

1. **No scroll-position loss on send.** When the user sends, the placeholder turn appears at the bottom; if the user was at-bottom, follow the new content. If the user had scrolled up (reading history), do NOT auto-scroll — pin scroll position absolutely. Surface a "↓ N new" pill at the bottom-right of the transcript instead.
2. **No scroll-jump on streaming token-land.** As tokens arrive, the message height grows. If the user is at-bottom, follow the growth (continuous scroll). If the user has scrolled up, pin position; the at-bottom-pill counter increments per token chunk.
3. **No jump on `<think>` expand/collapse.** The disclosure animation grows the row in place; surrounding rows must not reflow visibly. Achieved via per-row height animation, not full-transcript re-layout.
4. **No flicker on inspector toggle.** Toggling the trailing inspector resizes the transcript width; line wraps recompute. Must complete inside the 180ms `easeOut` window without intermediate layout passes that white-flash.
5. **No glitchy redraws on window resize.** Full re-wrap is expected; but it must not double-layout (once for the resize event, once for the wrap-recompute). Single layout pass.
6. **No control collisions when inspector toggles.** The composer's pill row must wrap cleanly when width drops below the layout-test threshold (≥900pt: pills inline; 700-899pt: pills wrap two rows; <700pt: pills collapse into a single `…` overflow). Defined explicitly so the implementation doesn't produce visual glitches at intermediate widths.

These get a TestKit suite under [Tests/RPClientCoreTests/UILayout/](Tests/RPClientCoreTests/) — not pixel-snapshot, but: scroll position invariants, height-growth on streaming, expand/collapse layer math.

### 4.9 Composer

**Layout.** Two-row stack inside a single rounded container:

- Row 1 (pills): `[Persona: Kevin ▾]  [Model: Qwen3.6 ▾]  [Server: kobold-loc ▾]  [🎙 Voice: Standard ▾]`. Labelled pills (LibreChat pattern, [research §A.6.3](V2_PHASE11_UI_RESEARCH.md)). Each pill: capsule shape, `caption1` label, `controlBackgroundColor` bg, click opens an `NSPopover` with the picker. Pills are `mini`/`small` size, never `regular` — they're metadata, not actions.
- Row 2 (input + actions): multi-line `NSTextView` with placeholder `Type a message…`. Trailing icon row inside the input's same plane: `📎` attachments, `🎙` dictation, `➤` send. Send is `controlAccentColor`-tinted when text is present, `tertiaryLabelColor` when empty. `↩` keystroke sends; `⌥↩` inserts a newline.

**Container.** Rounded rect 12pt corner radius, `controlBackgroundColor` background, sits at the bottom of the chat pane with `md` padding from the edge. Container max width matches transcript content width (720pt centred); below that, fills with `lg` margins.

**Width-responsive collapse** (§4.8.6): pills row collapses to a single `…` opener at <700pt window width, opening a popover with all pills stacked.

**Slash commands and `@`/`#` mentions:** deferred — not in scope per [research §C](V2_PHASE11_UI_RESEARCH.md) and [V2_DESIGN_LANGUAGE.md §11](V2_DESIGN_LANGUAGE.md) "what we deliberately don't borrow."

### 4.10 Long messages, errors

**Long-message behaviour** (§C.6): render fully, never auto-collapse. RP turns are 500-1500 chars — far below any reasonable collapse threshold. Code blocks longer than 320pt get inline scroll (existing Markdown.swift behaviour).

**Error states** (per [research §A.3.10](V2_PHASE11_UI_RESEARCH.md)): server unreachable / refusal / rate-limit render as a small inline notice attached to the failed assistant turn (replacing the streaming caret). Notice contains: red `exclamationmark.triangle` SF Symbol, brief error text (`subheadline`, `secondaryLabelColor`), inline `Retry` button. NEVER modal-alert a transient send failure.

Refusal-detected (Phase 8 §QuirkDetectors) gets a yellow `exclamationmark.triangle` plus the existing inline-notice grammar — Yellow vs Red distinguishes "model declined" from "transport failed."

### 4.11 Implementation sub-stepping

Sub-steps. Originally planned as 10 (4.a-4.j); ran longer in practice as several were split mid-execution to keep diffs focused. Current state below — done / in-progress / pending.

| Sub | Title | Status | What |
|---|---|---|---|
| 4.a | DesignTokens chat extensions | ✅ done | `Chat` namespace on `DesignTokens`: `transcriptMaxWidth`, `avatarSize`, `avatarGutter`, `avatarToBodyGap`, `turnGap`, `bubbleRadius`. `Phase11ChatTokensTests` pins values + no-fork aliasing rule. |
| 4.b.1 | TurnView data + speaker header + ✦→symbol + italic tint | ✅ done | `Markdown.extractThinking` splits trace from body; `stripThinking` becomes a wrapper. Italics in `Markdown.render` re-tinted to `secondaryLabelColor`. Always-on speaker name + timestamp header on assistant turns. `✦` glyph → `person.crop.circle` SF Symbol. Tests: `Phase11ThinkExtract` (10) + `Phase11ItalicTint` (3). |
| 4.b.2 | `<think>` disclosure UI | ✅ done | `▸ Thinking` capsule above the bubble body that expands inline. `bubbleTopConstraint` ivar swapped via `disclosureExtraHeight(...)` — pinned by `Phase11ThinkDisclosureHeight` (5). |
| 4.c | User-turn symmetric layout | ✅ done | User turns flipped left-aligned; 32pt avatar gutter + persona caption above bubble. `userTurnDisplayName(personaName:settingsUserName:)` resolver pinned by `Phase11UserDisplayName` (6). |
| §D.11 | `<think>` trace side-channel detour | ✅ done | `TurnVariant.thinkingTrace: String?` carries the captured trace per-variant. `ThinkBlockFilter.capturedTrace` + AppState stream-finish persist + ChatViewController push from `handleStreamFinished` and `handleChatUpdated` (variant pager). Tests: `Phase11ThinkTraceCapture` (10) + `Phase11ThinkTracePersistence` (7). Memory note: `feedback_turnview_lifecycle.md`. |
| 4.d.1 | Per-turn controls toolbar restructure | ✅ done | Toolbar slimmed to role-dependent primary set + `⋯` overflow. Variants pill broken out (always-visible). Right-click context menu mirror via `textView(_:menu:for:at:)` delegate hook. `overflowItems(role:isLastAssistant:variantCount:)` pinned by `Phase11OverflowMenu` (6). textView read-only by default — edit mode entered explicitly via the edit button (selection + Cmd-C still work). |
| 4.d.2 | Branches pill | ✅ done | `branches: N ▸` capsule next to variants pill on diverging messages. Replaces gutter glyph. `CapsulePill: NSStackView` subclass auto-adapts light/dark via `updateLayer()` + `accentBackground` flag. `branchesPillTitle(siblingCount:)` pinned by `Phase11BranchesPill` (4). |
| 4.e.1 | Typing-dots indicator | ✅ done | `TypingDotsView` — three pulsing circles with phase-shifted opacity animation. Replaces "Thinking…" italic-text body + avatar opacity pulse. Shown when `isThinking || (isStreaming && rawText.isEmpty)`. |
| 4.e.2 | Streaming caret | ✅ done | Thin `▍` glyph in `controlAccentColor` appended at end of streamed body while `isStreaming`. Removed automatically next render after `isStreaming` flips false. |
| 4.e.3 | Stop response pill | ✅ done | NSButton bottom-centre 12pt above InputBar; visible during streamStarted → streamFinished. Click → `AppState.shared.stop()`. (As of 4.g.2 this is the only cancel affordance — the InputBar morph has been removed.) Plus `AppState.thinkingReplyTokenCap = 4096` (vs 2048 default) when `thinkingActive`, with `[chat-pane] reply-budget:` log line per stream. |
| 4.h.1 | Empty-state restructure | ✅ done | Bifurcated layout: 64pt avatar + character name + scenario top-anchored; chips bottom-anchored above composer. SF Symbol fallback for free-form chats. InputBar height cap 220→260 to accommodate the new pill row added in 4.g.1. |
| 4.j.1 | Cleanup orphan NSButton ivars | ✅ done | Removed `replayButton`, `continueButton`, `discardVariantButton` ivars + their target/action wiring + dead isHidden/isEnabled flips. Selectors stay (used by overflow NSMenu items). |
| 4.h.2 | Chip seeding from character data | ✅ done | `EmptyStateView.chipSeeds(for: character)` resolves alts → scenario → static fallback. `Phase11ChipSeed` (9). Note: §D.14 — alts-as-chips surface area is narrow because firstMessage seeds turn 0 and suppresses the empty state for character chats. |
| 4.g.1 | Composer pill row + relocate pickers | ✅ done | `InputBar.pillRow: NSStackView` + `setMetadataPills(_:)` API. Server / Voice / Attribution pickers + speaker mute relocated from chat header. Chat header reduced to 8pt strip (4.f fills it later). |
| 4.g.2 | Send-button morph removal | ✅ done | InputBar's primaryButton is now a pure send affordance — no `.send`/`.stop` flip, no `PrimaryAction` enum. Disabled while busy (`isStreaming || isSummarizing || isExtracting`) or empty; tinted accent when sendable, tertiary otherwise. `InputBarDelegate.inputBarStop` removed (orphaned by §4.e.3 Stop pill, which calls `AppState.shared.stop()` directly). |
| 4.g.3 | Width-responsive pill collapse | ✅ done | `FlowPillRow: NSView` replaces the old `pillRow: NSStackView`. Uses manual frame-based layout driven by [`PillFlow`](Sources/RPClientCore/UI/PillFlow.swift) (pure helper, unit-tested via `Phase11PillFlow` × 14). Three modes per §4.8.6: `.inline` (≥900pt) single row · `.wrap` (700–899) greedy 2-row split · `.collapsed` (<700) single `ellipsis.circle` button → NSPopover with pills stacked vertically. Transitions log via `[chat-pane] pillRow mode X→Y width=N pills=K`. Empty pills → 0 intrinsic height (preserves pre-§4.g geometry). Note: spec band-edges are 900/700, not the 1100/700 placeholder previously in this row. |
| 4.g.4 | Persona pill (NEW UI) | ✅ done | `PersonaPill` (NSView) leading-most in pillRow. Title face: `Persona: <name>` or `Persona: None` (dimmed). Click → NSPopover with vertical stack: "No persona" row + one row per `AppState.personas` (semibold name + secondary description, ✓ marker on current). Click row → `updateCurrent { c.personaId = … }`; popover dismisses; refresh fires via `chatUpdated`. Self-bound to `currentChatChanged` / `chatUpdated` / `personasChanged`. Pure-data title resolver `PersonaPillTitle.resolve` unit-tested via `Phase11PersonaPill` × 4. Empty personas list shows a "open the library" hint instead of just the None row. Visual style matches existing pickers (`bezelStyle = .rounded`, `Theme.font(11)`); §4.9 capsule-pill restyle is a separate future pass. |
| 4.f | Header collapse | ✅ done | `ChatHeaderView` replaces the empty 8pt strip with a 36pt one-row header per §4.2. Leading: editable title (13pt semibold; click → cursor, Enter commits via `updateCurrent { c.title = … }`, Esc reverts) + `with <persona>` subhead (10pt secondary, hidden when no persona bound). Trailing: ⓘ inspector toggle (routes via responder chain to `AppDelegate.toggleInspector`) + ⋯ chat overflow with Rename / Delete chat…. Subhead resolver `ChatHeaderSubtitle.resolve` is pure-data + unit-tested via `Phase11ChatHeaderSubtitle` × 4. View self-binds to `currentChatChanged` / `chatUpdated` / `personasChanged`; refresh skips clobbering the title field while it's first responder. Background transparent — sits on the AppKit toolbar's glass. |
| 4.i | Layout-stability TestKit suite | ✅ done (partial) | `ScrollFollow.userIsScrolledUp(docHeight:visibleBottomY:threshold:)` lifted out of `ChatViewController.handleScroll`; `Phase11LayoutStability` × 8 covers §4.8 invariants 1 + 2 (scroll-pin on send / streaming-token-land), threshold semantics, negative-dist clamp, empty-doc edge. ChatViewController refactored to call the helper so the test pin matches production. §4.8 invariants 3-5 (think-toggle reflow, inspector-toggle flicker, resize layout-pass count) need an NSWindow harness which the CLT-only test runner can't host — explicitly documented in the test file's header comment. §4.8.6 (pill-row collapse) covered separately by `Phase11PillFlow`. |
| 4.j.2 | `uiFontOffset` removal | ✅ done | `Settings.uiFontOffset` (field + Codable encode/decode + CodingKeys + initializer arg + default) gone. SettingsWindowController loses the stepper + field + label + change handlers + the "Appearance" section header that gated only this control (replyTokens row stays, sits directly after the preceding separator). `Theme.fontOffset` getter removed; `Theme.size(_:)` simplified to `max(8, base)`. `AppNotification.fontChanged` notification name + observers across InputBar / ChatViewController / StatusBar / 6 Inspector panes left in place — they're forward-compatible with the macOS Dynamic Type adoption (separately pending) which will repost the same signal on OS-level metric changes. Test fixtures with `"uiFontOffset"` left as legacy-JSON migration smoke (Codable silently ignores; tests still pass at 1150/1150). |
| 4.k | Per-character mute toggle in speaker header | ✅ done | §D.13 spec changed during build — instead of a hover-icon over the avatar, the toggle landed inline in the assistant speaker header (`<name> · <time> 🔉`) so the on/off state is legible at-a-glance without hovering. Tap-target is an NSImageView with NSClickGestureRecognizer (NSButton's cell metrics floated the symbol above the timestamp baseline). `Chat.mutedCharacterIds: Set<UUID>` + `isMutedCharacter(_:)` helper land via Codable migration (decodeIfPresent → empty set; default-init empty); covered by `Phase11MutedCharacters` × 6 (helper + legacy-JSON decode + round-trip). Speaker.swift skips TTS in `speakAssistantLeaf` when the resolved speaker character (multi-cast: `turn.speakerId`; solo: `chat.characterId`) is muted; replay path bypasses (explicit user request). TurnView accepts `isMutedCharacter:` init param + push setter `setMuted(_:)` since `handleChatUpdated`'s in-place branch (mute toggling keeps the active path stable). Total tests now 1150/1150. |

**TDD posture per [feedback_tdd_workflow](memory/feedback_tdd_workflow.md):** every pure-data helper got tests-first (see `Phase11*Tests.swift` files). Layout/visual sub-steps land as honest glue/UI smoke — no faked tests. The §4.i layout-stability suite is the next big TDD target.

**Diagnostic logging** per [feedback_diagnostic_logging](memory/feedback_diagnostic_logging.md): permanent `[chat-pane]` prefix on stream-budget logs (`AppState.assembleAndStream`) and thinkingTrace persistence (stream-finish handler). One-shot diagnostics added during smoke iterations get pulled once they've served their purpose.

### 4.12 Out of scope for §4

Things that look chat-pane-shaped but belong to other sub-phases:

- **Inspector pane redesign** (Memory / World / Cast / Branches / Tree / Suggestions) — that's §6, with its own smaller research pass against productivity tools.
- **Sidebar redesign** (date-grouped + Folders) — §7. Chat-pane changes don't break the existing sidebar; sidebar can ship its redesign in parallel or after.
- **Settings tab restructure** — §9. Chat-pane changes don't depend on Settings shape; changes to Server / Voice / Persona pickers happen via popover invocations from the new composer pills, not in Settings itself.
- **Group-chat speaker affordances inline** (§D.7) — defer to a 4.k follow-up after 4.a-j land. Need real RP scenes against the new layout to call placement.
- **Slash commands / `@`/`#` mentions** — deferred per design language §11.
- **Multi-model side-by-side compare** (Open WebUI feature) — out of scope; reconsider in a separate phase if user demand surfaces.
- **Card Creator window** — already gold-standard per Phase 9 §5.3. The chat pane *measures against* it (control sizing, focus/hover treatment, motion budget), but doesn't change it.



---

## 5. Phase 11.b — Chat header (ABSORBED INTO §4)

**Status: merged into §4.2.** The chat header shares the chat-view controller with the transcript and composer; redesigning them together avoids a two-step churn. §4.2 (header anatomy) + §4.0.e (move pickers to composer) fully covers the header. §5 retained as an empty section so the §6+ numbering stays stable.

---

## 6. Phase 11.c — Inspector panes

**Status: STUB.** Memory / World / Cast / Branches / Tree / Suggestions panes need a unified visual grammar (per §10 anti-pattern). Specifics post-research; §3 doesn't cover inspector-shaped panes (those aren't chat-shaped), so this section may need a smaller follow-up research pass against productivity tools (Linear sidebar panels, Cursor sidebar, Notion right-pane).

---

## 7. Phase 11.d — Sidebar (chat list)

**Status: STUB.** Specifics post-research; §3 question 4 (conversation-list hierarchy) drives this.

---

## 8. Phase 11.e — Library window (characters / personas)

**Status: STUB.** Card Creator window is the gold-standard reference; Library is the *list* of cards, which is a different surface. Specifics later — likely after the chat pane ships and we've absorbed the design-language patterns into the rest of the app.

---

## 9. Phase 11.f — Settings window

**Status: STUB.** Already has multiple known issues (servers row bezel-mixing per §10 anti-pattern; the systemPromptAddendum field added 2026-05-09 needs re-housing if Settings gets a tab structure). Defer until the chat pane work has produced a settled control vocabulary.

---

## 10. Phase 11.g — Voice library window

**Status: STUB.** Already flagged in [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md) — should be a Settings tab, not a standalone window. Rehome during §11.f Settings work, not separately.

---

## 11. Phase 11.h — Popovers, sheets, alerts

**Status: STUB.** Cross-cutting. Audited last so the surfaces above can settle their patterns first.

---

## 12. Sequencing + risk notes

Updated 2026-05-10 mid-§4 implementation.

| # | Step | Status | Estimate |
|---|---|---|---|
| 1 | Research (§3) | ✅ landed 2026-05-09 — see [V2_PHASE11_UI_RESEARCH.md](V2_PHASE11_UI_RESEARCH.md) | (½ day) |
| 2 | Chat-pane design pass (§4) | ✅ spec'd 2026-05-09 | (½ day) |
| 3 | Chat-pane implementation (§4.a-4.k) | IN PROGRESS — 4.a, 4.b.1, 4.b.2, 4.c, §D.11 detour, 4.d.1, 4.d.2, 4.e.1, 4.e.2, 4.e.3, 4.h.1, 4.j.1, 4.h.2, 4.g.1, 4.g.2, 4.g.3, 4.g.4, 4.f, 4.i (partial — pure-data only), 4.k, 4.j.2 done. Remaining: 4.i NSWindow harness (deferred — needs Xcode test target). | ~3 days remaining |
| 4 | Inspector (§6) — small research pass + impl | After chat pane lands | 2-3 days |
| 5 | Sidebar (§7) — date grouping + Folders + pinned strip | Can run parallel to inspector | 1-2 days |
| 6 | Settings + Voice rehome (§9, §10) | After 4.g composer pills land (popover targets settle) | 1 day |
| 7 | Library window (§8) | After Card Creator patterns absorb across the app | 1-2 days |
| 8 | Popovers / sheets / alerts (§11) — cleanup pass | Last; after surfaces above settle | 1 day |

Total estimated: ~2 weeks of focused work, sequenced over a couple of months around other phases. Chat pane (item 3) is the highest-impact chunk — sub-steps 4.b (TurnView re-skin) and 4.g (composer redesign) are the two heavy days inside it.

**Risks tracked.**
- 4.b: pixel-stability snapshot diffs will surface false-positives across macOS 26 minor updates; pin the snapshot harness to a specific macOS version or use tolerance-based diffs.
- 4.e: streaming-state bus refactor risks regressing existing typing-cancel paths during multi-cast Director rounds — Phase 8's deferred multi-cast smoke needs to run against the rewrite before declaring done.
- 4.g: composer popover pickers replace the existing Settings → Servers and Settings → Voice flows for the chat-pane case; ensure the underlying state stays single-sourced via the existing `AppState` rather than duplicating state into composer-local controllers.
- 4.i: scroll-position invariants are the existing source of intermittent "blank window covers chat on first send" reports per [memory/project_blank_window_bug](memory/project_blank_window_bug.md); the layout-stability TestKit suite is the load-bearing artefact for finally pinning that down.

---

## 13. References

**Internal:**
- [V2_PLAN.md §8](V2_PLAN.md) — strategic placeholder for this overhaul.
- [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) — platform truth (typography scale, spacing tokens, color, materials, motion budget, application contract).
- `Sources/RPClientCore/UI/CardCreator/` — gold-standard reference implementation (Phase 9 §5.3).
- `Sources/RPClientCore/UI/DesignTokens.swift` — in-code embodiment of the design language. New surfaces import this; do not extend `Theme.swift`.

**External:**
Most of the external references for the *design language* layer are already catalogued in [V2_DESIGN_LANGUAGE.md §13](V2_DESIGN_LANGUAGE.md). The §3 research pass adds chat-surface-specific captures to that catalogue:

- Open WebUI — https://github.com/open-webui/open-webui (and the user's running instance, if applicable).
- Claude.ai — https://claude.ai (web).
- ChatGPT — https://chatgpt.com (web) and the macOS native app if installed.
- SillyTavern — https://github.com/SillyTavern/SillyTavern.
- Apple Messages.app — built into macOS.
- LibreChat — https://github.com/danny-avila/LibreChat.
- Anthropic Workbench — https://console.anthropic.com/workbench.
- Cursor — https://cursor.sh.
