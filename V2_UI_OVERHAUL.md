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

Sub-steps to feed implementation sessions. Each is independently testable; the order minimises rework. Estimated total: 3-4 days focused work.

| Sub | Title | What | Risk | TDD posture |
|---|---|---|---|---|
| 4.a | DesignTokens chat extensions | Add chat-specific tokens to [DesignTokens.swift](Sources/RPClientCore/UI/DesignTokens.swift): `transcriptMaxWidth`, `avatarSize`, `avatarGutter`, `bubbleRadius`, `turnGap`. No raw values in any subsequent sub-step. | Low. | Token presence + value tests — TDD. |
| 4.b.1 | TurnView re-skin (data + header) | Italics-as-secondary tint in `Markdown.render`. New `Markdown.extractThinking` separates `<think>` content from body (test-pinned no-fork against `stripThinking`). Always-on speaker name + timestamp header on assistant turns (replaces multi-cast-only Phase 8 label). `✦` glyph migration to `person.crop.circle` SF Symbol for free-form-chat assistant placeholder. `glyphCol` / `avatarSize` plumbed through `DesignTokens.Chat`. | Low — additive; the disclosure UI is split into 4.b.2. | Phase11ThinkExtractTests + Phase11ItalicTintTests pinned the data path. Visual treatment is honest UI smoke (header / italic tint / avatar fallback) — eyeball on next app run. |
| 4.b.2 | `<think>` disclosure UI | Visual disclosure pill (`▸ Thinking`) above the body that expands inline to show the captured `thinkingText` in `secondaryLabelColor` body. Constraint-heavy because the bubble's top anchor depends on disclosure state (hidden / collapsed / expanded); cleanest implementation switches between two row-anchor constraints or wraps the assistant body column in a vertical stack. | Medium — height-delta math is the bug-prone part. | Test the open/close height delta math + click-to-toggle state. Glue test for visual treatment. |
| 4.c | User-turn subtle bubble | Add user-turn variant to TurnView: 32pt symmetric gutter, persona caption above bubble, `controlBackgroundColor` 14pt-radius bubble. Avatar in `secondaryLabelColor`. | Low. | Layout invariants. |
| 4.d | Per-turn controls | Hover bar with [copy/regen/edit/branch/⋯]; right-click context menu mirror; variants pill (replace gutter chrome); branches pill on diverging messages; per-character mute as hover-icon over avatar. | Medium — hover detection on variable-height rows is fiddly. | Behavioural tests for state transitions; smoke-test the AppKit hover on a real window. |
| 4.e | Streaming refactor | Three-stage: typing-dots placeholder → caret → bottom-centre Stop pill. Remove any header spinner / send-button morph. | Medium — chat controller's streaming-state bus needs the right signals. | Unit tests for state machine; smoke for visible behaviour. |
| 4.f | Header collapse | One-row chat header: title + `with <persona>` subhead + ⓘ + ⋯. Delete server/model/voice/speaker-mute from header. Wire deletions cleanly so the controls' targets don't dangle. | Medium — risk is the deleted controls' wiring still being referenced. | Controller-level tests that the actions still trigger from their new homes. |
| 4.g | Composer redesign | Two-row composer container with pill row (Persona / Model / Server / Voice) + input + trailing actions. Width-responsive collapse rules per §4.8.6. | High — net-new layout, lots of state. | Layout-stability TestKit suite (§4.8); per-pill controller tests; smoke for the popover pickers. |
| 4.h | Empty state | Centred avatar + name + scenario + 3 chips drawn from `example_messages` / `scenario`. Click-to-prefill behaviour. | Low. | Chip seeding logic gets unit tests; visual is glue. |
| 4.i | Layout-stability invariants | TestKit suite for §4.8 rules (scroll-position, no-jump on stream, no-jump on think-toggle, inspector-toggle reflow, resize). Surface "↓ N new" pill on scroll-up state. | Medium — these are the bug-prone invariants users have already complained about. | TDD — write the invariant tests first; let them fail; then fix the controllers to make them pass. |
| 4.j | Cleanup | Remove `Theme.swift uiFontOffset` (no surface still uses it after 4.b). Remove dead chat-header chrome code. Remove `✦` glyph fallback now that 4.b ships avatars. | Low — pure deletion. | Compile + existing tests. |

**TDD posture per [feedback_tdd_workflow](memory/feedback_tdd_workflow.md):** sub-steps 4.a / 4.b (height math) / 4.d (state) / 4.e (state machine) / 4.g (responsive collapse) / 4.h (chip seeding) / 4.i (invariants) all have a clean failing-test target before implementation. 4.b/4.c/4.f visual treatment honestly admits glue/UI smoke is the right test — no faking. 4.j is pure deletion.

**Diagnostic logging** per [feedback_diagnostic_logging](memory/feedback_diagnostic_logging.md): bake `DebugLog.shared.write("[chat-pane] …")` calls at every state transition in 4.e (streaming) and 4.i (scroll-position) from the first commit. Prefix is `[chat-pane]` so future grepping is clean.

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

Updated 2026-05-09 with §4 spec'd and §5 absorbed.

| # | Step | Status | Estimate |
|---|---|---|---|
| 1 | Research (§3) | ✅ landed 2026-05-09 — see [V2_PHASE11_UI_RESEARCH.md](V2_PHASE11_UI_RESEARCH.md) | (½ day) |
| 2 | Chat-pane design pass (§4) | ✅ spec'd 2026-05-09 — sub-steps 4.a-4.j ready to execute | (½ day) |
| 3 | Chat-pane implementation (§4.a-4.j) | NEXT | 3-4 days, sub-stepped |
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
