import AppKit

/// Phase 9 §5.3c.2 — labeled single-line text field. Sibling of
/// `MultilineFieldView` but cheaper since the input is a single-line
/// `NSTextField` with no auto-grow logic. Used by the Details tab's
/// Age / Pronouns / Species / Orientation fields.
final class SingleLineFieldView: NSView {

    var onChange: ((String) -> Void)?

    private let labelView = NSTextField(labelWithString: "")
    private let field = NSTextField()
    private let hintView = NSTextField(labelWithString: "")

    private let label: String
    private let hint: String?
    private let placeholder: String?

    init(label: String,
         initialValue: String,
         placeholder: String? = nil,
         hint: String? = nil) {
        self.label = label
        self.hint = hint
        self.placeholder = placeholder
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValue: initialValue)
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    private func buildUI(initialValue: String) {
        labelView.stringValue = label
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(labelView)

        field.translatesAutoresizingMaskIntoConstraints = false
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = DesignTokens.Typography.body
        field.stringValue = initialValue
        if let placeholder = placeholder {
            field.placeholderString = placeholder
        }
        field.delegate = self
        addSubview(field)

        let hasHint = (hint != nil)
        if let hintText = hint {
            hintView.stringValue = hintText
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.secondary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 2
            hintView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hintView)
        }

        var constraints: [NSLayoutConstraint] = [
            labelView.topAnchor.constraint(equalTo: topAnchor),
            labelView.leadingAnchor.constraint(equalTo: leadingAnchor),

            field.topAnchor.constraint(equalTo: labelView.bottomAnchor, constant: DesignTokens.Spacing.xs),
            field.leadingAnchor.constraint(equalTo: leadingAnchor),
            field.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        if hasHint {
            constraints += [
                hintView.topAnchor.constraint(equalTo: field.bottomAnchor, constant: DesignTokens.Spacing.xs),
                hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hintView.trailingAnchor.constraint(equalTo: trailingAnchor),
                hintView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ]
        } else {
            constraints.append(field.bottomAnchor.constraint(equalTo: bottomAnchor))
        }
        NSLayoutConstraint.activate(constraints)
    }
}

extension SingleLineFieldView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onChange?(field.stringValue)
    }
}
