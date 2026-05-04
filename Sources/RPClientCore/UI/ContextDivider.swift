import AppKit

final class ContextDivider: NSView {
    private let label = NSTextField(labelWithString: "— not in context —")

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        label.font = Theme.font(10, weight: .medium)
        label.textColor = .tertiaryLabelColor
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        let leftLine = lineView()
        let rightLine = lineView()
        addSubview(leftLine)
        addSubview(label)
        addSubview(rightLine)

        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: centerXAnchor),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),

            leftLine.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftLine.trailingAnchor.constraint(equalTo: label.leadingAnchor, constant: -8),
            leftLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            leftLine.heightAnchor.constraint(equalToConstant: 1),

            rightLine.leadingAnchor.constraint(equalTo: label.trailingAnchor, constant: 8),
            rightLine.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            rightLine.centerYAnchor.constraint(equalTo: centerYAnchor),
            rightLine.heightAnchor.constraint(equalToConstant: 1),

            heightAnchor.constraint(equalToConstant: 18)
        ])
    }

    required init?(coder: NSCoder) { nil }

    private func lineView() -> NSView {
        let v = SeparatorLine()
        v.translatesAutoresizingMaskIntoConstraints = false
        return v
    }
}

private final class SeparatorLine: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        layer?.backgroundColor = NSColor.separatorColor.cgColor
    }
}
