import AppKit

/// V2_UI_OVERHAUL §4.5 — three-dot animated indicator shown while
/// the assistant is mid-stream but no displayable tokens have arrived
/// (pre-token gap, typically 200-2000ms on local models, plus the
/// duration of any `<think>` block). Apple Messages convention.
///
/// Replaces the pre-§4.e.1 "Thinking…" italic-text body + the avatar
/// opacity pulse — the dots are quieter, instantly recognisable as
/// "something is coming", and don't fight the avatar's color.
///
/// Dots are 4pt circles, 7pt apart, opacity-pulsing 0.3 → 1.0 with a
/// 200ms phase offset per dot. `secondaryLabelColor` adapts to
/// light / dark / increase-contrast automatically via `updateLayer`.
final class TypingDotsView: NSView {
    private let dots: [DotLayer]

    override init(frame frameRect: NSRect) {
        dots = (0..<3).map { _ in DotLayer() }
        super.init(frame: frameRect)
        wantsLayer = true
        for (i, dot) in dots.enumerated() {
            addSubview(dot)
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 4),
                dot.heightAnchor.constraint(equalToConstant: 4),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.leadingAnchor.constraint(
                    equalTo: leadingAnchor,
                    constant: CGFloat(i) * 7
                )
            ])
        }
        widthAnchor.constraint(equalToConstant: 18).isActive = true
        heightAnchor.constraint(equalToConstant: 14).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    /// Begin the per-dot pulse cycle. Idempotent — calling twice
    /// doesn't stack animations.
    func startAnimating() {
        let now = CACurrentMediaTime()
        for (i, dot) in dots.enumerated() {
            dot.layer?.removeAnimation(forKey: "typingDots")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.3
            pulse.toValue = 1.0
            pulse.duration = 0.5
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            pulse.beginTime = now + Double(i) * 0.18
            dot.layer?.add(pulse, forKey: "typingDots")
        }
    }

    func stopAnimating() {
        for dot in dots {
            dot.layer?.removeAnimation(forKey: "typingDots")
        }
    }
}

/// Inner dot. Subclassed so `updateLayer()` re-applies the
/// secondary-label fill on appearance changes (light ↔ dark) without
/// needing a manual NSAppearance observer.
private final class DotLayer: NSView {
    override var wantsUpdateLayer: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 2
    }
    required init?(coder: NSCoder) { nil }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.secondaryLabelColor.cgColor
    }
}
