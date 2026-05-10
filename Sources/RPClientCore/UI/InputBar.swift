import AppKit

protocol InputBarDelegate: AnyObject {
    func inputBarSend(_ bar: InputBar, text: String)
}

final class InputBar: NSView, NSTextViewDelegate {
    weak var delegate: InputBarDelegate?

    private let pill = NSView()
    private let scrollView = NSScrollView()
    let textView = NSTextView()
    private let primaryButton = NSButton()
    /// V2_UI_OVERHAUL §4.9 / §4.g — row of metadata pills (Server,
    /// Voice, Attribution, etc.) above the input pill. ChatViewController
    /// fills this via `setMetadataPills(_:)`. As of §4.g.3 this is a
    /// custom view that switches between inline / wrap-2-rows /
    /// collapsed-to-overflow-button layouts based on available width
    /// (§4.8.6 thresholds). Empty by default; height collapses to 0
    /// so the rest of the layout falls back to its pre-§4.g position.
    let pillRow = FlowPillRow()
    /// Phase 8 §4.3 — speaker picker. Hidden on solo / free-form chats
    /// (cast.count <= 1) so it doesn't clutter the input pill. On
    /// multi-cast chats, shows a compact symbol-button that opens a menu
    /// of cast members + Auto-mode entries; selecting a member queues a
    /// one-shot pendingSpeakerId for the next send, selecting an Auto
    /// switches `chat.speakerSelection` and clears any pending pick.
    private let speakerButton = NSPopUpButton()
    private var speakerLeadingConstraint: NSLayoutConstraint?

    /// V2_UI_OVERHAUL §4.g — install the row of metadata pills above
    /// the input pill (Server, Voice, Attribution, etc.). Caller owns
    /// each view's lifecycle and bindings; InputBar just provides the
    /// layout slot. Replaces a previous arrangedSubview list (if any)
    /// so this can be called repeatedly during chat-pane rebuilds.
    func setMetadataPills(_ pills: [NSView]) {
        pillRow.setPills(pills)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        addSubview(pillRow)

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

        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        speakerButton.bezelStyle = .rounded
        speakerButton.isBordered = true
        speakerButton.pullsDown = true
        speakerButton.imagePosition = .imageLeading
        speakerButton.font = Theme.font(12)
        speakerButton.target = self
        speakerButton.action = #selector(speakerMenuPicked(_:))
        speakerButton.toolTip = "Pick next speaker"
        speakerButton.isHidden = true
        pill.addSubview(speakerButton)

        // The speakerButton's leading constraint to scrollView varies with
        // its visibility (collapsed when hidden) — held as ivars so
        // updateSpeakerPicker can swap them.
        let speakerToScroll = scrollView.leadingAnchor.constraint(
            equalTo: speakerButton.trailingAnchor, constant: 6
        )
        speakerLeadingConstraint = speakerToScroll
        let scrollNoSpeaker = scrollView.leadingAnchor.constraint(
            equalTo: pill.leadingAnchor, constant: 14
        )
        scrollNoSpeaker.priority = NSLayoutConstraint.Priority(rawValue: 250)
        speakerToScroll.priority = NSLayoutConstraint.Priority.required

        NSLayoutConstraint.activate([
            // V2_UI_OVERHAUL §4.g — pill row sits above the input pill.
            // When empty (no metadata pills installed) it collapses to
            // 0 intrinsic height, so the input pill stays right at the
            // pre-§4.g top position.
            pillRow.topAnchor.constraint(equalTo: topAnchor, constant: 8),
            pillRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pillRow.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -16),

            pill.topAnchor.constraint(equalTo: pillRow.bottomAnchor, constant: DesignTokens.Spacing.xs),
            pill.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            pill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
            pill.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: pill.topAnchor, constant: 8),
            scrollView.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            scrollNoSpeaker,
            scrollView.trailingAnchor.constraint(equalTo: primaryButton.leadingAnchor, constant: -8),
            scrollView.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),

