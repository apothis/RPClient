import Foundation
@testable import RPClientCore

/// Phase 11 §4.0.f / §4.d.2 — title formatter for the "branches: N ▸"
/// pill that surfaces on diverging messages. Pure data; no AppKit
/// dependency. Returns nil when the count means there's nothing to
/// disclose (single-variant, root, or off-tree).
///
/// Spec §4.0.f keeps both inline + inspector for branches: a small
/// pill on diverging messages opens the existing sibling popover
/// (RPClient's lightweight inline path; the spec's "inspector" is
/// the future scaling answer for >3-4 branches per research §A.1.6).
func phase11BranchesPillTests() -> TestSuite {
    let s = TestSuite("Phase11BranchesPill")

    s.test("siblingCount of 1 — no pill (root or only-child)") {
        try expectEqual(TurnView.branchesPillTitle(siblingCount: 1), nil)
    }

    s.test("siblingCount of 0 — no pill (defensive)") {
        try expectEqual(TurnView.branchesPillTitle(siblingCount: 0), nil)
    }

    s.test("siblingCount of 2 — branches: 2") {
        try expectEqual(TurnView.branchesPillTitle(siblingCount: 2), "branches: 2")
    }

    s.test("siblingCount of 7 — branches: 7") {
        try expectEqual(TurnView.branchesPillTitle(siblingCount: 7), "branches: 7")
    }

    return s
}
