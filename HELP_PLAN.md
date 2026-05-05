# RPClient help system — plan

In-app help system with two books: a **User Guide** (task-first, "how do I…") and a **Technical Reference** (system-first, "how does it work"). Same window, same renderer, different TOC. Frozen markdown shipped as bundle resources — content edits happen in source, not at runtime.

**Status as of 2026-05-05.** Slices 1–4 shipped on branch `v2-plan` (25 pages across User Guide + Technical Reference). Slice 5 (V8 multi-server coverage — new `multi-server` page plus stale-prose fixes across 6 existing pages) shipped 2026-05-05 in TDD style: failing TestKit cases first, then content. Future work is content maintenance — keeping the pages in sync with the codebase as features land.

---

## 0. Decisions

Resolved up front so future slices don't relitigate them:

| Question | Decision | Notes |
|---|---|---|
| Surface | In-app `NSWindowController` with TOC + markdown content | Matches the zero-deps offline ethos. Apple `.help` bundle was rejected as overkill. |
| Editability | Frozen — content lives in `Sources/RPClientCore/Help/*.md` | No writable copy in Application Support. Edits go through code review. |
| Search | Included in v1 | Full-text substring filter over loaded markdown; matches highlighted in the rendered page. |
| Screenshots | Skipped for v1 | Prose-only. Deferred until we have a screenshot capture story that doesn't bitrot fast. |
| Content split | Two books in one window (User Guide / Technical Reference) | Switched via the TOC outline; both use the same renderer. |

---

## 1. Architecture

```
Sources/RPClientCore/
├── Help/                          ← bundle resources (frozen markdown)
│   ├── quick-start.md
│   ├── chats-sidebar.md
│   ├── chat-view.md
│   ├── input-bar.md
│   └── status-bar.md
└── UI/Help/
    ├── HelpIndex.swift            ← typed page registry; single source of truth
    ├── HelpRenderer.swift         ← markdown → NSAttributedString + anchor map
    └── HelpWindowController.swift ← TOC outline, content text view, search
```

`Package.swift` declares `resources: [.process("Help")]` on the `RPClientCore` target so `Bundle.module` can resolve the markdown files. `build.sh` copies the SwiftPM-generated `RPClient_RPClientCore.bundle` into `RPClient.app/Contents/Resources/` so packaged builds find the same resources via `Bundle.main` lookup.

### Linking model

Internal links use a custom `rpclient-help:` URL scheme so the `NSTextView` delegate can intercept clicks without touching the system handler:

- `rpclient-help:page-id` — open another page at the top.
- `rpclient-help:page-id#anchor` — open another page scrolled to a heading.
- `rpclient-help:#anchor` — same-page anchor jump.

Anchors are derived at render time from heading text (slug = lowercase + non-alphanumeric → hyphen), tagged on the heading's range via a custom `helpAnchor` attribute, and collected into a `[slug → location]` map per page.

External `https:` links pass through to `NSWorkspace.shared.open(url)`.

### Deep-linking from features

`AppDelegate.openHelp(pageId:anchor:)` is the public entry point. Inspector pane "?" buttons (Slice 2) and Settings tab help icons (Slice 3+) call this. `HelpIndex` is the only place that lists page ids; consumers reference page ids as string literals — ungreppability is OK at this scale, the TestKit suite asserts every registered id resolves.

---

## 2. Sequencing

```
┌──────────────────────────────────────────────────────────────────┐
│  Slice 1   Skeleton + Quick Start             ✅ 2026-05-04      │
│  Slice 2   Memory user guide + ? buttons      ✅ 2026-05-04      │
│  Slice 3a  Tech reference (priority tier)     ✅ 2026-05-05      │
│  Slice 4   Long-tail user guide               ✅ 2026-05-05      │
│  Slice 3b  Tech reference (tier 2)            ✅ 2026-05-05      │
│  Slice 5   V8 multi-server coverage (TDD)     ✅ 2026-05-05      │
└──────────────────────────────────────────────────────────────────┘
```

Why this order:

- **Skeleton first** because every page beyond #1 is wasted work if the renderer or window is wrong. Slice 1 is the structural commitment; later slices are pure content.
- **Memory second** because it is RPClient's differentiator and the area users most plausibly need help with. Adding **?** buttons to inspector panes happens at the same time so help is discoverable in context, not buried under a menu.
- **Technical reference third** rather than last because the load-bearing pages (architecture, prompt assembly, memory pipeline) help future-me pick up the codebase after a long break. They are also the cheapest to write — the prose is mostly already in `MEMORY_AUDIT.md`, `MEMORY_V2_PLAN.md`, etc.
- **Long tail last** because by then the system has been used enough to know which gaps actually hurt.

