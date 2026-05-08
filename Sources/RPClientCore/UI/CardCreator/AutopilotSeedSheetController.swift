import AppKit

/// Phase 9 §5.4.c slice 5 — small modal sheet that captures the seed
/// input for Mode 3 ("Generate full card"). Per V2_PHASE9_CARD_CREATOR
/// §4.8 the seed is one of:
///   - a one-line description ("an aging archivist who keeps to
///     themselves in a port town")
///   - a name + a few tags
///   - just tags (cold-start; the model invents everything)
///
/// The author types into a single multi-line field and clicks
/// Generate. The text is passed through to the orchestrator as the
/// `hint` (lands in every pass's prompt as an AUTHOR DIRECTION block).
/// Tags + name are read from the draft, not duplicated here.

@MainActor
final class AutopilotSeedSheetController: NSWindowController {

    var onGenerate: ((String) -> Void)?
    var onCancel: (() -> Void)?

    private let textView = NSTextView()
    private let generateButton = NSButton(title: "Generate full card", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    init() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 260),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Generate full card"
        super.init(window: panel)
        buildUI()
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

        let hint = NSTextField(wrappingLabelWithString: "A one-line concept anchors every pass — \"an aging archivist who keeps to themselves in a port town.\" Leave blank to let the model invent everything from your tags. Name and tags from the Identity tab are always included.")
        hint.font = DesignTokens.Typography.subheadline
        hint.textColor = DesignTokens.Foreground.secondary
        hint.translatesAutoresizingMaskIntoConstraints = false

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
            scroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 100),

            footer.topAnchor.constraint(equalTo: scroll.bottomAnchor, constant: DesignTokens.Spacing.md),
            footer.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),
            footer.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DesignTokens.Spacing.md),
        ])
    }

    @objc private func generateClicked() {
        let hint = textView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        DebugLog.shared.write("cardgen: mode3 seed submitted (\(hint.count)c)")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .OK) }
        onGenerate?(hint)
    }

    @objc private func cancelClicked() {
        DebugLog.shared.write("cardgen: mode3 seed cancelled")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .cancel) }
        onCancel?()
    }
}
