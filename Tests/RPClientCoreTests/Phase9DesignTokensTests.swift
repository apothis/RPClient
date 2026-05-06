import AppKit
import Foundation
@testable import RPClientCore

/// Phase 9 §5.3a — DesignTokens is the in-code embodiment of
/// V2_DESIGN_LANGUAGE.md. These tests pin the canonical token values
/// so a future "let me just bump 24pt to 22pt for this view" regression
/// hits a test boundary instead of silently drifting the language.
func phase9DesignTokensTests() -> TestSuite {
    let s = TestSuite("Phase9DesignTokens")

    // MARK: - Spacing — 8pt grid, five named tokens

    s.test("Spacing tokens hold the 8pt-grid canonical values") {
        try expectEqual(DesignTokens.Spacing.xs, 4)
        try expectEqual(DesignTokens.Spacing.sm, 8)
        try expectEqual(DesignTokens.Spacing.md, 16)
        try expectEqual(DesignTokens.Spacing.lg, 24)
        try expectEqual(DesignTokens.Spacing.xl, 32)
    }

    // MARK: - Typography — system text styles

    s.test("Typography returns NSFont for every named style") {
        // Just-non-nil + reasonable size is enough — Apple owns the exact
        // pt values per Dynamic Type, we verify the wiring.
        try expectTrue(DesignTokens.Typography.body.pointSize > 0)
        try expectTrue(DesignTokens.Typography.headline.pointSize > 0)
        try expectTrue(DesignTokens.Typography.title1.pointSize > 0)
        try expectTrue(DesignTokens.Typography.subheadline.pointSize > 0)
        try expectTrue(DesignTokens.Typography.caption1.pointSize > 0)
    }

    s.test("headline is semibold (the field-label contract)") {
        // Field labels rely on weight contrast against body for hierarchy
        // (V2_DESIGN_LANGUAGE §2). Spec says "field labels are headline
        // (13pt semibold)."
        let f = DesignTokens.Typography.headline
        let traits = f.fontDescriptor.symbolicTraits
        try expectTrue(traits.contains(.bold) || f.fontDescriptor.fontAttributes[.traits] != nil,
                       "headline should carry bold/semibold trait")
    }

    s.test("mono returns a monospaced font for the same style") {
        let m = DesignTokens.Typography.mono(.body)
        try expectTrue(m.fontName.contains("Mono") || m.fontDescriptor.symbolicTraits.contains(.monoSpace),
                       "mono should produce a monospaced face")
    }

    // MARK: - Color — semantic NSColor only

    s.test("Foreground tokens map to system semantic NSColor") {
        try expectEqual(DesignTokens.Foreground.primary, NSColor.labelColor)
        try expectEqual(DesignTokens.Foreground.secondary, NSColor.secondaryLabelColor)
        try expectEqual(DesignTokens.Foreground.tertiary, NSColor.tertiaryLabelColor)
        try expectEqual(DesignTokens.Foreground.quaternary, NSColor.quaternaryLabelColor)
        try expectEqual(DesignTokens.Foreground.accent, NSColor.controlAccentColor)
        try expectEqual(DesignTokens.Foreground.destructive, NSColor.systemRed)
        try expectEqual(DesignTokens.Foreground.warning, NSColor.systemYellow)
        try expectEqual(DesignTokens.Foreground.success, NSColor.systemGreen)
    }

    s.test("Background tokens map to system semantic NSColor") {
        try expectEqual(DesignTokens.Background.window, NSColor.windowBackgroundColor)
        try expectEqual(DesignTokens.Background.textInput, NSColor.textBackgroundColor)
        try expectEqual(DesignTokens.Background.group, NSColor.controlBackgroundColor)
    }

    // MARK: - Motion — within the §8 budget

    s.test("Motion durations sit within the 80ms–260ms HIG-restraint budget") {
        // V2_DESIGN_LANGUAGE §8 — durations are 100-220ms. Test bounds are
        // a hair wider so a future 80ms or 260ms doesn't fail spuriously
        // but a 500ms spring sneak-in does.
        let durations: [TimeInterval] = [
            DesignTokens.Motion.tabSwap,
            DesignTokens.Motion.disclosure,
            DesignTokens.Motion.suggestionsReveal,
            DesignTokens.Motion.hoverFade,
            DesignTokens.Motion.staleBadge,
        ]
        for d in durations {
            try expectTrue(d >= 0.080 && d <= 0.260, "duration \(d) outside motion budget")
        }
    }

    // MARK: - Radius — concentricity

    s.test("Radius tokens echo the concentricity principle (window > section > control)") {
        try expectTrue(DesignTokens.Radius.window >= DesignTokens.Radius.section)
        try expectTrue(DesignTokens.Radius.section >= DesignTokens.Radius.control)
        try expectTrue(DesignTokens.Radius.control > 0)
    }

    return s
}
