import AppKit

/// Phase 9 §5.3b — labeled multi-line text input. Reused across Persona /
/// Greetings (firstMessage) / Examples / System tabs. Layout follows the
/// design-language application contract: label is `headline` (semibold,
/// label color); input is `body` (label color); hint below is `subheadline`
/// secondary; spacing uses tokens (xs between label and input, xs between
/// input and hint).
///
/// The text view auto-grows from `minHeight` (default 96pt) up to
/// `maxHeight` (default 320pt) before scrolling — for prose, this gives
/// authors a comfortable reading window without occupying the whole tab
/// when the field is short. Width target is 480pt: roughly 80 chars at
/// 13pt body, the readable-prose sweet spot.
final class MultilineFieldView: NSView {

    var onChange: ((String) -> Void)?

    private let labelView = NSTextField(labelWithString: "")
    private let v3PillContainer = NSView()
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let hintView = NSTextField(labelWithString: "")

    private let label: String
    private let hint: String?
    private let v3Only: Bool
    private let minHeight: CGFloat
    private let maxHeight: CGFloat

    private var heightConstraint: NSLayoutConstraint!

    init(label: String,
         initialValue: String,
         hint: String? = nil,
         v3Only: Bool = false,
         placeholder: String? = nil,
         minHeight: CGFloat = 96,
         maxHeight: CGFloat = 320) {
        self.label = label
        self.hint = hint
        self.v3Only = v3Only
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValue: initialValue, placeholder: placeholder)
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            recalculateHeight()
        }
    }

    private func buildUI(initialValue: String, placeholder: String?) {
        // Header row — label + v3 pill (if applicable).
        labelView.stringValue = label
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [labelView])
        header.orientation = .horizontal
        header.spacing = DesignTokens.Spacing.xs
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        if v3Only {
            header.addArrangedSubview(makeV3Pill())
        }
        addSubview(header)

        // Text view + scroll view.
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.isEditable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.usesFindBar = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.string = initialValue
        textView.delegate = self
        textView.translatesAutoresizingMaskIntoConstraints = false
        // Vertical insets so text doesn't sit flush against the top edge.
        textView.textContainerInset = NSSize(width: 4, height: 6)
        if let placeholder = placeholder {
            // NSTextView doesn't have a built-in placeholder — fake it
            // with attributed text rendered as caret guidance. We'll
            // leave it empty for now and revisit; placeholder glyph is
            // out of scope for §5.3b.
            _ = placeholder
        }

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = textView
        scrollView.drawsBackground = true

        // Bezel-style background — `textBackgroundColor` adapts.
        addSubview(scrollView)

        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: minHeight)
        heightConstraint.priority = .defaultHigh

        // Hint footer.
        if let hintText = hint {
            hintView.stringValue = hintText
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.secondary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 3
            hintView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hintView)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,
        ])

        if hint != nil {
            NSLayoutConstraint.activate([
                hintView.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: DesignTokens.Spacing.xs),
                hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hintView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor).isActive = true
        }

        // Initial height calc once layout pass settles.
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    private func makeV3Pill() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.drawsBackground = false

        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.group
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }

    /// Re-derive the scroll view's height from the text view's intrinsic
    /// content. Clamps between min and max so the field auto-grows on
    /// short prose and starts scrolling on long.
    private func recalculateHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset.height * 2
        let target = max(minHeight, min(maxHeight, used.height + inset + 8))
        if abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
        }
    }
}

extension MultilineFieldView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        recalculateHeight()
        onChange?(textView.string)
    }
}
