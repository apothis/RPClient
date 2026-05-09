# V2 UI Overhaul

**Status: planning — research pass not yet executed.** Per V2_PLAN.md §8 — the deferred complete-UI-overhaul doc, foundation laid by [V2_DESIGN_LANGUAGE.md](V2_DESIGN_LANGUAGE.md) (2026-05-07). This doc is the **per-surface migration plan** that builds on top.

The research section below (§3) is fully specified and ready to run as its own session. Per-surface plans (§4 onwards) are stubs — they get populated after the research pass lands actionable findings.

---

## 1. Scope, posture, north-star

### 1.1 In scope
- **Chat pane first** (the load-bearing surface, the part that needs the most). Everything else — chat header, sidebar, inspector, library, Settings, popovers / sheets — comes after.
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

## 3. Phase 11.0 — Reference-app research pass (FULLY SPECIFIED — ready to run)

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

**Status: STUB — populated post-research.** Per the user's guidance, this is the highest-priority surface; everything else waits.

This section will get filled in after §3 lands with:
- Proposed anatomy (header / transcript / composer / status bar — what's where, what's permanent, what's hover-revealed).
- Per-turn rendering (bubbles vs no-bubbles, indent, avatar treatment, name treatment, timestamp treatment).
- Per-turn controls (the user-loved function set — regen / edit / branch / variants / copy / delete / continue) re-skinned per the §3 verdicts.
- Streaming + cancel feedback.
- Empty-state of a fresh chat.
- Long-message behaviour (collapse? render-full?).
- Markdown + `<think>` block rendering.
- Layout-stability rules (no jumps on send, no scroll loss on relayout).

Pre-research placeholders / hypotheses (subject to §3 evidence):
- **No-bubbles transcript layout.** Likely steal from Open WebUI / Claude / ChatGPT. Bubbles read as sender-equivalence; character-shaped RP doesn't have that.
- **Per-turn controls hover-revealed at leading edge of the turn**, with a trailing `…` menu for less-frequent actions. Variants navigation (◀ / ▶) stays inline at the bottom of the turn.
- **Header collapses** to title + collapsed metadata strip; full controls accessed via a `⌥-click` reveal or a "show details" disclosure.
- **Composer bar** stays minimal — text input + send. Model-switch + persona-switch + attachment stay one-click-away (header dropdown or a `+` menu inside the composer).

These are starting points to be confirmed / overturned by §3.

---

## 5. Phase 11.b — Chat header

**Status: STUB.** Currently the worst anti-pattern per [V2_DESIGN_LANGUAGE.md §10](V2_DESIGN_LANGUAGE.md). Specifics post-research; the §3 cross-app evidence on header density (question 3) drives this.

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

(Post-research — populated when §4 lands.)

Initial intuition (subject to revision):
1. Research (§3) — ½–1 day.
2. Chat pane plan (§4) — ½ day after research lands.
3. Chat pane implementation — 2-4 days, sub-stepped.
4. Chat header (§5) — 1 day, immediately after chat pane (they share the chat-view controller).
5. Sidebar (§7) — 1 day, can run parallel to header if a second session.
6. Inspector (§6) — separate small research pass + 2-3 days impl.
7. Settings + Voice rehome (§9, §10) — 1 day combined.
8. Library (§8) — 1-2 days.
9. Popovers / sheets / alerts (§11) — 1 day cleanup pass.

Total estimated: ~2 weeks of focused work, sequenced over a couple of months around other phases. The chat pane is the highest-impact 4-day chunk; everything else is incremental polish on a settled foundation.

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
