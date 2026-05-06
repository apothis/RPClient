# RPClient V2 Design Language

**Status: living document.** First codified during Phase 9 §5.3 (Card Creator window) so the creator can serve as the gold-standard surface the rest of the app aligns to during the future UI overhaul ([`V2_PLAN.md`](V2_PLAN.md) §8). Every system-level decision here — typography scale, spacing, color tokens, materials, motion, density posture — should hold across the app. Per-feature design docs reference this; this doc is platform truth.

The reference platform is **macOS 26 Tahoe / "Liquid Glass"** (Apple's 2025 WWDC25 design language, shipped with macOS 26). RPClient is unsandboxed AppKit; nothing here requires SwiftUI. WWDC25 session 310 ("Build an AppKit app with the new design") and the macOS HIG Materials / Typography / Designing-for-macOS pages are the source-of-truth references.

---

## 1. Principles

Five load-bearing rules. Every design decision in the app should fall out of one of these.

1. **Power-user dense, not consumer-airy.** RPClient is a deliberate scene-construction tool. We lean denser than Mail / Notes — but density doesn't mean cramming. It means **earning** every visible control. A control that's used <10% of sessions belongs behind a hover/focus reveal, not in the chrome. (V2_PLAN §8 calls out the existing chat header as an anti-pattern: Server + Attribution + Voice + speaker mute all permanently visible at 28pt. This is what we're correcting.)
2. **Concentricity.** Inner radii echo outer radii: a 26pt window houses 14pt sections containing 8pt fields containing 4pt chips. Spacing follows the same logic — 24pt section gaps, 16pt row gaps, 8pt control gaps, 4pt token gaps. A reader's eye finds rhythm without consciously parsing it.
3. **Material conveys depth, not ornament.** Glass and vibrancy are spatial cues — sidebar is *behind* content, popover is *above* content. Don't apply glass for visual interest; apply it where the depth metaphor is real. Translucency without spatial purpose is noise.
4. **One accent, used sparingly.** The system accent color is reserved for: the primary action of any view, the focused control, the selected item. Everything else is the system gray hierarchy (`labelColor` → `secondaryLabelColor` → `tertiaryLabelColor` → `quaternaryLabelColor`). If three things are accented in one view, two are wrong.
5. **Progressive disclosure for the non-essential.** Anything that's not required for the 80% case lives behind a reveal — disclosure triangle, hover-only chip, focus-only control, "Show advanced" sheet. The default view is the dense common path; the long tail is one click away. Always one click — never buried two layers deep.

A design choice that violates a principle should be corrected, not justified. Exceptions get loud comments in code so future readers know it's deliberate.

---

## 2. Typography

System font is **SF Pro** (the macOS default — `NSFont.systemFont(ofSize:)`). All sizes follow Apple's 2026 macOS scale; we never invent sizes.

| Token | pt | Weight | Use |
|---|---|---|---|
| `largeTitle` | 26 | Regular | Window-level page titles. Used sparingly — at most once per window. |
| `title1` | 22 | Regular | Major section headings. Tab body opening titles. |
| `title2` | 17 | Regular | Sub-section headings. |
| `title3` | 15 | Regular | Group headings inside a section. |
| `headline` | 13 | **Semibold** | Field labels, list-row primary text, table column headers. |
| `body` | 13 | Regular | Default body text. Field input. Multi-line content. |
| `callout` | 12 | Regular | Inline annotations next to body text. |
| `subheadline` | 11 | Regular | Field hint text below input, secondary metadata. |
| `footnote` | 10 | Regular | Tertiary text. Disabled-state captions. |
| `caption1` | 10 | Regular | Smallest visible text. Avatar captions, tag pills. |

**Rules.**

- Use the named `NSFont.preferredFont(forTextStyle:)` API where possible — it scales with the user's accessibility text-size preference. Fixed-point sizes only when the layout depends on a specific metric (rare).
- Field labels are `headline` (13pt semibold). Field input is `body` (13pt regular). The semibold/regular contrast is the visual hierarchy — don't substitute color for it.
- Multi-line content (description / personality / scenario / system_prompt) uses `body`. Don't shrink to fit; let the user scroll.
- Monospace (SF Mono, `NSFont.monospacedSystemFont(ofSize: 11)`) is reserved for code-shaped content: the `extensions` JSON viewer, debug logs, raw JSON previews. Never for prose.

Existing offenders to fix during the future overhaul: chat header uses 13pt for everything; should be `headline` for the chat title and `subheadline` for server / mode metadata.

---

## 3. Spacing

8pt baseline grid. Five named tokens — anything not in this list is wrong.

| Token | pt | Use |
|---|---|---|
| `xs` | 4 | Inside chips / pills / token-field tokens. Between an icon and its label. |
| `sm` | 8 | Default control padding. Between rows in a tight list. Default form-row vertical gap. |
| `md` | 16 | Between form rows in a relaxed layout. Between a section heading and its first row. |
| `lg` | 24 | Between sections inside a tab. Margin around a single section in a popover. |
| `xl` | 32 | Tab-body outer padding. Top of a window-content-area to first heading. |

Window-edge insets: `lg` (24pt) on every side of the content area (inside the window chrome / sidebar / inspector). Sections inside the content area get `xl` (32pt) top breathing room from the window edge.

Avoid: 12pt, 20pt, 28pt. They feel "almost right" because they're between grid stops, which is exactly why they look off.

---

## 4. Color

Use **system** semantic colors, never raw hex. The app should adapt automatically across light / dark / increase-contrast / accent-color preferences.

### Foreground

| Use | Token |
|---|---|
| Primary text | `NSColor.labelColor` |
| Field labels, secondary metadata | `NSColor.secondaryLabelColor` |
| Placeholder, hint text | `NSColor.tertiaryLabelColor` |
| Disabled | `NSColor.quaternaryLabelColor` |
| Primary action (button title), focused field outline, selected list row | `NSColor.controlAccentColor` |
| Destructive action | `NSColor.systemRed` |
| Warning chip (refusal-detected, depth_prompt-not-routed) | `NSColor.systemYellow` |
| Success | `NSColor.systemGreen` |

### Background

| Use | Token |
|---|---|
| Window content | `NSColor.windowBackgroundColor` (auto-adapts to material) |
| Field input chrome | `NSColor.textBackgroundColor` |
| Selected row | `NSColor.alternatingContentBackgroundColors[1]` or `NSColor.selectedContentBackgroundColor` |
| Group / section background | `NSColor.controlBackgroundColor` |

### Speaker / cast color hashing

Phase 8's [`SpeakerColor`](Sources/RPClientCore/UI/SpeakerColor.swift) deterministic palette stays as the source of truth for per-speaker accents. Don't pick palettes ad-hoc in new surfaces.

---

## 5. Materials & layering

Liquid Glass is the macOS 26 default. Apply with intent.

### Window structure

- **Window** itself adopts the standard 26pt window corner radius automatically; don't override.
- **Sidebar** (chat list, library grid) uses `NSSplitViewController` with the sidebar split-item behavior. AppKit applies the floating glass material — **do not** put an `NSVisualEffectView` inside the sidebar; it will block the glass.
- **Inspector** (chat detail panes, future card-bound context) uses the inspector split-item behavior — edge-to-edge glass alongside content.
- **Content area** is opaque (`.windowBackgroundColor`). Material is only at the chrome boundaries.

### Custom glass surfaces

Use `NSGlassEffectView` for surfaces that genuinely sit "above" content — popovers, floating panels, hover cards. Set `contentView` so AppKit applies legibility treatments (vibrancy, contrast pulls) automatically. Don't compose glass yourself with stacked `NSVisualEffectView`s; the API does it correctly.

### Materials we don't use

- The deprecated `.sidebar` material (legacy NSVisualEffectView) — superseded by sidebar split-item behavior.
- Multi-layer glass stacking. One pane of glass, one depth stop. Stacking doesn't add depth; it adds noise.
- Translucent buttons or fields. Glass is for chrome, not content controls.

---

## 6. Controls

### Sizing

Apple's 2026 sizes. Pick by visual weight in context, not by personal preference.

| Size | Shape | Use |
|---|---|---|
| `mini` | Rounded rect | Inline sublabels (rare). |
| `small` | Rounded rect | Dense forms (creator-window-style field sets). |
| `regular` | Rounded rect | Default. Most controls. |
| `large` | Capsule | Primary action of a sheet / dialog. |
| `extraLarge` | Capsule | Hero buttons (rare; not used in RPClient today). |

Concentricity: the corner shape echoes the size. Mixing `small` rounded rect with `large` capsule in the same row reads as broken; pick one and commit.

### Buttons

- Primary action = `NSButton.bezelStyle = .rounded`, `.controlSize = .regular`, `keyEquivalent = "\r"` for the default action of a view.
- Secondary actions: same bezel, no key equivalent.
- Destructive: `.bezelStyle = .rounded` plus `.hasDestructiveAction = true` (renders red text in macOS 26).
- Icon-only buttons in chrome: `NSButton.bezelStyle = .toolbar` or borderless with a hover-state outline.
- Avoid the deprecated `.recessed` / `.regularSquare` styles for new code.

### Form fields

- Text input: `NSTextField.bezelStyle = .roundedBezel`, `controlSize` matching surrounding controls.
- Multi-line: `NSTextView` inside `NSScrollView` with `hasVerticalScroller = true`, `autohidesScrollers = true`. Min height 96pt, grows-to-fit up to 320pt before scrolling.
- Token field: `NSTokenField` with `tokenStyle = .rounded`. Autocomplete via `tokenField(_:completionsForSubstring:indexOfToken:indexOfSelectedItem:)`.
- Pop-up: `NSPopUpButton.bezelStyle = .rounded`. For long lists (>20 items), use a search-field-driven sheet instead.

### Focus + selection

- Focus ring: system default (`focusRingType = .default`). Don't suppress it; it's the keyboard-navigation contract.
- Hover: hover-only secondary controls fade in over 120ms. Use `NSTrackingArea` with `.mouseEnteredAndExited`.
- Selected-row indicator: 2pt accent rule on the leading edge for list rows, full `selectedContentBackgroundColor` fill for dense table rows.

---

## 7. Iconography

**SF Symbols 6** (the macOS 26-bundled set) for everything.

- Use `NSImage(systemSymbolName:accessibilityDescription:)`. Always pass an accessibility label.
- Symbol weight: `.regular` by default, `.semibold` to match `headline` text contexts.
- Symbol scale: `.medium` for inline, `.large` for primary toolbar actions.
- Variants: prefer the `.fill` variant for selected / active states, outline for default. Don't mix in the same row.
- Color: inherit from foreground (`tintColor` / `contentTintColor`). Don't hard-code symbol colors.

Custom glyphs are forbidden when an SF Symbol exists. The chat-view's `✦` placeholder for character-less assistant turns is one of two existing exceptions and should migrate to `person.crop.circle` during the future pass.

---

## 8. Motion

Subtle. macOS isn't iOS; motion shouldn't draw attention.

| Action | Duration | Easing |
|---|---|---|
| Tab swap inside a tabbed window | 180ms | `easeOut` |
| Disclosure expand / collapse | 220ms | `easeInOut` |
| Suggestions strip reveal (Phase 9 §4.1) | 160ms | `easeOut` |
| Hover-secondary control fade | 120ms | `linear` |
| Sheet present | system default (don't override) |
| Window appear | system default (don't override) |
| Stale-badge appearance | 100ms cross-fade |

Avoid: spring animations (consumer iOS feel), bounce, rotation. macOS motion is restrained translation + opacity. Anything else feels off-platform.

---

## 9. Density posture

RPClient's specific stance on the density-vs-air axis. This is where the app diverges from consumer-grade chat (ChatGPT, Claude.ai) and aligns with power-user tools (Linear, Xcode, Things 3 in pro mode).

- **Default to dense.** A pane that fits 12 rows in the viewport beats one that fits 8. Padding above the platform default is a smell.
- **Earn every visible control.** Header chrome should carry only what the user touches once per session minimum. Per-turn / per-card actions live in hover / context menus, not the chrome.
- **Reveal long-tail on focus or hover.** AI-assist suggestions strip is closed by default; depth-prompt advanced controls are behind a disclosure; the extensions JSON viewer is one tab away. The 80% path is never dragged through the 20% surface.
- **One unified scale.** The user's font-size preference (system Dynamic Type) drives every text size. RPClient's per-window or per-pane scale overrides — the existing `uiFontOffset` setting — are technical-debt to be removed during the overhaul, not extended.

---

## 10. Anti-patterns (existing app to fix later)

Known violations of this language in the current app. Catalogued so the future UI overhaul has a punch list.

- **Chat header density.** Server + Attribution + Voice + speaker mute all permanently visible. Should collapse: chat title visible, server/mode/voice in a hover-revealed metadata strip, mute as a hover icon over the avatar.
- **Inspector pane visual inconsistency.** Memory / World / Cast / Branches / Tree / Suggestions panes don't share a visual grammar — different padding, different label weights, different empty-state copy styles.
- **Voice library window separation.** A dedicated window for what should be a Settings tab. Rehome during the overhaul.
- **`uiFontOffset` setting.** Per-app font scaling override. Replaced by macOS Dynamic Type. Remove.
- **Custom glyph use.** `✦` for character-less assistant turns. Replace with `person.crop.circle` SF Symbol.
- **Settings → Servers row layout.** Profile rows mix bezel styles (rounded text field next to a borderless icon button). Pick one bezel family.

This list grows during the overhaul; don't fold corrections into Phase 9.

---

## 11. Application contract for new surfaces

Any new view added to RPClient from this point on must:

- Use named text styles (no raw `NSFont.systemFont(ofSize: 15)` calls).
- Stick to the spacing tokens (no 12pt or 20pt gaps).
- Use semantic colors (no `NSColor(red:..., green:..., blue:...)` for foreground).
- Use SF Symbols (no custom glyphs).
- Earn every permanently-visible control (or relegate to hover / disclosure).
- Pick one control size family per view (mini-medium *or* large-xl, not mixed).

Reviewer expectation: the diff should be answerable in design-language-token terms. "Section gap is `lg`" beats "section gap is 24pt". If the answer requires a magic number, the magic number is wrong.

---

## 12. References

- [Designing for macOS — HIG](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos).
- [macOS Materials — HIG](https://developer.apple.com/design/human-interface-guidelines/foundations/materials/).
- [Typography — HIG](https://developer.apple.com/design/human-interface-guidelines/foundations/typography/).
- [Adopting Liquid Glass — Apple Developer Documentation](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass).
- [WWDC25 Session 310 — Build an AppKit app with the new design](https://developer.apple.com/videos/play/wwdc2025/310/).
- [WWDC25 Session notes (community)](https://wwdcnotes.com/documentation/wwdcnotes/wwdc25-310-build-an-appkit-app-with-the-new-design/).
- [`V2_PLAN.md`](V2_PLAN.md) §8 — deferred UI overhaul (this doc is its foundation).
- [`V2_PHASE9_CARD_CREATOR.md`](V2_PHASE9_CARD_CREATOR.md) — the first surface that fully applies this language.
