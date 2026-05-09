import AppKit
import Foundation
@testable import RPClientCore

/// Phase 11 §4.b / §4.7 — italics in the chat transcript re-tint to
/// `secondaryLabelColor`. RP authors use `*action*` semantics; the
/// secondary tone reads as "narration aside, not dialogue" without
/// losing the italics. Speech (unmarked) stays at `labelColor`.
func phase11ItalicTintTests() -> TestSuite {
    let s = TestSuite("Phase11ItalicTint")

    s.test("*italic* range carries secondaryLabelColor") {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let attr = Markdown.render("She smiled. *softly*", baseFont: base)
        // Find the substring "softly" in the rendered string and check
        // its foreground color attribute.
        let ns = attr.string as NSString
        let r = ns.range(of: "softly")
        try expectTrue(r.location != NSNotFound, "rendered string missing italic content")
        let attrs = attr.attributes(at: r.location, effectiveRange: nil)
        let fg = attrs[.foregroundColor] as? NSColor
        try expectEqual(fg, NSColor.secondaryLabelColor)
    }

    s.test("non-italic text keeps labelColor") {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let attr = Markdown.render("She smiled.", baseFont: base)
        let attrs = attr.attributes(at: 0, effectiveRange: nil)
        let fg = attrs[.foregroundColor] as? NSColor
        try expectEqual(fg, NSColor.labelColor)
    }

    s.test("**bold** stays at labelColor (only italics are re-tinted)") {
        let base = NSFont.preferredFont(forTextStyle: .body)
        let attr = Markdown.render("She **stopped**.", baseFont: base)
        let ns = attr.string as NSString
        let r = ns.range(of: "stopped")
        try expectTrue(r.location != NSNotFound)
        let attrs = attr.attributes(at: r.location, effectiveRange: nil)
        let fg = attrs[.foregroundColor] as? NSColor
        try expectEqual(fg, NSColor.labelColor)
    }

    return s
}
