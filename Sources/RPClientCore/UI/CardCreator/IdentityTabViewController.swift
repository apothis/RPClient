import AppKit

/// Phase 9 §5.3a / §3.2 — Identity tab content. Two-column layout: avatar
/// control on the left, name / nickname / tags / creator / version stack on
/// the right. Field labels are `headline` semibold; inputs are `body`. The
/// label/input contrast does the hierarchy work; color does not.
final class IdentityTabViewController: NSViewController {

    private let draft: CharacterDraft
    private let onDirty: () -> Void
    private let aiRegistry: CardCreatorAIRegistry

    private let avatarControl = AvatarControl()
    private let nameField = NSTextField()
    private let nicknameField = NSTextField()
    private let tagsField = NSTokenField()
    private let creatorField = NSTextField()
    private let versionField = NSTextField()

    /// Phase 9 §5.4 — sex chooser. NSPopUpButton with the four common
    /// options + Other. Distinct from pronouns (the linguistic form);
    /// this is the biological / identity attribute that informs
    /// AI-assist generation across the card. Stored as
    /// `extensions["rpclient/details"].sex` alongside the rest of
    /// CardDetails (which is otherwise edited on the Details tab).
    private let sexPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let sexCustomField = NSTextField()
    private static let sexStandardOptions = ["Male", "Female", "Non-binary"]
    private static let sexUnsetTitle = "—"
    private static let sexOtherTitle = "Other"

    /// Row of small per-tag pills shown below the tags field for any
    /// tag that isn't in the bundled vocabulary OR the persistent
    /// custom-tags list. Each pill carries a toggle: ✗ (default —
    /// "use on this card only") or ✓ ("save to autocomplete vocab on
    /// next save"). The toggle is purely UI state until the author
    /// hits Save; only then do ✓-marked tags get promoted into
    /// `Settings.customTags` (via `commitPendingTagPromotions()`).
    private let pendingTagsRow = NSStackView()

    /// Author-marked novel tags that should be promoted into the
    /// persistent custom-tags vocabulary on the next card save. UI
    /// state — not persisted, cleared on commit. A tag drops from
    /// this set if it stops being novel (e.g., the author removes it
    /// from the field, or it was promoted on a save we already saw).
    private var tagsToPromoteOnSave: Set<String> = []

