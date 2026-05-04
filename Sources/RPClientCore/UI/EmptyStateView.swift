import AppKit

protocol EmptyStateViewDelegate: AnyObject {
    func emptyStateDidPickStarter(_ view: EmptyStateView, text: String)
}

final class EmptyStateView: NSView {
    weak var delegate: EmptyStateViewDelegate?

    private let glyph = NSTextField(labelWithString: "✦")
    private let title = NSTextField(labelWithString: "Start a new chat")
    private let subtitle = NSTextField(labelWithString: "Send a message to begin")
    private let chipsStack = NSStackView()

    private let starters: [String] = [
        "Set the scene",
        "Introduce a character",
        "Pick up where we left off",
        "Surprise me"
    ]

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        glyph.font = Theme.font(44, weight: .light)
        glyph.textColor = .tertiaryLabelColor
        glyph.alignment = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glyph)

        title.font = Theme.font(22, weight: .semibold)
        title.textColor = .labelColor
        title.alignment = .center
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        subtitle.font = Theme.font(13)
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        chipsStack.orientation = .horizontal
        chipsStack.spacing = 8
        chipsStack.alignment = .centerY
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipsStack)

        for s in starters {
            let btn = ChipButton(title: s)
            btn.target = self
            btn.action = #selector(chipTapped(_:))
            chipsStack.addArrangedSubview(btn)
        }

        NSLayoutConstraint.activate([
            glyph.centerXAnchor.constraint(equalTo: centerXAnchor),
            glyph.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -80),

            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: glyph.bottomAnchor, constant: 12),

            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 6),

            chipsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            chipsStack.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 28),
            chipsStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 16),
            chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16)
        ])
    }

    required init?(coder: NSCoder) { nil }

    @objc private func chipTapped(_ sender: ChipButton) {
        delegate?.emptyStateDidPickStarter(self, text: sender.title)
    }
}

private final class ChipButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        isBordered = false
        wantsLayer = true
        font = Theme.font(13)
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 28).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 14
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 28
        return s
    }
}
