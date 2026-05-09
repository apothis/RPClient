import AppKit
import Foundation
@testable import RPClientCore

/// Phase 11 §4.a — chat-pane-specific token aliases on top of
/// `DesignTokens`. Per V2_UI_OVERHAUL.md §4.0 / §4.3 / §4.11, these
/// names exist so call sites in TurnView / composer / per-turn controls
/// read in chat-vocabulary terms (`Chat.turnGap`, `Chat.avatarSize`)
/// rather than reaching for `Spacing.md` / `Spacing.xl` directly.
///
/// Two contracts these tests pin:
///
/// 1. **Canonical values.** The locked decisions in V2_UI_OVERHAUL §4.0
///    (avatar gutter `xl` 32pt; bubble radius 14pt; turn gap `md` 16pt;
///    transcript max width 720pt) cannot drift silently.
///
/// 2. **No forking.** Chat-namespace tokens must alias the underlying
///    `Spacing` / `Radius` tokens — never duplicate the literal. If the
///    design language ever bumps `md` to 14 or `xl` to 36, the chat
///    layout follows automatically. A future "let me just hardcode 32"
///    regression hits these tests.
func phase11ChatTokensTests() -> TestSuite {
    let s = TestSuite("Phase11ChatTokens")

    // MARK: - Canonical values per V2_UI_OVERHAUL §4.0 / §4.3

    s.test("Chat.transcriptMaxWidth is 720 (§4.3 max content width)") {
        try expectEqual(DesignTokens.Chat.transcriptMaxWidth, 720)
    }

    s.test("Chat.avatarSize is 32 (§4.0.b xl gutter)") {
        try expectEqual(DesignTokens.Chat.avatarSize, 32)
    }

    s.test("Chat.avatarGutter is 32 (§4.3 [32pt avatar gutter] [sm gap] [body])") {
        try expectEqual(DesignTokens.Chat.avatarGutter, 32)
    }

    s.test("Chat.bubbleRadius is 14 (§4.3 user-turn bubble — matches Radius.section)") {
        try expectEqual(DesignTokens.Chat.bubbleRadius, 14)
    }

    s.test("Chat.turnGap is 16 (§4.3 vertical rhythm between turns — md)") {
        try expectEqual(DesignTokens.Chat.turnGap, 16)
    }

    s.test("Chat.avatarToBodyGap is 8 (§4.3 sm gap between gutter and body)") {
        try expectEqual(DesignTokens.Chat.avatarToBodyGap, 8)
    }

    // MARK: - No-forking contract — chat names alias underlying tokens

    s.test("Chat.avatarSize aliases Spacing.xl (no fork)") {
        try expectEqual(DesignTokens.Chat.avatarSize, DesignTokens.Spacing.xl)
    }

    s.test("Chat.avatarGutter aliases Spacing.xl (no fork)") {
        try expectEqual(DesignTokens.Chat.avatarGutter, DesignTokens.Spacing.xl)
    }

    s.test("Chat.turnGap aliases Spacing.md (no fork)") {
        try expectEqual(DesignTokens.Chat.turnGap, DesignTokens.Spacing.md)
    }

    s.test("Chat.avatarToBodyGap aliases Spacing.sm (no fork)") {
        try expectEqual(DesignTokens.Chat.avatarToBodyGap, DesignTokens.Spacing.sm)
    }

    s.test("Chat.bubbleRadius aliases Radius.section (no fork)") {
        try expectEqual(DesignTokens.Chat.bubbleRadius, DesignTokens.Radius.section)
    }

    // MARK: - transcriptMaxWidth is genuinely new (not aliased)

    s.test("transcriptMaxWidth is content-width, not a Spacing alias") {
        // 720 doesn't appear in Spacing — it's a content-column rule, not
        // a grid token. This test exists so a future reader doesn't
        // mistake it for an alias and try to add `Spacing.transcript = 720`
        // (which would violate the 8pt-grid principle).
        try expectTrue(DesignTokens.Chat.transcriptMaxWidth != DesignTokens.Spacing.xs)
        try expectTrue(DesignTokens.Chat.transcriptMaxWidth != DesignTokens.Spacing.sm)
        try expectTrue(DesignTokens.Chat.transcriptMaxWidth != DesignTokens.Spacing.md)
        try expectTrue(DesignTokens.Chat.transcriptMaxWidth != DesignTokens.Spacing.lg)
        try expectTrue(DesignTokens.Chat.transcriptMaxWidth != DesignTokens.Spacing.xl)
    }

    return s
}