    init(draft: CharacterDraft, onDirty: @escaping () -> Void, aiRegistry: CardCreatorAIRegistry) {
        self.draft = draft
        self.onDirty = onDirty
        self.aiRegistry = aiRegistry
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
            DebugLog.shared.write("avatar: identity-tab received \(data?.count ?? 0)B → draft")
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

        // Sex chooser (Phase 9 §5.4 — identity attribute that plumbs
        // into AI-assist generation across the card; distinct from
        // pronouns).
        sexPopup.translatesAutoresizingMaskIntoConstraints = false
        sexPopup.bezelStyle = .rounded
        sexPopup.controlSize = .small
        sexPopup.removeAllItems()
        sexPopup.addItem(withTitle: Self.sexUnsetTitle)
        for opt in Self.sexStandardOptions { sexPopup.addItem(withTitle: opt) }
        sexPopup.addItem(withTitle: Self.sexOtherTitle)
        sexPopup.target = self
        sexPopup.action = #selector(sexPopupChanged)

        configureField(sexCustomField, placeholder: "futa, agender, …", width: 200)
        sexCustomField.delegate = self
        sexCustomField.isHidden = true

        let sexRowControls = NSStackView(views: [sexPopup, sexCustomField])
        sexRowControls.orientation = .horizontal
        sexRowControls.alignment = .firstBaseline
        sexRowControls.spacing = DesignTokens.Spacing.sm
        sexRowControls.translatesAutoresizingMaskIntoConstraints = false

        let sexRow = labeledRow("Sex",
                                control: sexRowControls,
                                hint: "Distinct from pronouns. Plumbed into AI-assist as universal context.")
        fieldStack.addArrangedSubview(sexRow)

        loadSexFromDraft()

        // Tags (token field). NSTokenField's wrap-to-multi-line mode
        // is unreliable in current AppKit — settings (cell.wraps +
        // isScrollable=false + preferredMaxLayoutWidth) don't always
        // take, leaving the field in single-line clipping mode.
        // Embracing single-line: wrap in an NSScrollView with a
        // visible horizontal scroller so a busy tag list shows a
        // scroll thumb the user can drag, instead of silently
        // clipping at the right edge.
        //
        // Documentview setup uses translatesAutoresizingMaskIntoConstraints=true
        // (frame-based sizing) so the field's intrinsic content size
        // drives its width inside the clip view — without this, the
        // earlier wrap attempt left the field at zero size and ate
        // all click events.
        tagsField.translatesAutoresizingMaskIntoConstraints = true
        tagsField.tokenStyle = .rounded
        tagsField.controlSize = .small
        tagsField.placeholderString = "Add tags…"
        tagsField.objectValue = draft.character.tags
        tagsField.delegate = self
        tagsField.font = DesignTokens.Typography.body
        tagsField.isBordered = false
        tagsField.drawsBackground = false
        tagsField.frame = NSRect(x: 0, y: 0, width: 360, height: 22)
        tagsField.autoresizingMask = [.height]

        let tagsScroll = NSScrollView()
        tagsScroll.translatesAutoresizingMaskIntoConstraints = false
        tagsScroll.hasHorizontalScroller = true
        tagsScroll.hasVerticalScroller = false
        tagsScroll.autohidesScrollers = false
        tagsScroll.borderType = .bezelBorder
        tagsScroll.drawsBackground = true
        tagsScroll.documentView = tagsField
        tagsScroll.widthAnchor.constraint(equalToConstant: 360).isActive = true
        // Field height + horizontal scroller height (~16pt on macOS 26).
        tagsScroll.heightAnchor.constraint(equalToConstant: 44).isActive = true

        let tagsRow = labeledRow("Tags",
                                 control: tagsScroll,
                                 hint: "Comma-separated. Used by the library for filtering. Common tags autocomplete.",
                                 width: 360)
        fieldStack.addArrangedSubview(tagsRow)

        // Pending-novel-tags row (Phase 9 §5.3a follow-up). One pill per
        // novel tag with an ✗/✓ toggle so the author opts-in to
        // promoting the tag into the persistent custom-tags vocabulary.
        // Defaults to ✗ — typos no longer pollute autocomplete forever.
        pendingTagsRow.orientation = .horizontal
        pendingTagsRow.alignment = .centerY
        pendingTagsRow.spacing = DesignTokens.Spacing.xs
        pendingTagsRow.translatesAutoresizingMaskIntoConstraints = false
        pendingTagsRow.isHidden = true
        fieldStack.addArrangedSubview(pendingTagsRow)
        refreshPendingTagsRow()

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
            hintView.textColor = DesignTokens.Foreground.secondary
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
        pill.drawsBackground = false

        // Inset the text via a wrapping container so the pill has padding.
        // Use AppearanceAwareLayerView so the chip background tracks
        // light/dark/accent flips.
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
}

// MARK: - NSTextFieldDelegate / NSTokenFieldDelegate

extension IdentityTabViewController: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        switch field {
        case nameField:
            draft.character.name = field.stringValue
            aiRegistry.markDownstreamStale(of: .name)
        case nicknameField: draft.character.nickname = nonEmpty(field.stringValue)
        case creatorField: draft.character.creator = nonEmpty(field.stringValue)
        case versionField: draft.character.characterVersion = nonEmpty(field.stringValue)
        case sexCustomField:
            // "Other" mode — every keystroke writes through to
            // extensions and propagates stale.
            commitSex()
            return  // commitSex already markDirty + onDirty
        case tagsField:
            // NSTokenField fires controlTextDidChange both on raw
            // character entry (still-being-typed input) AND on token
            // commit. objectValue only reflects committed tokens, so
            // pulling here captures comma/enter token commits promptly
            // without polluting state with mid-word characters. The
            // textShouldEndEditing path remains as a backstop for
            // focus-leaves-field commits.
            let tokens = (tagsField.objectValue as? [String]) ?? []
            draft.character.tags = tokens
            aiRegistry.markTagsChanged()
            refreshPendingTagsRow()
        default: return
        }
        draft.markDirty()
        onDirty()
    }

    private func nonEmpty(_ s: String) -> String? {
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Sex chooser (Phase 9 §5.4)

    /// Read the persisted sex value off the draft and reflect it in
    /// the popup + custom-field state. Empty → "—". Standard option
    /// → that option. Otherwise → "Other" + custom-field text.
    private func loadSexFromDraft() {
        let current = (CardDetails.extractFrom(draft.character)?.sex ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if current.isEmpty {
            sexPopup.selectItem(withTitle: Self.sexUnsetTitle)
            sexCustomField.stringValue = ""
            sexCustomField.isHidden = true
        } else if Self.sexStandardOptions.contains(current) {
            sexPopup.selectItem(withTitle: current)
            sexCustomField.stringValue = ""
            sexCustomField.isHidden = true
        } else {
            sexPopup.selectItem(withTitle: Self.sexOtherTitle)
            sexCustomField.stringValue = current
            sexCustomField.isHidden = false
        }
    }

    /// Read the current chooser state into the canonical string value
    /// (empty if "—"; the option title for standard; the custom
    /// field's value for "Other").
    private func currentSexValue() -> String {
        guard let title = sexPopup.titleOfSelectedItem else { return "" }
        switch title {
        case Self.sexUnsetTitle: return ""
        case Self.sexOtherTitle:
            return sexCustomField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        default: return title
        }
    }

    @objc private func sexPopupChanged() {
        // Toggle the custom-field visibility based on the new choice.
        let isOther = sexPopup.titleOfSelectedItem == Self.sexOtherTitle
        sexCustomField.isHidden = !isOther
        if isOther {
            // Focus the custom field for the typing flow.
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.view.window?.makeFirstResponder(self.sexCustomField)
            }
        }
        commitSex()
    }

    /// Read-modify-write to extensions["rpclient/details"].sex so the
    /// rest of CardDetails (age/pronouns/species/orientation/
    /// appearance/mood — owned by the Details tab) stays intact.
    private func commitSex() {
        var d = CardDetails.extractFrom(draft.character) ?? CardDetails()
        d.sex = currentSexValue()
        d.applyTo(&draft.character)
        draft.markDirty()
        onDirty()
        aiRegistry.markDownstreamStale(of: .detailsSex)
    }
}

