import AppKit

/// Phase 9 §5.3a / §3.2 — Identity tab content. Two-column layout: avatar
/// control on the left, name / nickname / tags / creator / version stack on
/// the right. Field labels are `headline` semibold; inputs are `body`. The
/// label/input contrast does the hierarchy work; color does not.
final class IdentityTabViewController: NSViewController {

    private let draft: CharacterDraft
    private let onDirty: () -> Void

    private let avatarControl = AvatarControl()
    private let nameField = NSTextField()
    private let nicknameField = NSTextField()
    private let tagsField = NSTokenField()
    private let creatorField = NSTextField()
    private let versionField = NSTextField()

    init(draft: CharacterDraft, onDirty: @escaping () -> Void) {
        self.draft = draft
        self.onDirty = onDirty
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root

        // Left column — avatar control.
        avatarControl.translatesAutoresizingMaskIntoConstraints = false
        avatarControl.loadAvatarUnchecked(draft.avatarPNG)
        avatarControl.onChange = { [weak self] data in
            self?.draft.avatarPNG = data
            self?.draft.markDirty()
            self?.onDirty()
        }
        root.addSubview(avatarControl)

        // Right column — field stack.
        let fieldStack = NSStackView()
        fieldStack.orientation = .vertical
        fieldStack.alignment = .leading
        fieldStack.spacing = DesignTokens.Spacing.md
        fieldStack.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(fieldStack)

        // Name (required).
        configureField(nameField, placeholder: "Marin", width: 360)
        nameField.stringValue = draft.character.name
        let nameRow = labeledRow("Name", control: nameField,
                                 hint: "How the character is identified in the library and prompts.")
        fieldStack.addArrangedSubview(nameRow)

        // Nickname (v3, optional).
        configureField(nicknameField, placeholder: "Captain", width: 360)
        nicknameField.stringValue = draft.character.nickname ?? ""
        let nicknameRow = labeledRow("Nickname",
                                     control: nicknameField,
                                     hint: "Replaces {{char}} in v3 prompts. Falls back to Name. Optional.",
                                     v3Only: true)
        fieldStack.addArrangedSubview(nicknameRow)

        // Tags (token field).
        tagsField.translatesAutoresizingMaskIntoConstraints = false
        tagsField.tokenStyle = .rounded
        tagsField.controlSize = .small
        tagsField.placeholderString = "Add tags…"
        tagsField.objectValue = draft.character.tags
        tagsField.delegate = self
        tagsField.font = DesignTokens.Typography.body
        let tagsRow = labeledRow("Tags",
                                 control: tagsField,
                                 hint: "Comma-separated. Used by the library for filtering. Common tags autocomplete.",
                                 width: 360)
        fieldStack.addArrangedSubview(tagsRow)

        // Creator (optional).
        configureField(creatorField, placeholder: "anon", width: 240)
        creatorField.stringValue = draft.character.creator ?? ""
        let creatorRow = labeledRow("Creator", control: creatorField,
                                    hint: "Author credit. Display only; never reaches the prompt.")
        fieldStack.addArrangedSubview(creatorRow)

        // Version (optional, mono per §11 — numeric/version content).
        configureField(versionField, placeholder: "1.0", width: 120)
        versionField.stringValue = draft.character.characterVersion ?? ""
        versionField.font = DesignTokens.Typography.mono(.body)
        let versionRow = labeledRow("Version", control: versionField,
                                    hint: "Semantic version of this card (1.0, 1.2, 2.0…). Optional.")
        fieldStack.addArrangedSubview(versionRow)

        // Wire change events for dirty tracking.
        for field in [nameField, nicknameField, creatorField, versionField] {
            field.delegate = self
        }

        NSLayoutConstraint.activate([
            avatarControl.topAnchor.constraint(equalTo: root.topAnchor, constant: DesignTokens.Spacing.xl),
            avatarControl.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Spacing.xl),

            fieldStack.topAnchor.constraint(equalTo: root.topAnchor, constant: DesignTokens.Spacing.xl),
            fieldStack.leadingAnchor.constraint(equalTo: avatarControl.trailingAnchor, constant: DesignTokens.Spacing.xl),
            fieldStack.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -DesignTokens.Spacing.xl),
            fieldStack.bottomAnchor.constraint(lessThanOrEqualTo: root.bottomAnchor, constant: -DesignTokens.Spacing.xl),
        ])
    }

    // MARK: - Row builder

    private func labeledRow(
        _ label: String,
        control: NSView,
        hint: String? = nil,
        v3Only: Bool = false,
        width: CGFloat? = nil
    ) -> NSView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Label row (label + optional v3 pill).
        let labelRow = NSStackView()
        labelRow.orientation = .horizontal
        labelRow.spacing = DesignTokens.Spacing.xs
        labelRow.alignment = .firstBaseline

        let labelView = NSTextField(labelWithString: label)
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelRow.addArrangedSubview(labelView)

        if v3Only {
            labelRow.addArrangedSubview(makeV3Pill())
        }

        stack.addArrangedSubview(labelRow)
        stack.addArrangedSubview(control)

        if let hint = hint {
            let hintView = NSTextField(labelWithString: hint)
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.tertiary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 2
            hintView.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(hintView)
            if let width = width {
                hintView.widthAnchor.constraint(equalToConstant: width).isActive = true
            } else {
                hintView.widthAnchor.constraint(equalToConstant: 360).isActive = true
            }
        }

        return stack
    }

    private func configureField(_ field: NSTextField, placeholder: String, width: CGFloat) {
        field.translatesAutoresizingMaskIntoConstraints = false
        field.bezelStyle = .roundedBezel
        field.controlSize = .regular
        field.font = DesignTokens.Typography.body
        field.placeholderString = placeholder
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
    }

    private func makeV3Pill() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.wantsLayer = true
        pill.layer?.backgroundColor = DesignTokens.Background.group.cgColor
        pill.layer?.cornerRadius = DesignTokens.Radius.chip
        pill.layer?.cornerCurve = .continuous

        // Inset the text via a wrapping container so the pill has padding.
        let wrap = NSView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.wantsLayer = true
        wrap.layer?.backgroundColor = DesignTokens.Background.group.cgColor
        wrap.layer?.cornerRadius = DesignTokens.Radius.chip
        wrap.layer?.cornerCurve = .continuous
        wrap.addSubview(pill)
        pill.layer?.backgroundColor = NSColor.clear.cgColor
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}

// MARK: - NSTextFieldDelegate / NSTokenFieldDelegate

extension IdentityTabViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField: draft.character.name = field.stringValue
        case nicknameField: draft.character.nickname = nonEmpty(field.stringValue)
        case creatorField: draft.character.creator = nonEmpty(field.stringValue)
        case versionField: draft.character.characterVersion = nonEmpty(field.stringValue)
        default: return
        }
        draft.markDirty()
        onDirty()
    }

    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension IdentityTabViewController: NSTokenFieldDelegate {
    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let needle = substring.lowercased()
        guard !needle.isEmpty else { return [] }
        return TagVocabulary.shared.matches(prefix: needle).map { $0 as Any }
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        if let tokenField = control as? NSTokenField, tokenField === tagsField {
            let tokens = (tokenField.objectValue as? [String]) ?? []
            draft.character.tags = tokens
            draft.markDirty()
            onDirty()
        }
        return true
    }
}
