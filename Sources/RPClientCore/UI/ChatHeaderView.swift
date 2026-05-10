import AppKit

/// V2_UI_OVERHAUL §4.2 / §4.f — chat header (one row, ≤3 visible
/// controls). Replaces the empty 8pt strip placeholder from §4.g.1.
///
/// Layout:
///   [ Title (editable on click)             ] [ ⓘ inspector ] [ ⋯ overflow ]
///   [ with <persona> (hidden when no persona)]
///
/// Height fixed at 36pt per the spec table. Background is transparent
/// — the header sits on the same Liquid Glass plane as the AppKit
/// toolbar; we don't add a NSVisualEffectView.
final class ChatHeaderView: NSView, NSTextFieldDelegate {
    private let titleField = NSTextField()
    private let subtitleLabel = NSTextField(labelWithString: "")
    private let inspectorButton = NSButton()
    private let overflowButton = NSButton()
    private var subtitleHeightZero: NSLayoutConstraint?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        // V2_UI_OVERHAUL §4.2 — Title `headline` (13pt semibold).
        // Editable in place: borderless / transparent until focused,
        // commit on Enter or focus loss.
        titleField.font = NSFont.systemFont(ofSize: 13, weight: .semibold)
        titleField.isBordered = false
        titleField.drawsBackground = false
        titleField.isEditable = true
        titleField.isSelectable = true
        titleField.usesSingleLineMode = true
        titleField.lineBreakMode = .byTruncatingTail
        titleField.cell?.sendsActionOnEndEditing = true
        titleField.delegate = self
        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.target = self
        titleField.action = #selector(titleCommitted)
        titleField.toolTip = "Click to rename this chat"
        addSubview(titleField)

        // Subhead `caption1` (10pt, secondaryLabelColor).
        subtitleLabel.font = NSFont.systemFont(ofSize: 10)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.translatesAutoresizingMaskIntoConstraints = false
        subtitleLabel.lineBreakMode = .byTruncatingTail
        addSubview(subtitleLabel)

        configureToolbarButton(
            inspectorButton,
            symbol: "info.circle",
            tooltip: "Toggle inspector",
            action: #selector(inspectorTapped)
        )
        configureToolbarButton(
            overflowButton,
            symbol: "ellipsis.circle",
            tooltip: "Chat options",
            action: #selector(overflowTapped)
        )
        addSubview(inspectorButton)
        addSubview(overflowButton)

        // Pin both rows leading; bake in a height-zero fallback for
        // the subtitle so it can collapse cleanly when there's no
        // persona attached.
        let subZero = subtitleLabel.heightAnchor.constraint(equalToConstant: 0)
        subZero.priority = .defaultHigh
        subtitleHeightZero = subZero

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 36),

            titleField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            titleField.topAnchor.constraint(equalTo: topAnchor, constant: 4),
            titleField.trailingAnchor.constraint(lessThanOrEqualTo: inspectorButton.leadingAnchor, constant: -8),

            subtitleLabel.leadingAnchor.constraint(equalTo: titleField.leadingAnchor),
            subtitleLabel.topAnchor.constraint(equalTo: titleField.bottomAnchor, constant: 1),
            subtitleLabel.trailingAnchor.constraint(lessThanOrEqualTo: inspectorButton.leadingAnchor, constant: -8),

            overflowButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12),
            overflowButton.centerYAnchor.constraint(equalTo: centerYAnchor),

            inspectorButton.trailingAnchor.constraint(equalTo: overflowButton.leadingAnchor, constant: -4),
            inspectorButton.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.personasChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    private func configureToolbarButton(
        _ button: NSButton,
        symbol: String,
        tooltip: String,
        action: Selector
    ) {
        button.bezelStyle = .toolbar
        button.controlSize = .small
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: tooltip
        )
        button.toolTip = tooltip
        button.target = self
        button.action = action
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    // MARK: - State

    @objc private func refresh() {
        // Don't clobber the title field while the user is mid-edit.
        // NSTextField's currentEditor is non-nil only while focused;
        // checking responder identity protects against a stale editor.
        let editor = titleField.currentEditor()
        let isEditingTitle = editor != nil && window?.firstResponder === editor
        if !isEditingTitle {
            titleField.stringValue = AppState.shared.currentChat?.title ?? ""
        }

        let subtitle = ChatHeaderSubtitle.resolve(
            personaId: AppState.shared.currentChat?.personaId,
            personas: AppState.shared.personas
        )
        if let subtitle, !subtitle.isEmpty {
            subtitleLabel.stringValue = subtitle
            subtitleLabel.isHidden = false
            subtitleHeightZero?.isActive = false
        } else {
            subtitleLabel.stringValue = ""
            subtitleLabel.isHidden = true
            subtitleHeightZero?.isActive = true
        }
    }

    // MARK: - Title editing

    @objc private func titleCommitted() {
        let new = titleField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let current = AppState.shared.currentChat?.title ?? ""
        guard !new.isEmpty else {
            // Empty title is meaningless; revert to the live value.
            titleField.stringValue = current
            return
        }
        guard new != current else { return }
        DebugLog.shared.write("[chat-pane] header title rename '\(current)' → '\(new)'")
        AppState.shared.updateCurrent { c in c.title = new }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            // Escape: drop edits, revert.
            titleField.stringValue = AppState.shared.currentChat?.title ?? ""
            window?.makeFirstResponder(nil)
            return true
        }
        return false
    }

    // MARK: - Buttons

    @objc private func inspectorTapped() {
        // Routes through the responder chain to AppDelegate.toggleInspector.
        NSApp.sendAction(Selector(("toggleInspector")), to: nil, from: self)
    }

    @objc private func overflowTapped() {
        let menu = NSMenu()
        let rename = NSMenuItem(
            title: "Rename",
            action: #selector(beginRename),
            keyEquivalent: ""
        )
        rename.target = self
        menu.addItem(rename)

        menu.addItem(NSMenuItem.separator())

        let delete = NSMenuItem(
            title: "Delete chat…",
            action: #selector(deleteChat),
            keyEquivalent: ""
        )
        delete.target = self
        menu.addItem(delete)

        let p = NSPoint(x: 0, y: overflowButton.bounds.height + 2)
        menu.popUp(positioning: nil, at: p, in: overflowButton)
    }

    @objc private func beginRename() {
        window?.makeFirstResponder(titleField)
        if let editor = titleField.currentEditor() as? NSTextView {
            editor.selectAll(nil)
        }
    }

    @objc private func deleteChat() {
        guard let chat = AppState.shared.currentChat else { return }
        let alert = NSAlert()
        alert.messageText = "Delete this chat?"
        alert.informativeText = chat.title
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppState.shared.deleteChat(id: chat.id)
        }
    }
}
