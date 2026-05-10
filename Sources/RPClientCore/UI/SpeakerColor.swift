import AppKit
import Foundation

/// Phase 8 §4.3 — deterministic accent colour for a cast-member id. Used
/// by the speaker chip on assistant turn bubbles (§6.2) and by the
/// speaker-aware Branches/Tree minimap glyphs (§4.5) so a given character
/// always has the same colour wherever they appear in the UI.
///
/// Palette is hand-picked rather than generated so all colours stay
/// distinguishable from each other and from the chat background. Twelve
/// entries — well past the practical cast-size ceiling. UUID bytes hash
/// into the palette index via FNV-1a (cheap, dep-free, no Foundation
/// hashing-randomization across launches).
enum SpeakerColor {
    /// Hand-picked palette tuned for both light and dark mode. Each entry
    /// is medium-saturation so a 24px chip remains legible against the
    /// chat-bubble fill in either appearance. Order is incidental — only
    /// the count matters for the hash mapping.
    private static let palette: [NSColor] = [
        NSColor(srgbRed: 0.84, green: 0.45, blue: 0.40, alpha: 1.0),  // coral
        NSColor(srgbRed: 0.40, green: 0.65, blue: 0.85, alpha: 1.0),  // sky
        NSColor(srgbRed: 0.55, green: 0.75, blue: 0.45, alpha: 1.0),  // sage
        NSColor(srgbRed: 0.85, green: 0.65, blue: 0.35, alpha: 1.0),  // amber
        NSColor(srgbRed: 0.65, green: 0.50, blue: 0.85, alpha: 1.0),  // lavender
        NSColor(srgbRed: 0.45, green: 0.75, blue: 0.75, alpha: 1.0),  // teal
        NSColor(srgbRed: 0.85, green: 0.55, blue: 0.70, alpha: 1.0),  // rose
        NSColor(srgbRed: 0.50, green: 0.55, blue: 0.80, alpha: 1.0),  // periwinkle
        NSColor(srgbRed: 0.75, green: 0.70, blue: 0.40, alpha: 1.0),  // olive
        NSColor(srgbRed: 0.70, green: 0.45, blue: 0.55, alpha: 1.0),  // mauve
        NSColor(srgbRed: 0.45, green: 0.70, blue: 0.55, alpha: 1.0),  // emerald
        NSColor(srgbRed: 0.85, green: 0.50, blue: 0.55, alpha: 1.0),  // salmon
    ]

    /// Deterministic accent for `id`. Same id always returns the same
    /// colour, both within a launch and across launches (FNV-1a is
    /// stable; doesn't use Swift's randomized hashing).
    static func accent(for id: UUID) -> NSColor {
        let bytes = withUnsafeBytes(of: id.uuid) { Array($0) }
        var h: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for b in bytes {
            h ^= UInt64(b)
            h = h &* prime
        }
        let idx = Int(h % UInt64(palette.count))
        return palette[idx]
    }
}