extension IdentityTabViewController: NSTokenFieldDelegate {
    func tokenField(_ tokenField: NSTokenField, completionsForSubstring substring: String, indexOfToken tokenIndex: Int, indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?) -> [Any]? {
        let needle = substring.lowercased()
        guard !needle.isEmpty else { return [] }
        let custom = AppState.shared.settings.customTags
        return TagVocabulary.shared.matches(prefix: needle, customTags: custom).map { $0 as Any }
    }

    func control(_ control: NSControl, textShouldEndEditing fieldEditor: NSText) -> Bool {
        if let tokenField = control as? NSTokenField, tokenField === tagsField {
            let tokens = (tokenField.objectValue as? [String]) ?? []
            draft.character.tags = tokens
            // Phase 9 §3.8 was auto-promote-on-commit; superseded by the
            // per-tag opt-in toggle below the field. Author clicks ✓ on
            // a novel tag to promote it to Settings.customTags. Typos no
            // longer pollute autocomplete forever.
            draft.markDirty()
            onDirty()
            aiRegistry.markTagsChanged()
            refreshPendingTagsRow()
        }
        return true
    }

    // MARK: - Pending-novel-tags row

    /// Recompute the row of pending-novel-tag pills. A tag is "novel"
    /// if it isn't in the bundled vocabulary AND isn't already in
    /// `Settings.customTags`. Pills stay visible while the tag is
    /// novel; the ✗/✓ state is UI-only until the next save.
    private func refreshPendingTagsRow() {
        pendingTagsRow.arrangedSubviews.forEach {
            pendingTagsRow.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        let cardTags = draft.character.tags
        let knownBundled = Set(TagVocabulary.shared.all.map { $0.lowercased() })
        let knownCustom = Set(AppState.shared.settings.customTags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var novel: Set<String> = []
        var seen = Set<String>()
        for raw in cardTags {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            guard seen.insert(normalized).inserted else { continue }
            if knownBundled.contains(normalized) { continue }
            if knownCustom.contains(normalized) { continue }
            novel.insert(normalized)
            pendingTagsRow.addArrangedSubview(makePendingTagPill(tag: normalized))
        }
        // A tag that was marked-to-promote but is no longer in the
        // field should drop from the pending set.
        tagsToPromoteOnSave.formIntersection(novel)
        pendingTagsRow.isHidden = pendingTagsRow.arrangedSubviews.isEmpty
    }

    /// Build one pill: small caption-style label + an SF Symbol
    /// toggle. ✗ = default ("don't save to vocab"); ✓ = "save when
    /// the card next saves". Toggle is reversible; nothing is
    /// persisted until the author clicks Save.
    private func makePendingTagPill(tag: String) -> NSView {
        let willPromote = tagsToPromoteOnSave.contains(tag)
        let label = NSTextField(labelWithString: tag)
        label.font = DesignTokens.Typography.caption1
        label.textColor = DesignTokens.Foreground.secondary
        label.translatesAutoresizingMaskIntoConstraints = false

        let toggle = NSButton()
        toggle.bezelStyle = .recessed
        toggle.controlSize = .mini
        toggle.imagePosition = .imageOnly
        toggle.image = NSImage(
            systemSymbolName: willPromote ? "checkmark" : "xmark",
            accessibilityDescription: willPromote
                ? "Will save '\(tag)' on next save"
                : "Don't save '\(tag)' to vocabulary"
        )
        toggle.contentTintColor = willPromote
            ? DesignTokens.Foreground.success
            : DesignTokens.Foreground.tertiary
        toggle.toolTip = willPromote
            ? "On save, '\(tag)' will be added to your tag vocabulary. Click to undo."
            : "Click to add '\(tag)' to your tag vocabulary on next save."
        toggle.target = self
        toggle.action = #selector(pendingTagToggleClicked(_:))
        toggle.identifier = NSUserInterfaceItemIdentifier(rawValue: tag)
        toggle.translatesAutoresizingMaskIntoConstraints = false

        let pill = NSStackView(views: [label, toggle])
        pill.orientation = .horizontal
        pill.alignment = .centerY
        pill.spacing = DesignTokens.Spacing.xs
        pill.translatesAutoresizingMaskIntoConstraints = false
        return pill
    }

    @objc private func pendingTagToggleClicked(_ sender: NSButton) {
        guard let tag = sender.identifier?.rawValue else { return }
        if tagsToPromoteOnSave.contains(tag) {
            tagsToPromoteOnSave.remove(tag)
            DebugLog.shared.write("tags: pending-promote '\(tag)' deselected")
        } else {
            tagsToPromoteOnSave.insert(tag)
            DebugLog.shared.write("tags: pending-promote '\(tag)' marked")
        }
        // In-place visual update so the pill stays put — no flash, no
        // pill removal. Re-rendering the whole row would also work but
        // would lose focus / animation continuity.
        let willPromote = tagsToPromoteOnSave.contains(tag)
        sender.image = NSImage(
            systemSymbolName: willPromote ? "checkmark" : "xmark",
            accessibilityDescription: willPromote
                ? "Will save '\(tag)' on next save"
                : "Don't save '\(tag)' to vocabulary"
        )
        sender.contentTintColor = willPromote
            ? DesignTokens.Foreground.success
            : DesignTokens.Foreground.tertiary
        sender.toolTip = willPromote
            ? "On save, '\(tag)' will be added to your tag vocabulary. Click to undo."
            : "Click to add '\(tag)' to your tag vocabulary on next save."
    }

    /// Called by `CardCreatorViewController.saveClicked()` just before
    /// `draft.flush(...)`. Promotes every ✓-marked novel tag into
    /// `Settings.customTags`; clears the pending set. Does nothing if
    /// no tags are pending.
    func commitPendingTagPromotions() {
        guard !tagsToPromoteOnSave.isEmpty else { return }
        var settings = AppState.shared.settings
        let known = Set(settings.customTags.map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        })
        var added: [String] = []
        for tag in tagsToPromoteOnSave.sorted() {
            let normalized = tag.lowercased()
            if known.contains(normalized) { continue }
            settings.customTags.append(normalized)
            added.append(normalized)
        }
        if !added.isEmpty {
            AppState.shared.saveSettings(settings)
            let joined = added.joined(separator: ", ")
            DebugLog.shared.write("tags: promoted \(added.count) to custom vocabulary on save: \(joined)")
        }
        tagsToPromoteOnSave.removeAll()
        // Pills for now-known tags will drop on the next refresh —
        // typically the next focus/typing event. Refresh proactively
        // so the UI is in sync immediately after save.
        refreshPendingTagsRow()
    }
}
