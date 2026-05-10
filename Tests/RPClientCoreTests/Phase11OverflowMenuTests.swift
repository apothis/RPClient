import Foundation
@testable import RPClientCore

/// Phase 11 §4.d.1 — pure-data planner for the per-turn `⋯` overflow
/// menu. Pinned as a static helper so the menu contents are testable
/// without instantiating an NSMenu / NSView in an offscreen test.
///
/// V2_UI_OVERHAUL §C.2 sets the rule: "≤4 items, never more". Items
/// beyond four belong elsewhere (an inspector, a per-chat setting,
/// or visible primary). The assistant set today: replay-audio,
/// continue (last only), discard-variant (count > 1), delete — at
/// most four. The user set today: copy (delete is primary on the
/// user side per §4.3, so it's not in overflow).
func phase11OverflowMenuTests() -> TestSuite {
    let s = TestSuite("Phase11OverflowMenu")

    // MARK: - Assistant overflow

    s.test("assistant overflow on the last turn with multiple variants — full set, ≤4 items") {
        let items = TurnView.overflowItems(
            role: .assistant, isLastAssistant: true, variantCount: 3
        )
        try expectTrue(items.contains("Replay audio"))
        try expectTrue(items.contains("Continue"))
        try expectTrue(items.contains("Discard this variant"))
        try expectTrue(items.contains("Delete"))
        try expectTrue(items.count <= 4, "got \(items.count) overflow items: \(items)")
    }

    s.test("assistant overflow on a non-last turn drops Continue") {
        // Continue only makes sense on the trailing assistant turn —
        // continuing into the middle of history would fork a branch
        // (which is what the explicit fork action is for).
        let items = TurnView.overflowItems(
            role: .assistant, isLastAssistant: false, variantCount: 3
        )
        try expectTrue(!items.contains("Continue"))
        try expectTrue(items.contains("Discard this variant"))
        try expectTrue(items.contains("Delete"))
    }

    s.test("assistant overflow with only one variant drops Discard this variant") {
        // No alternatives to fall back to — discarding the only
        // variant would leave an empty turn.
        let items = TurnView.overflowItems(
            role: .assistant, isLastAssistant: true, variantCount: 1
        )
        try expectTrue(!items.contains("Discard this variant"))
        try expectTrue(items.contains("Continue"))
        try expectTrue(items.contains("Delete"))
    }

    s.test("assistant overflow always keeps Replay audio + Delete") {
        // Even on a non-last single-variant assistant turn (the most
        // restricted case) these two stay — replay because audio is
        // a per-turn affordance independent of variants, delete
        // because removing a turn is always meaningful.
        let items = TurnView.overflowItems(
            role: .assistant, isLastAssistant: false, variantCount: 1
        )
        try expectTrue(items.contains("Replay audio"))
        try expectTrue(items.contains("Delete"))
    }

    // MARK: - User overflow

    s.test("user overflow contains Copy and nothing else") {
        // User primary is [edit] [delete] [⋯] per §4.3. Overflow
        // carries Copy (low-frequency-but-useful). Nothing else
        // belongs there today.
        let items = TurnView.overflowItems(
            role: .user, isLastAssistant: false, variantCount: 1
        )
        try expectEqual(items, ["Copy"])
    }

    s.test("user overflow ignores variantCount + isLastAssistant") {
        // User turns never fan out into variants. Defensive: even
        // if a hand-edited JSON sets variantCount > 1 on a user turn,
        // the overflow stays as just Copy.
        let items = TurnView.overflowItems(
            role: .user, isLastAssistant: true, variantCount: 5
        )
        try expectEqual(items, ["Copy"])
    }

    return s
}
