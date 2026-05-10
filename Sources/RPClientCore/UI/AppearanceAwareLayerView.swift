import AppKit

/// Layer-backed `NSView` that re-resolves its layer's background and border
/// colors when the system appearance flips (light ↔ dark, or the user
/// changes their accent color). Avoids the canonical AppKit dark-mode trap:
/// `NSColor.cgColor` captures a *snapshot* at assignment time, so a layer
/// that was assigned `NSColor.controlBackgroundColor.cgColor` in light mode
/// will stay light when the system flips to dark.
///
/// Usage: assign `backgroundColor` / `borderColor` as `NSColor` (semantic),
/// not `CGColor`. The view re-derives the CGColor on every appearance
/// change. Set `cornerRadiusValue` / `borderWidthValue` directly.
///
/// The alternative — overriding `updateLayer()` — works only on the
/// receiver itself; this helper lets composite views (`AvatarControl`,
/// pill chips) use the same pattern without re-implementing it.
final class AppearanceAwareLayerView: NSView {

    var backgroundColor: NSColor? {
        didSet { applyColors() }
    }

    var borderColor: NSColor? {
        didSet { applyColors() }
    }

    var borderWidthValue: CGFloat = 0 {
        didSet { layer?.borderWidth = borderWidthValue }
    }

    var cornerRadiusValue: CGFloat = 0 {
        didSet {
            layer?.cornerRadius = cornerRadiusValue
            layer?.cornerCurve = .continuous
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyColors()
    }

    private func applyColors() {
        guard let layer = layer else { return }
        // Resolve the CGColors under this view's effective appearance so the
        // colors track even when the view is in a window with a non-default
        // appearance override.
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let bg = backgroundColor {
                layer.backgroundColor = bg.cgColor
            } else {
                layer.backgroundColor = nil
            }
            if let border = borderColor {
                layer.borderColor = border.cgColor
            } else {
                layer.borderColor = nil
            }
        }
    }
}