---

## 3. Slice 1 — Skeleton + Quick Start ✅ shipped 2026-05-04

Landed in a single change on branch `v2-plan`. Section preserved as historical record.

### What shipped

- `Help/` resource directory; `Package.swift` updated with `resources: [.process("Help")]`.
- `HelpIndex` — typed page registry with `pages: [HelpPage]`, `markdown(for:)`, `pages(in:)`.
- `HelpRenderer` — line-based block parser (headings H1–H4, paragraphs, bullet/numbered lists, fenced code blocks). Inline pass for **bold**, *italic*, `code`, and `[label](target)` links.
- `HelpWindowController` — `NSOutlineView` TOC grouped by book, read-only `NSTextView` content with custom link interception, `NSSearchField` filter that hides non-matching pages and highlights matches in yellow on the rendered page.
- `Help` menu in `AppDelegate` (`⌘?`) plus public `openHelp(pageId:anchor:)`.
- `HelpIndexTests` — 4 cases: every registered page loads non-empty markdown, ids unique, every page renders with at least one anchor, slugify is stable.
- `build.sh` updated to copy `*.bundle` from the SwiftPM build output into `RPClient.app/Contents/Resources/`.

### Pages

| Slug | Title | Hook |
|---|---|---|
| `quick-start` | Quick Start | Two-minute path from fresh install to streaming reply. |
| `chats-sidebar` | Chats & sidebar | Creating, switching, deleting chats; sidebar row anatomy. |
| `chat-view` | The chat view | Turns, streaming, editing, swipes, the context divider. |
| `input-bar` | Input bar & token cap | Send/stop, Shift-Enter, per-reply cap override. |
| `status-bar` | Status bar | Model/template label, context fill bar segments, tps, totals. |

### Bug found and fixed during the build

`applyInline` passed a stale `baseRange` to subsequent regex passes after the link substitution shrank the string. First mutation made every following `applyPattern` call throw `NSRangeException`. Fixed by recomputing the search range from the current string length on each pass.

---

## 4. Slice 2 — Memory user guide + Inspector "?" buttons ✅ shipped 2026-05-04

Memory is the differentiator and where users will most plausibly look up "what does this do." Help is most useful when surfaced from the panel itself, so the **?** buttons landed in the same slice.

### Pages shipped

| Slug | Title | Covers |
|---|---|---|
| `memory-pinned-facts` | Memory: pinned facts | What gets pinned, format, token cap, worked example (a character allergy). |
| `memory-summary` | Memory: rolling summary | When the summarizer triggers, how to view/edit, "summarize now" menu item. |
| `memory-authors-note` | Memory: author's note | Free-text + injection depth; example steering tone mid-scene. |
| `memory-world-info` | Memory: world info / lorebook | Keys, secondary keys (AND-gate), match scope, priority, worked example. |
| `memory-suggestions` | Memory: suggestions | Fact extractor side-call, review/approve/dismiss flow, cadence setting. |
| `memory-entities` | Memory: entities | Entity store, on-stage selection, manual edits. |
| `memory-retrieval` | Memory: retrieval | Vector search settings, what shows up in the pane, when to enable. |

### Implementation that landed

