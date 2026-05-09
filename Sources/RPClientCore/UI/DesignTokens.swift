import AppKit

/// In-code embodiment of [`V2_DESIGN_LANGUAGE.md`](../../V2_DESIGN_LANGUAGE.md).
/// Phase 9 §5.3a — every new RPClient surface imports these tokens; magic
/// numbers in layout / typography / color call sites are bugs. The existing
/// app's `Theme.swift` is intentionally not extended (the `uiFontOffset`
/// scaling is in the §10 anti-patterns list); new code uses `DesignTokens`
/// directly.
///
/// Reference platform: macOS 26 Tahoe / Liquid Glass. Non-Apple modern UX
/// references (Linear visual-weight, Vercel/Geist mono-numerics, Notion
/// hover-handles) inform the higher-level posture; per-token values match
/// the macOS HIG spec.
enum DesignTokens {

    /// 8pt baseline grid. Five tokens — anything else is wrong (§3).
    enum Spacing {
        /// 4 — inside chips/pills, between an icon and its label.
        static let xs: CGFloat = 4
        /// 8 — default control padding, tight-list row gap.
        static let sm: CGFloat = 8
        /// 16 — relaxed form-row gap, section-heading-to-first-row.
        static let md: CGFloat = 16
        /// 24 — between sections inside a tab, popover margins.
        static let lg: CGFloat = 24
        /// 32 — tab-body outer padding.
        static let xl: CGFloat = 32
    }

    /// Apple text-style scale. Use the named tokens; never raw point sizes
    /// (the system Dynamic Type setting drives the actual size). §2.
    enum Typography {
        static var largeTitle: NSFont { NSFont.preferredFont(forTextStyle: .largeTitle) }
        static var title1: NSFont { NSFont.preferredFont(forTextStyle: .title1) }
        static var title2: NSFont { NSFont.preferredFont(forTextStyle: .title2) }
        static var title3: NSFont { NSFont.preferredFont(forTextStyle: .title3) }
        /// 13pt semibold — field labels, list-row primary text, table column
        /// headers. The semibold/regular contrast against `body` is the
        /// hierarchy contract; do not substitute color for it.
        static var headline: NSFont { NSFont.preferredFont(forTextStyle: .headline) }
        static var body: NSFont { NSFont.preferredFont(forTextStyle: .body) }
        static var callout: NSFont { NSFont.preferredFont(forTextStyle: .callout) }
        /// Hint text below a field, secondary metadata.
        static var subheadline: NSFont { NSFont.preferredFont(forTextStyle: .subheadline) }
        static var footnote: NSFont { NSFont.preferredFont(forTextStyle: .footnote) }
        static var caption1: NSFont { NSFont.preferredFont(forTextStyle: .caption1) }
        static var caption2: NSFont { NSFont.preferredFont(forTextStyle: .caption2) }

        /// Monospaced face at the same size as the named text style. Used
        /// for technical / numeric content per §11 — depth values, dates,
        /// version numbers, token counts, JSON in the extensions viewer.
        /// Defaults to regular weight; pass `.semibold` for table headers.
        static func mono(_ style: NSFont.TextStyle, weight: NSFont.Weight = .regular) -> NSFont {
            let size = NSFont.preferredFont(forTextStyle: style).pointSize
            return NSFont.monospacedSystemFont(ofSize: size, weight: weight)
        }
    }

    /// Foreground (text + glyph) color tokens. Semantic NSColor only — they
    /// adapt to light/dark/high-contrast/accent automatically. §4.
    enum Foreground {
        static var primary: NSColor { .labelColor }
        static var secondary: NSColor { .secondaryLabelColor }
        static var tertiary: NSColor { .tertiaryLabelColor }
        static var quaternary: NSColor { .quaternaryLabelColor }
        /// Use sparingly — primary action of a view, focused control,
        /// selected item. Three accents in one view = two are wrong (§1.4).
        static var accent: NSColor { .controlAccentColor }
        static var destructive: NSColor { .systemRed }
        static var warning: NSColor { .systemYellow }
        static var success: NSColor { .systemGreen }
    }

    /// Background color tokens. §4.
    enum Background {
        static var window: NSColor { .windowBackgroundColor }
        static var textInput: NSColor { .textBackgroundColor }
        static var group: NSColor { .controlBackgroundColor }
        static var selectedRow: NSColor { .selectedContentBackgroundColor }
    }

    /// Animation durations. Restraint over expression — macOS isn't iOS
    /// (§8). All durations sit inside the 100-220ms HIG envelope; springs
    /// are forbidden, ease-out / ease-in-out only.
    enum Motion {
        static let tabSwap: TimeInterval = 0.180
        static let disclosure: TimeInterval = 0.220
        static let suggestionsReveal: TimeInterval = 0.160
        static let hoverFade: TimeInterval = 0.120
        static let staleBadge: TimeInterval = 0.100
    }

    /// Corner radii — concentricity (outer wraps inner). §1.2.
    enum Radius {
        /// Window itself — macOS 26 standard.
        static let window: CGFloat = 26
        /// Section / card surface inside content area.
        static let section: CGFloat = 14
        /// Form control (button, text field, pill).
        static let control: CGFloat = 8
        /// Chip / pill / token-field token.
        static let chip: CGFloat = 4
    }

    /// Chat-pane semantic tokens. Phase 11 §4.a — these are not new
    /// values, they're chat-vocabulary names for the same `Spacing` /
    /// `Radius` tokens. Call sites in TurnView / composer / per-turn
    /// controls read in chat terms ("turn gap", "avatar gutter") rather
    /// than reaching for the underlying grid token.
    ///
    /// **No-fork rule.** Anything that can be expressed as an alias
    /// MUST alias — never duplicate the literal. If the language ever
    /// bumps `Spacing.md`, chat layout follows automatically.
    enum Chat {
        /// 720 — content column max width per V2_UI_OVERHAUL §4.3.
        /// Genuinely new (the only Chat token that isn't an alias);
        /// it's a content-rule, not a grid-token.
        static let transcriptMaxWidth: CGFloat = 720

        /// 32 — avatar circle diameter, both assistant and user side
        /// (§4.0.b / §4.0.c). Aliases `Spacing.xl`.
        static let avatarSize: CGFloat = Spacing.xl

        /// 32 — leading gutter column width that holds the avatar
        /// (§4.3 anatomy). Same as `avatarSize`; the separation exists
        /// so a future variant (e.g. avatar shrinks to 28 inside a
        /// 32 gutter for visual breathing) doesn't require renaming
        /// every call site.
        static let avatarGutter: CGFloat = Spacing.xl

        /// 8 — gap between the avatar gutter and the body content
        /// (§4.3 `[gutter] [sm gap] [body]`). Aliases `Spacing.sm`.
        static let avatarToBodyGap: CGFloat = Spacing.sm

        /// 16 — vertical rhythm between turns (§4.3). Aliases `Spacing.md`.
        static let turnGap: CGFloat = Spacing.md

        /// 14 — corner radius for the user-turn subtle bubble
        /// (§4.0.a / §4.3). Aliases `Radius.section` since the bubble
        /// is conceptually a small card surface.
        static let bubbleRadius: CGFloat = Radius.section
    }
}
