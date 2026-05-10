import Foundation
import CoreGraphics
@testable import RPClientCore

/// V2_UI_OVERHAUL §4.8 / §4.i — layout-stability invariants suite.
///
/// What's covered here (pure-data helpers):
///   1. **No scroll-position loss on send** (invariant §4.8.1) — the
///      `userScrolledUp` decision that gates auto-scroll. Verified
///      via [`ScrollFollow.userIsScrolledUp`](Sources/RPClientCore/UI/ScrollFollow.swift).
///   2. **No scroll-jump on streaming token-land** (invariant §4.8.2) —
///      same gate; the streaming token handler reads the same flag
///      so the math being correct is sufficient for both invariants.
///   6. **No control collisions when inspector toggles** (invariant
///      §4.8.6) — pill row width-responsive collapse is covered
///      separately by [`Phase11PillFlow`](Phase11PillFlowTests.swift).
///
/// What's NOT covered here (and why):
///   3. **No jump on `<think>` expand/collapse** (invariant §4.8.3) —
///      the disclosure animation runs through `NSAnimationContext`
///      and its surrounding-row reflow is observable only against a
///      laid-out NSScrollView. Disclosure height math itself is
///      already covered by `Phase11ThinkDisclosureHeight`; the
///      layout-jump *behaviour* needs an NSWindow harness, which
///      this CLT-only test runner can't host.
///   4. **No flicker on inspector toggle** (invariant §4.8.4) — same
///      reason: the 180ms easeOut behaviour is observable only on
///      a real window. Best caught by manual smoke today.
///   5. **No glitchy redraws on window resize** (invariant §4.8.5) —
///      single-layout-pass behaviour is an NSWindow concern.
///
/// The intermittent blank-window bug
/// [`memory/project_blank_window_bug.md`] could be either layout or
/// state — this suite shrinks the layout-side surface area by
/// pinning the scroll-follow math; the state-side surface still
/// needs separate investigation.
func phase11LayoutStabilityTests() -> TestSuite {
    let s = TestSuite("Phase11LayoutStability")

    // MARK: - §4.8.1 / §4.8.2 — at-bottom detection

    s.test("at exact bottom → not scrolled up") {
        // doc 1000pt tall, visible reaches exactly to 1000 → dist 0.
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 1000, visibleBottomY: 1000
        ))
    }

    s.test("threshold pixels above bottom → still not scrolled up (boundary inclusive)") {
        // dist == threshold → strict-greater-than means: still at-bottom.
        // Locks in the boundary semantics so a single streamed token's
        // descender doesn't flip the user into pinned mode.
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 1000, visibleBottomY: 920,
            threshold: 80
        ))
    }

    s.test("threshold + 1 above bottom → scrolled up") {
        try expectTrue(ScrollFollow.userIsScrolledUp(
            docHeight: 1000, visibleBottomY: 919,
            threshold: 80
        ))
    }

    s.test("scrolled to top of long doc → scrolled up") {
        try expectTrue(ScrollFollow.userIsScrolledUp(
            docHeight: 5000, visibleBottomY: 600
        ))
    }

    s.test("default threshold matches the production constant") {
        // Sanity: the test helpers above pass `threshold: 80`. If
        // someone bumps the production threshold without updating the
        // tests, this catches it.
        try expectEqual(ScrollFollow.defaultThreshold, 80)
    }

    s.test("custom threshold of 0 → any pixel of distance counts as scrolled up") {
        try expectTrue(ScrollFollow.userIsScrolledUp(
            docHeight: 1000, visibleBottomY: 999,
            threshold: 0
        ))
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 1000, visibleBottomY: 1000,
            threshold: 0
        ))
    }

    s.test("visible bottom past document end → clamps to at-bottom (no negative-dist false positive)") {
        // Transient during resize / re-layout AppKit can produce
        // visibleBottomY > docHeight; if we returned true here we'd
        // erroneously pin scroll on every resize.
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 800, visibleBottomY: 850
        ))
    }

    s.test("empty document (height 0) → not scrolled up regardless of visible") {
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 0, visibleBottomY: 0
        ))
        try expectFalse(ScrollFollow.userIsScrolledUp(
            docHeight: 0, visibleBottomY: 100
        ))
    }

    return s
}