- Authored the seven `.md` files; registered in `HelpIndex.pages`.
- Added [HelpButton.swift](Sources/RPClientCore/UI/Help/HelpButton.swift) — one square `(?)` glyph that calls `AppDelegate.openHelp(pageId:anchor:)`. Centralises visual treatment and keeps call sites one line.
- Wired one `HelpButton` into the header of each Inspector pane:
  - [MemoryPane.swift](Sources/RPClientCore/UI/Inspector/MemoryPane.swift) → `memory-pinned-facts`
  - [SummaryPane.swift](Sources/RPClientCore/UI/Inspector/SummaryPane.swift) → `memory-summary`
  - [AuthorsNotePane.swift](Sources/RPClientCore/UI/Inspector/AuthorsNotePane.swift) → `memory-authors-note`
  - [WorldInfoPane.swift](Sources/RPClientCore/UI/Inspector/WorldInfoPane.swift) → `memory-world-info`
  - [SuggestionsPane.swift](Sources/RPClientCore/UI/Inspector/SuggestionsPane.swift) → `memory-suggestions`
  - [EntitiesPane.swift](Sources/RPClientCore/UI/Inspector/EntitiesPane.swift) → `memory-entities`
  - [RetrievalPane.swift](Sources/RPClientCore/UI/Inspector/RetrievalPane.swift) → `memory-retrieval`
  - [ExtractionPane.swift](Sources/RPClientCore/UI/Inspector/ExtractionPane.swift) → `memory-suggestions` (shares the page; extraction is the configure twin to suggestions' review surface).
- Extended the TestKit suite with an assertion that every page id used by an inspector pane resolves in `HelpIndex` — catches typos.

### Authoring guidance (still applicable to Slice 3)

Lean on the repo markdowns when describing rationale: `MEMORY_AUDIT.md`, `MEMORY_V2_PLAN.md`, `MEMORY_HANDOFF.md`, `MEMORY_RESEARCH.md`. They are the source of truth for the *why* of the memory system; the help pages should be the *how*.

---

## 5. Slice 3 — Technical reference (prioritised)

Prioritised because the load-bearing pages return value to future-me as much as to users. Each page ends with a `file:line` pointer (one or two — not a full code dump).

### Priority tier (Slice 3a) ✅ shipped 2026-05-05

| Slug | Title | Pointers |
|---|---|---|
| `tech-architecture` | Architecture overview | Targets, dataflow, `AppState` singleton, notification model, on-disk layout, file map. |
| `tech-prompt-assembly` | Prompt assembly | Cache-aware layout, per-template assembly, last-user-turn extras, continuation mode, budget overflow handling. |
| `tech-memory-pipeline` | Memory pipeline | The six-layer contract, side-calls (summarizer / extractor / blurber), rolling vs scene summaries, entity supersession, retrieval eligibility, world-info matching. |

### Tier 2 (Slice 3b) ✅ shipped 2026-05-05

Nine pages covering the remaining subsystems:

| Slug | Title | Hook |
|---|---|---|
| `tech-app-state` | AppState & UI wiring | Singleton ownership, mutation funnels, notification model, generation entry points, per-turn maintenance, UI thread discipline. |
| `tech-storage` | Storage layer | On-disk layout, atomic-write pattern, encoder/decoder config, schema-versioning approach (forward/backward compatible). |
| `tech-kobold-client` | KoboldClient & SSE | Endpoint map, streaming + side-call flow, abort double-action (client + server), token counting, embeddings batching, error model, health checks. |
| `tech-summarizer` | Summarizer | Trigger paths, slice selection (~25% ctx, 4-turn floor), split-then-merge two-call structure, scene-break vs. summarize, failure modes. |
| `tech-fact-extractor` | Fact extractor | GBNF grammar, instruction shape, 15-user-turn window, priority topic hints, trust-layer contract, eval window. |
| `tech-retrieval` | Retrieval pipeline | Chunker windowing, contextual blurbs, vector store API, eligibility predicate (the load-bearing rule), persistence ordering. |
| `tech-world-info-injector` | World-info injector | Match algorithm by mode/scope, word-boundary semantics, sort + budget, what's deliberately not implemented (vector mode, fuzzy match). |
| `tech-entities` | Entity store | Data shape, on-stage gating, salience sort, render-time topic supersession, block budget eviction order, header-prose rationale, v3 migration. |
| `tech-testing` | Testing (TestKit) | TestKit anatomy, suite list, conventions, what's deliberately not tested, how to add a regression case. |

Two pages from the original plan were folded into existing material rather than authored separately:

- **`tech-templates`** — covered by [templates](Sources/RPClientCore/Help/templates.md) (User Guide) plus the per-template implementation notes in [tech-prompt-assembly](Sources/RPClientCore/Help/tech-prompt-assembly.md).
- **`tech-scene-summaries`** — covered by the "Rolling vs. scene summaries" section in [tech-memory-pipeline](Sources/RPClientCore/Help/tech-memory-pipeline.md) and the past-tense framing material in [tech-prompt-assembly](Sources/RPClientCore/Help/tech-prompt-assembly.md).

---

## 6. Slice 4 — Long-tail user guide ✅ shipped 2026-05-05

Six pages closing the forward-link gaps from Slices 1–2 and rounding out the User Guide:

| Slug | Title | Hook |
|---|---|---|
| `presets` | Sampler presets | Per-knob explanation, the three shipped presets, tuning advice. |
| `templates` | Templates: Gemma vs Qwen3 | When to pick which, mismatch symptoms, Qwen3 thinking-mode toggle. |
| `characters-personas` | Characters & personas | Field anatomy, importing SillyTavern v2 cards, persona priority order, library workflow. |
| `library` | Library window | Characters tab, Personas tab, what the library does *not* manage. |
| `settings` | Settings | Every settings field, with cross-links into the relevant memory and template pages. |
| `troubleshooting` | Troubleshooting | Field guide for the most common symptoms (server unreachable, empty replies, looping, out of context, retrieval shows zero, etc.). |

These pages also added inbound links to the existing memory pages — `[author's note](memory-authors-note)`, `[retrieval](memory-retrieval)` — so the user guide reads as a connected document rather than a stack of isolated pages.

---

## 7. Slice 5 — V8 multi-server coverage ✅ shipped 2026-05-05

V8 (Phase 4 in [V2_PLAN.md](V2_PLAN.md)) shipped 7 commits between Slices 3b and this one. The help system was unaware of:

- The Settings → Servers section (list of profiles + role popups).
- The chat header per-chat server picker.
- `KoboldClientRegistry` and the `ServerRole`-based resolution chain.
- Side-call role routing (summarizer / extractor / embeddings can each pin to a specific server).
- The fallback semantics when a referenced profile is deleted.

### TDD workflow

Followed the new repo convention (see `feedback_tdd_workflow.md` in memory): tests first, watch them fail, then write content to make them pass.

Added 6 failing assertions to `helpIndexTests`:

- `multi-server` page exists.
- `multi-server` page mentions "registry", "per-chat", and "role" (the load-bearing concepts).
- `settings.md` contains "Servers" (capital S).
- `troubleshooting.md` covers multi-server scenarios.
- `tech-architecture.md` mentions the client registry.
- `tech-kobold-client.md` mentions `KoboldClientRegistry` and role routing.
- `tech-app-state.md` mentions the registry ownership.

(One additional pre-existing assertion passed accidentally; the rewrite strengthened it.)

### Content changes

| File | Change |
|---|---|
| `multi-server.md` | New page. Servers section anatomy, role assignment table, per-chat pin, probe semantics, three worked examples (workstation+cloud, pinning, recovery from deleted profile). |
| `settings.md` | Replaced single "Server URL" section with a "Servers" section that points at the dedicated page. |
| `troubleshooting.md` | Server-unreachable diagnostic now references "whichever the active chat is using"; new "Side-call ran on the wrong server" section. |
| `quick-start.md` | First sentence now reads "one or more servers"; forward-link to multi-server. |
| `tech-architecture.md` | Diagram updated; new network paragraph splitting registry from per-server transport; file-map gains `KoboldClientRegistry.swift`, `ServerProfile.swift`, `ServerProbe.swift`. |
| `tech-kobold-client.md` | Page reframed: registry first (cache rationale, `ServerRole` resolution rules, settings-update identity-preservation), then per-server transport. |
| `tech-app-state.md` | "What AppState owns" section: removed `kobold: KoboldClient`, added `registry: KoboldClientRegistry`. `assembleAndStream` flow now reads the chat-pinned client through the registry. |

### What this slice did *not* cover

Deferred to future maintenance:

- **HelpButton on the Settings → Servers section.** Would deep-link from the Servers UI to `multi-server`. Cheap (one button + one anchor) but requires a small `SettingsWindowController` edit in the right place.
- **A new tech page on `ServerProbe.swift`.** The probe parser is small and well-tested; current help link is the file pointer in `tech-architecture`. If the probe surface grows it will warrant its own page.
- **Anchor-level deep-links from inspector pane "?" buttons.** Currently they all open at page-top; a mild polish pass to land each `(?)` on the right section.

---

## 8. Open follow-ups

Carry these in mind but don't block on them:

- **Screenshots.** Deferred. Revisit once we have a stable capture script and the inspector layout has settled.
- **Full-text search rank.** Today's filter is "page contains substring." Fine for v1. If the corpus grows past ~30 pages, switch to per-page match counts and a ranked drawer instead of a TOC filter.
- **Dead-anchor detection.** TestKit currently asserts every registered page renders with at least one anchor. It does **not** assert that every `[label](page-id#anchor)` link in any page resolves to a real anchor. Adding this is a 20-line change and worth doing once Slice 2's cross-links exist.
- **CharacterCardView pane help, Settings tab help.** Same `HelpButton` mechanism, deferred until Slice 4.
