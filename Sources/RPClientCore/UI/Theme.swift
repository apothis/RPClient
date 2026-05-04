import AppKit

/// Centralised font sizing so a single user setting (`uiFontOffset`) can scale
/// every label, text view, and button across the app. All UI sites that used
/// `NSFont.systemFont(ofSize: N)` should call `Theme.font(N)` instead.
enum Theme {
    static var fontOffset: Int { AppState.shared.settings.uiFontOffset }

    static func size(_ base: CGFloat) -> CGFloat {
        max(8, base + CGFloat(fontOffset))
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
