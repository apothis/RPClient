import Foundation
import CoreGraphics

/// V2_UI_OVERHAUL §4.8 (invariants 1 + 2) — pure-data helper for the
/// transcript's scroll-follow decision. The chat pane auto-scrolls
/// to the bottom on send and on every streaming token, but ONLY if
/// the user is at-bottom; if they've scrolled up to read history we
/// must pin the scroll position absolutely (the at-bottom-pill below
/// the transcript handles their re-entry).
///
/// Lifted out of `ChatViewController.handleScroll` so the threshold
/// semantics are unit-testable without standing up an NSScrollView.
enum ScrollFollow {
    /// V2_UI_OVERHAUL §4.5 — the slack zone that still counts as
    /// "at the bottom" so a one-line cursor descender or a single
    /// streamed token doesn't accidentally flip us into pinned-mode.
    /// Empirically tuned 2026-04 to 80pt; bumped to a constant so
    /// tests anchor against the same value the production code uses.
    static let defaultThreshold: CGFloat = 80

    /// Returns true when the user has scrolled away from the bottom
    /// by more than `threshold`. When true, callers MUST NOT
    /// auto-scroll on streaming tokens / placeholder-turn insertion
    /// (§4.8 invariants 1 + 2).
    ///
    /// `docHeight` = `scrollView.documentView.frame.height`.
    /// `visibleBottomY` = `scrollView.contentView.bounds.maxY` (the
    /// clip view's visible-rect lower edge in document coordinates).
    /// Both come straight from AppKit; we just compare them.
    ///
    /// Negative `dist` (visible bottom past the document — usually
    /// transient during resize / layout) clamps to zero and reads
    /// as "at-bottom" so we don't accidentally pin during a
    /// re-layout pass.
    static func userIsScrolledUp(
        docHeight: CGFloat,
        visibleBottomY: CGFloat,
        threshold: CGFloat = defaultThreshold
    ) -> Bool {
        let dist = max(0, docHeight - visibleBottomY)
        return dist > threshold
    }
}
