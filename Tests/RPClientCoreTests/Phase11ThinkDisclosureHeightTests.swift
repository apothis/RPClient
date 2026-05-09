import AppKit
import Foundation
@testable import RPClientCore

/// Phase 11 §4.b.2 — pure height math for the `<think>` disclosure
/// pill. Pinned as a static helper so the row layout can be tested
/// without instantiating a full TurnView (NSView + tracking areas +
/// NSTextStorage make that fragile in an offscreen test).
///
/// V2_UI_OVERHAUL §4.11 calls this out specifically: "test the
/// `<think>` open/close height delta math." Layout invariant is:
///
/// - no thinking content        → 0
/// - thinking, collapsed        → pill height + gap
/// - thinking, expanded         → pill height + gap + body + gap
///
/// All four states are pinned below.
func phase11ThinkDisclosureHeightTests() -> TestSuite {
    let s = TestSuite("Phase11ThinkDisclosureHeight")

    s.test("no thinking content — disclosure area is 0pt") {
        let h = TurnView.disclosureExtraHeight(
            hasThinking: false, expanded: false, bodyHeight: 0
        )
        try expectEqual(h, 0)
    }

    s.test("no thinking content — expanded flag ignored, still 0pt") {
        // The expanded flag is meaningless when there's nothing to show.
        // Defensive: clearing thinkingText must collapse the area even
        // if a stale `thinkingExpanded = true` survived.
        let h = TurnView.disclosureExtraHeight(
            hasThinking: false, expanded: true, bodyHeight: 200
        )
        try expectEqual(h, 0)
    }

    s.test("thinking present, collapsed — pill height + xs gap above bubble") {
        // Pill is 20pt high; xs gap separates it from the bubble below.
        let h = TurnView.disclosureExtraHeight(
            hasThinking: true, expanded: false, bodyHeight: 0
        )
        try expectEqual(h, 20 + DesignTokens.Spacing.xs)
    }

    s.test("thinking present, expanded — pill + gap + body + gap") {
        // Body uses a measured height that callers compute against the
        // available width. Test pins the *math*, not the measurement.
        let h = TurnView.disclosureExtraHeight(
            hasThinking: true, expanded: true, bodyHeight: 64
        )
        try expectEqual(h, 20 + DesignTokens.Spacing.xs + 64 + DesignTokens.Spacing.xs)
    }

    s.test("expand delta matches body + one xs gap (the open/close delta)") {
        // The user-visible animation when toggling the disclosure
        // grows the row by exactly bodyHeight + xs. Pinning this delta
        // separately so a future "let me bump the gap to sm" regression
        // hits a test boundary even if the absolute heights drift.
        let collapsed = TurnView.disclosureExtraHeight(
            hasThinking: true, expanded: false, bodyHeight: 64
        )
        let expanded = TurnView.disclosureExtraHeight(
            hasThinking: true, expanded: true, bodyHeight: 64
        )
        try expectEqual(expanded - collapsed, 64 + DesignTokens.Spacing.xs)
    }

    return s
}
