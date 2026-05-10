import AppKit

/// Centralised font factories. The pre-§4.j.2 `uiFontOffset` user
/// setting that scaled every label is gone (V2_DESIGN_LANGUAGE.md §10
/// anti-pattern); macOS Dynamic Type via
/// `NSFont.preferredFont(forTextStyle:)` is the long-term replacement.
/// Callers that still pass an absolute pt value are kept working
/// here so this removal didn't have to ripple into every UI site.
enum Theme {
    static func size(_ base: CGFloat) -> CGFloat {
        max(8, base)
    }

    static func font(_ base: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.systemFont(ofSize: size(base), weight: weight)
    }

    static func mono(_ base: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: size(base), weight: weight)
    }

    static func bold(_ base: CGFloat) -> NSFont {
        NSFont.boldSystemFont(ofSize: size(base))
    }
}
