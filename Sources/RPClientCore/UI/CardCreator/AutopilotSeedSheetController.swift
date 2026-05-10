import AppKit

/// Phase 9 §5.4.c slice 5 — small modal sheet that captures the seed
/// input for Mode 3 ("Generate full card"). Per V2_PHASE9_CARD_CREATOR
/// §4.8 the seed is one of:
///   - a one-line description ("an aging archivist who keeps to
///     themselves in a port town")
///   - a name + a few tags
///   - just tags (cold-start; the model invents everything)
///
/// The author types into the description field and optionally edits
/// the tags before clicking Generate. Both flow through to the
/// orchestrator: the description as `hint` (lands in every pass's
/// prompt as an AUTHOR DIRECTION block), the tags as the snapshot's
/// `tags` array. Tags entered here are NOT promoted into the global
/// custom-tags vocabulary — they stay scoped to this card.

@MainActor
final class AutopilotSeedSheetController: NSWindowController {

    /// Called when the author confirms. `hint` is the trimmed prose
    /// from the description field; `tags` is the comma-separated list
    /// from the token field. Either may be empty — the orchestrator
    /// handles cold-start.
    var onGenerate: ((_ hint: String, _ tags: [String]) -> Void)?
    var onCancel: (() -> Void)?

    private let textView = NSTextView()
    private let tagsField = NSTokenField()
    private let generateButton = NSButton(title: "Generate full card", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    /// Seed values from the current draft so the author can edit
    /// rather than retype. The caller passes the draft's tags so the
    /// sheet shows what's already on the card; if the author commits,
    /// the edited list is fed back into the draft.
    init(initialTags: [String] = []) {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Generate full card"
        super.init(window: panel)
        buildUI()
        tagsField.objectValue = initialTags
    }

    required init?(coder: NSCoder) { fatalError() }

    func beginSheet(over parent: NSWindow) {
        guard let w = window else { return }
        DebugLog.shared.write("cardgen: mode3 seed sheet opened")
        parent.beginSheet(w) { _ in }
        w.makeFirstResponder(textView)
    }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        let title = NSTextField(labelWithString: "Describe the character (optional)")
        title.font = DesignTokens.Typography.headline
        title.textColor = DesignTokens.Foreground.primary
        title.translatesAutoresizingMaskIntoConstraints = false

        let hint = NSTextField(wrappingLabelWithString: "A one-line concept anchors every pass — \"an aging archivist who keeps to themselves in a port town.\" Leave blank to let the model invent everything from your tags.")
        hint.font = DesignTokens.Typography.subheadline
        hint.textColor = DesignTokens.Foreground.secondary
        hint.translatesAutoresizingMaskIntoConstraints = false

        let tagsLabel = NSTextField(labelWithString: "Tags")
        tagsLabel.font = DesignTokens.Typography.headline
        tagsLabel.textColor = DesignTokens.Foreground.primary
        tagsLabel.translatesAutoresizingMaskIntoConstraints = false

        let tagsHint = NSTextField(wrappingLabelWithString: "Steers the genre and archetype (e.g. fantasy, monstergirl). Autocompletes from the global tag list; you can type new tags. Anything entered here flows into the new card's tags on commit, but isn't added to the global autocomplete list.")
        tagsHint.font = DesignTokens.Typography.caption1
        tagsHint.textColor = DesignTokens.Foreground.tertiary
        tagsHint.translatesAutoresizingMaskIntoConstraints = false

        // NSTokenField mirrors the Identity tab's tags widget — comma-
        // separated entry, autocomplete via the delegate below. Frame
        // size is required for NSTokenField to render initial tokens
        // without flicker.
        tagsField.tokenStyle = .rounded
        tagsField.controlSize = .regular
        tagsField.placeholderString = "Add tags…"
        tagsField.delegate = self
        tagsField.font = DesignTokens.Typography.body
        tagsField.translatesAutoresizingMaskIntoConstraints = false

        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.backgroundColor = DesignTokens.Background.textInput
        textView.drawsBackground = true
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.textContainerInset = NSSize(
            width: DesignTokens.Spacing.sm, height: DesignTokens.Spacing.sm
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.borderType = .lineBorder
        scroll.hasVerticalScroller = true
        scroll.translatesAutoresizingMaskIntoConstraints = false

        for b in [generateButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        generateButton.target = self
        generateButton.action = #selector(generateClicked)
        generateButton.keyEquivalent = "\r"
        generateButton.keyEquivalentModifierMask = [.command]
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1B}"

        let footer = NSStackView(views: [cancelButton, NSView(), generateButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = DesignTokens.Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(title)
        content.addSubview(hint)
        content.addSubview(scroll)
        content.addSubview(tagsLabel)
        content.addSubview(tagsField)
        content.addSubview(tagsHint)
        content.addSubview(footer)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: content.topAnchor, constant: DesignTokens.Spacing.md),
            title.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            title.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            hint.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DesignTokens.Spacing.xs),
            hint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            hint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            scroll.topAnchor.constraint(equalTo: hint.bottomAnchor, constant: DesignTokens.Spacing.sm),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            tagsLabel.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: DesignTokens.Spacing.md),
            tagsLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),

            tagsField.topAnchor.constraint(equalTo: tagsLabel.bottomAnchor, constant: DesignTokens.Spacing.xs),
            tagsField.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            tagsField.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            tagsHint.topAnchor.constraint(equalTo: tagsField.bottomAnchor, constant: DesignTokens.Spacing.xs),
            tagsHint.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            tagsHint.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            footer.topAnchor.constraint(equalTo: tagsHint.bottomAnchor, constant: DesignTokens.Spacing.md),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DesignTokens.Spacing.md),
        ])
    }

    @objc private func generateClicked() {
        let hint = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let tags = (tagsField.objectValue as? [String])?
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty } ?? []
        DebugLog.shared.write("cardgen: mode3 seed submitted (\(hint.count)c, \(tags.count) tags=\(tags.joined(separator: ",")))")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .OK) }
        onGenerate?(hint, tags)
    }

    @objc private func cancelClicked() {
        DebugLog.shared.write("cardgen: mode3 seed cancelled")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .cancel) }
        onCancel?()
    }
}

extension AutopilotSeedSheetController: NSTokenFieldDelegate {
    /// Autocomplete from the bundled tag vocabulary + the user's
    /// custom tags list. Identical to the Identity tab's tag field
    /// behavior — but tokens entered here are NOT promoted into
    /// `Settings.customTags` (per the spec for the seed sheet: this
    /// is per-card seed input, not vocabulary curation).
    func tokenField(
        _ tokenField: NSTokenField,
        completionsForSubstring substring: String,
        indexOfToken tokenIndex: Int,
        indexOfSelectedItem selectedIndex: UnsafeMutablePointer<Int>?
    ) -> [Any]? {
        guard !substring.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        let custom = AppState.shared.settings.customTags
        // Same prefix-as-novel-tag fix as the Identity tab: typing
        // "fem" with "female" in the vocab returns ["fem", "female"]
        // so a plain comma commits "fem".
        return TagVocabulary.shared
            .autocompleteCandidates(for: substring, customTags: custom)
            .map { $0 as Any }
    }
}