            speakerButton.leadingAnchor.constraint(equalTo: pill.leadingAnchor, constant: 8),
            speakerButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -8),
            speakerButton.heightAnchor.constraint(equalToConstant: 26),

            primaryButton.trailingAnchor.constraint(equalTo: pill.trailingAnchor, constant: -6),
            primaryButton.bottomAnchor.constraint(equalTo: pill.bottomAnchor, constant: -6),
            primaryButton.widthAnchor.constraint(equalToConstant: 30),
            primaryButton.heightAnchor.constraint(equalToConstant: 30),

            heightAnchor.constraint(greaterThanOrEqualToConstant: 70),
            // Cap so the layout engine doesn't dump all the vertical
            // slack here when the chat content is short (e.g. empty
            // state). 260 = 220 (pre-§4.g cap) + ~38pt headroom for
            // the metadata pill row + its top/bottom gaps when
            // populated. textView auto-scrolls past the input pill's
            // own ceiling so a long message stays interactable.
            heightAnchor.constraint(lessThanOrEqualToConstant: 260)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(streamStateChanged),
            name: AppNotification.streamFinished, object: nil)
        nc.addObserver(self, selector: #selector(streamStateChanged),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleFontChanged),
            name: AppNotification.fontChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateSpeakerPicker),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(updateSpeakerPicker),
            name: AppNotification.chatUpdated, object: nil)
        updateButtons()
        updateSpeakerPicker()
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
        let text = textView.string
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        delegate?.inputBarSend(self, text: text)
        textView.string = ""
        updateButtons()
    }

    @objc private func streamStateChanged() {
        updateButtons()
    }

    /// V2_UI_OVERHAUL §4.g.2 — pure send button. The send→stop morph
    /// (ChatGPT anti-pattern flagged in §C.5) is gone; cancel lives on
    /// the §4.e.3 Stop pill below the composer. Button stays in send
    /// affordance always, disabled while busy or while the field is empty.
    func updateButtons() {
        primaryButton.image = NSImage(
            systemSymbolName: "arrow.up.circle.fill",
            accessibilityDescription: "Send"
        )
        primaryButton.toolTip = "Send"

        let s = AppState.shared
        let busy = s.isStreaming || s.isSummarizing || s.isExtracting
        let hasText = !textView.string
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let canSend = hasText && !busy

        primaryButton.isEnabled = canSend
        primaryButton.contentTintColor = canSend
            ? .controlAccentColor
            : .tertiaryLabelColor
    }

    // MARK: - NSTextViewDelegate

    func textDidChange(_ notification: Notification) {
        updateButtons()
    }

    // MARK: - Speaker picker (Phase 8 §4.3)

    @objc private func updateSpeakerPicker() {
        guard let chat = AppState.shared.currentChat else {
            speakerButton.isHidden = true
            speakerLeadingConstraint?.isActive = false
            return
        }
        let isMultiCast = chat.cast.count > 1
        speakerButton.isHidden = !isMultiCast
        speakerLeadingConstraint?.isActive = isMultiCast
        if !isMultiCast { return }

        // Director mode picks asynchronously per-send; the sync picker
        // returns nil so we can't show a deterministic "Next: <name>"
        // ahead of time. Show the mode label instead so the user knows
        // the LLM router is active. Other modes show the actual next
        // pick (or the queued one-shot via pendingSpeakerId).
        let headerTitle: String
        if chat.speakerSelection == .director && chat.pendingSpeakerId == nil {
            headerTitle = "Next: director will pick"
        } else {
            let nextPick = SpeakerPicker.next(in: chat) ?? chat.cast.first
            let nextName = nextPick.flatMap { AppState.shared.character(id: $0)?.name }
                ?? "?"
            headerTitle = "Next: \(nextName)"
        }

        let menu = NSMenu()
        // First item is the menu's "title" for pulldown popups — set it
        // to the resolved header so the button face is informative even
        // when collapsed. Disabled so a pick on the title is a no-op.
        let header = NSMenuItem(title: headerTitle, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(NSMenuItem.separator())

        // Auto-mode entries. Picking switches `chat.speakerSelection`
        // and clears any pending one-shot pick.
        let modes: [(SpeakerSelectionMode, String)] = [
            (.roundRobin, "Auto — round-robin"),
            (.pooled,     "Auto — pooled"),
            (.manual,     "Auto — manual"),
            (.director,   "Auto — director (LLM, experimental)"),
        ]
        for (mode, title) in modes {
            let item = NSMenuItem(title: title, action: #selector(speakerMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = mode.rawValue
            item.state = (chat.speakerSelection == mode) ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        // Per-cast members. Picking sets a one-shot `pendingSpeakerId`.
        for cid in chat.cast {
            let name = AppState.shared.character(id: cid)?.name ?? "Unknown"
            let label = (chat.pendingSpeakerId == cid) ? "✓ \(name) (one-shot)" : name
            let item = NSMenuItem(title: label, action: #selector(speakerMenuPicked(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = cid.uuidString
            menu.addItem(item)
        }
        speakerButton.menu = menu
        // Pull-down popups treat item 0 as the title — ours is a disabled
        // "Next: …" header which is fine to surface.
        speakerButton.selectItem(at: 0)
    }

    @objc private func speakerMenuPicked(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String else { return }
        if let mode = SpeakerSelectionMode(rawValue: raw) {
            AppState.shared.updateCurrent { c in
                c.speakerSelection = mode
                c.pendingSpeakerId = nil
            }
        } else if let cid = UUID(uuidString: raw) {
            AppState.shared.updateCurrent { c in
                c.pendingSpeakerId = cid
            }
        }
        // updateSpeakerPicker fires via chatUpdated; reset the popup
        // selection so the menu header re-renders.
        speakerButton.selectItem(at: 0)
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
