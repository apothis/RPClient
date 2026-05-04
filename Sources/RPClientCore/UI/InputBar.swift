import AppKit

protocol InputBarDelegate: AnyObject {
    func inputBarSend(_ bar: InputBar, text: String)
    func inputBarStop(_ bar: InputBar)
}

final class InputBar: NSView, NSTextViewDelegate {
    weak var delegate: InputBarDelegate?

    private let pill = NSView()
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private let primaryButton = NSButton()

    private enum PrimaryAction { case send, stop }
    private var primaryAction: PrimaryAction = .send

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        pill.wantsLayer = true
        pill.layer?.cornerRadius = 18
        pill.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pill)

        textView.isRichText = false
        textView.font = Theme.font(15)
        textView.allowsUndo = true
        textView.delegate = self
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: 22)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = false

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(scrollView)

        primaryButton.target = self
        primaryButton.action = #selector(primaryTapped)
        primaryButton.bezelStyle = .inline
        primaryButton.isBordered = false
        primaryButton.imagePosition = .imageOnly
        primaryButton.imageScaling = .scaleProportionallyDown
        primaryButton.translatesAutoresizingMaskIntoConstraints = false
        primaryButton.keyEquivalent = "\r"
        pill.addSubview(primaryButton)

        NSLayoutConstraint.activate([
            pill.topAnchor.constraint(equalTo: topAnchor, constant: 10),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            scrollView.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 14),
            scrollView.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),

            primaryButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            primaryButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            primaryButton.widthAnchor.constraint(equalToConstant: 30),
            primaryButton.heightAnchor.constraint(equalToConstant: 30),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 70)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(streamStateChanged),
            name: AppNotification.streamFinished, object: nil)
        nc.addObserver(self, selector: #selector(streamStateChanged),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleFontChanged),
            name: AppNotification.fontChanged, object: nil)
        updateButtons()
    }

    @objc private func handleFontChanged() {
        textView.font = Theme.font(15)
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolve dynamic colors in the current appearance context.
        pill.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        pill.layer?.borderColor = NSColor.separatorColor.cgColor
        pill.layer?.borderWidth = 0.5
    }

    @objc private func primaryTapped() {
        switch primaryAction {
        case .send:
            let text = textView.string
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            delegate?.inputBarSend(self, text: text)
            textView.string = ""
            updateButtons()
        case .stop:
            delegate?.inputBarStop(self)
        }
    }

    @objc private func streamStateChanged() {
        updateButtons()
    }

    func updateButtons() {
        let s = AppState.shared
        let busy = s.isStreaming || s.isSummarizing || s.isExtracting
        if busy {
            primaryAction = .stop
            primaryButton.image = NSImage(
                systemSymbolName: "stop.circle.fill",
                accessibilityDescription: "Stop"
            )
            primaryButton.contentTintColor = .systemRed
            primaryButton.isEnabled = true
            primaryButton.toolTip = "Stop"
        } else {
            primaryAction = .send
            primaryButton.image = NSImage(
                systemSymbolName: "arrow.up.circle.fill",
                accessibilityDescription: "Send"
            )
            let hasText = !textView.string
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            primaryButton.contentTintColor = hasText
                ? .controlAccentColor
                : .tertiaryLabelColor
            primaryButton.isEnabled = hasText
            primaryButton.toolTip = "Send"
        }
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        // Refresh send-button enable state as the user types.
        if !AppState.shared.isStreaming
            && !AppState.shared.isSummarizing
            && !AppState.shared.isExtracting {
            updateButtons()
        }
    }

    // Enter sends; Shift+Enter inserts a newline.
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false
            if shift {
                textView.insertNewlineIgnoringFieldEditor(nil)
            } else {
                primaryTapped()
            }
            return true
        }
        return false
    }
}
