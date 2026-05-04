# RPClient help system — plan

In-app help system with two books: a **User Guide** (task-first, "how do I…") and a **Technical Reference** (system-first, "how does it work"). Same window, same renderer, different TOC. Frozen markdown shipped as bundle resources — content edits happen in source, not at runtime.

**Status as of 2026-05-04.** Slice 1 (skeleton + first five User Guide pages) shipped on branch `v2-plan`. Slice 2 (Memory user guide + Inspector pane "?" buttons) is next; Slice 3 (Technical Reference, prioritised) follows.

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
│  Slice 1  Skeleton + Quick Start         ✅ shipped 2026-05-04   │
│  Slice 2  Memory user guide + ? buttons                          │
│  Slice 3  Technical reference (prioritised)                      │
│  Slice 4  Long tail (presets, templates, library, settings,      │
│           troubleshooting, remaining tech pages)                 │
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

## 4. Slice 2 — Memory user guide + Inspector "?" buttons (next)

Memory is the differentiator and where users will most plausibly look up "what does this do." Help is most useful when surfaced from the panel itself, so the **?** buttons land in the same slice.

### Pages to author

| Slug | Title | Covers |
|---|---|---|
| `memory-pinned-facts` | Memory: pinned facts | What gets pinned, format, token cap, worked example (a character allergy). |
| `memory-summary` | Memory: rolling summary | When the summarizer triggers, how to view/edit, "summarize now" menu item. |
| `memory-authors-note` | Memory: author's note | Free-text + injection depth; example steering tone mid-scene. |
| `memory-world-info` | Memory: world info / lorebook | Keys, secondary keys (AND-gate), match scope, priority, worked example. |
| `memory-suggestions` | Memory: suggestions | Fact extractor side-call, review/approve/dismiss flow, cadence setting. |
| `memory-entities` | Memory: entities | Entity store, on-stage selection, manual edits. |
| `memory-retrieval` | Memory: retrieval | Vector search settings, what shows up in the pane, when to enable. |

### Implementation steps

1. Author the seven `.md` files; register in `HelpIndex.pages`.
2. Add a small `HelpButton` helper view (one square `(?)` glyph that calls `AppDelegate.openHelp(pageId:)`) to keep the call sites uniform.
3. Wire one `HelpButton` into the header of each Inspector pane:
   - [MemoryPane.swift](Sources/RPClientCore/UI/Inspector/MemoryPane.swift) → `memory-pinned-facts`
   - [SummaryPane.swift](Sources/RPClientCore/UI/Inspector/SummaryPane.swift) → `memory-summary`
   - [AuthorsNotePane.swift](Sources/RPClientCore/UI/Inspector/AuthorsNotePane.swift) → `memory-authors-note`
   - [WorldInfoPane.swift](Sources/RPClientCore/UI/Inspector/WorldInfoPane.swift) → `memory-world-info`
   - [SuggestionsPane.swift](Sources/RPClientCore/UI/Inspector/SuggestionsPane.swift) → `memory-suggestions`
   - [EntitiesPane.swift](Sources/RPClientCore/UI/Inspector/EntitiesPane.swift) → `memory-entities`
   - [RetrievalPane.swift](Sources/RPClientCore/UI/Inspector/RetrievalPane.swift) → `memory-retrieval`
4. Extend the TestKit suite with one assertion per pane that the page id used by the pane resolves in `HelpIndex` — guards against typos.

### Authoring guidance

Lean on the repo markdowns when describing rationale: `MEMORY_AUDIT.md`, `MEMORY_V2_PLAN.md`, `MEMORY_HANDOFF.md`, `MEMORY_RESEARCH.md`. They are the source of truth for the *why* of the memory system; the help pages should be the *how*.

---

## 5. Slice 3 — Technical reference (prioritised)

Prioritised because the load-bearing pages return value to future-me as much as to users. Each page ends with a `file:line` pointer (one or two — not a full code dump).

### Priority tier (Slice 3a)

| Slug | Title | Pointers |
|---|---|---|
| `tech-architecture` | Architecture overview | Process layout, `RPClient` vs `RPClientCore`, `AppState` central state, change-notification model. |
| `tech-prompt-assembly` | Prompt assembly | Cache-aware layout: stable above the boundary, changing below. Why SmartCache reuse depends on this. |
| `tech-memory-pipeline` | Memory pipeline | Token-budget allocation, layer ordering, eviction, summarizer/extractor side-calls. |

### Tier 2 (Slice 3b, opportunistic)

`tech-storage`, `tech-kobold-client`, `tech-templates`, `tech-summarizer`, `tech-fact-extractor`, `tech-retrieval` (chunker + embeddings + vector store + retrieval engine), `tech-world-info-injector`, `tech-entities`, `tech-scene-summaries`, `tech-app-state`, `tech-testing`.

---

## 6. Slice 4 — Long tail

Remaining User Guide pages (`presets`, `templates`, `library`, `settings`, `troubleshooting`) plus any Tier 2 tech pages not landed in Slice 3b. Sequenced by what the user actually hits when reading the existing pages and finding a forward link unfilled.

---

## 7. Open follow-ups

Carry these in mind but don't block on them:

- **Screenshots.** Deferred. Revisit once we have a stable capture script and the inspector layout has settled.
- **Full-text search rank.** Today's filter is "page contains substring." Fine for v1. If the corpus grows past ~30 pages, switch to per-page match counts and a ranked drawer instead of a TOC filter.
- **Dead-anchor detection.** TestKit currently asserts every registered page renders with at least one anchor. It does **not** assert that every `[label](page-id#anchor)` link in any page resolves to a real anchor. Adding this is a 20-line change and worth doing once Slice 2's cross-links exist.
- **CharacterCardView pane help, Settings tab help.** Same `HelpButton` mechanism, deferred until Slice 4.
