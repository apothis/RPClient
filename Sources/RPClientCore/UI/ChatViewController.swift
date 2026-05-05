import AppKit

final class ChatViewController: NSViewController, InputBarDelegate, TurnViewDelegate, EmptyStateViewDelegate, NSMenuItemValidation {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let inputBar = InputBar()
    private let statusBar = StatusBar()
    private let scrollLatestButton = NSButton()
    private let emptyStateView = EmptyStateView()
    /// Phase 4 §5.4 — per-chat server pin. nil/(use default) = chat
    /// generation goes to settings.defaultServerId; otherwise pinned to the
    /// chosen profile.
    private let chatHeader = NSView()
    private let serverPicker = NSPopUpButton()
    private var turnViews: [TurnView] = []
    private var dividerView: ContextDivider?
    private var dividerWidthConstraint: NSLayoutConstraint?
    /// True when the user has scrolled away from the bottom; suppresses
    /// auto-scroll on streamed tokens so we don't fight them.
    private var userScrolledUp: Bool = false
    private let scrollFollowThreshold: CGFloat = 80

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        stackView.orientation = .vertical
        stackView.alignment = .leading
        stackView.spacing = 28
        stackView.edgeInsets = NSEdgeInsets(top: 24, left: 0, bottom: 24, right: 0)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        let clip = FlippedClipView()
        clip.drawsBackground = false
        clip.postsBoundsChangedNotifications = true
        scrollView.contentView = clip
        scrollView.documentView = stackView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        // Chat header bar — server picker (Phase 4 §5.4). Future home for
        // template + sampler pickers if/when we surface those per-chat too.
        chatHeader.translatesAutoresizingMaskIntoConstraints = false
        chatHeader.wantsLayer = true
        let serverLabel = NSTextField(labelWithString: "Server:")
        serverLabel.font = Theme.font(11)
        serverLabel.textColor = .secondaryLabelColor
        serverLabel.translatesAutoresizingMaskIntoConstraints = false
        serverPicker.target = self
        serverPicker.action = #selector(serverPickerChanged(_:))
        serverPicker.bezelStyle = .rounded
        serverPicker.translatesAutoresizingMaskIntoConstraints = false
        chatHeader.addSubview(serverLabel)
        chatHeader.addSubview(serverPicker)
        v.addSubview(chatHeader)
        NSLayoutConstraint.activate([
            chatHeader.heightAnchor.constraint(equalToConstant: 28),
            serverLabel.leadingAnchor.constraint(equalTo: chatHeader.leadingAnchor, constant: 12),
            serverLabel.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            serverPicker.leadingAnchor.constraint(equalTo: serverLabel.trailingAnchor, constant: 6),
            serverPicker.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
        ])

        // Stack tracks the panel width with a small symmetric gutter; turns
        // expand fully as the panel widens.
        stackView.widthAnchor.constraint(
            equalTo: scrollView.contentView.widthAnchor, constant: -24
        ).isActive = true
        stackView.centerXAnchor.constraint(
            equalTo: scrollView.contentView.centerXAnchor
        ).isActive = true

        inputBar.delegate = self
        inputBar.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(inputBar)

        statusBar.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(statusBar)

        configureScrollLatestButton()
        v.addSubview(scrollLatestButton)

        emptyStateView.delegate = self
        emptyStateView.translatesAutoresizingMaskIntoConstraints = false

        NSLayoutConstraint.activate([
            chatHeader.topAnchor.constraint(equalTo: v.topAnchor),
            chatHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            chatHeader.trailingAnchor.constraint(equalTo: v.trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: chatHeader.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: inputBar.topAnchor),

            inputBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            inputBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            inputBar.bottomAnchor.constraint(equalTo: statusBar.topAnchor),

            statusBar.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            scrollLatestButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            scrollLatestButton.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -12),
            scrollLatestButton.widthAnchor.constraint(equalToConstant: 30),
            scrollLatestButton.heightAnchor.constraint(equalToConstant: 30)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleStreamToken),
            name: AppNotification.streamTokenAppended, object: nil)
        nc.addObserver(self, selector: #selector(handleStreamFinished),
            name: AppNotification.streamFinished, object: nil)
        nc.addObserver(self, selector: #selector(handleThinkingStateChanged),
            name: AppNotification.thinkingStateChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleChatUpdated),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(updateTruncationVisuals),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(rebuild),
            name: AppNotification.fontChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleSettingsChanged),
            name: AppNotification.settingsChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleScroll),
            name: NSView.boundsDidChangeNotification, object: clip)

        rebuild()
    }

    private func configureScrollLatestButton() {
        scrollLatestButton.image = NSImage(
            systemSymbolName: "chevron.down",
            accessibilityDescription: "Scroll to latest"
        )
        scrollLatestButton.bezelStyle = .circular
        scrollLatestButton.isBordered = true
        scrollLatestButton.imagePosition = .imageOnly
        scrollLatestButton.imageScaling = .scaleProportionallyDown
        scrollLatestButton.target = self
        scrollLatestButton.action = #selector(scrollLatestTapped)
        scrollLatestButton.translatesAutoresizingMaskIntoConstraints = false
        scrollLatestButton.alphaValue = 0
        scrollLatestButton.isHidden = true
        scrollLatestButton.toolTip = "Scroll to latest"
    }

    private func installEmptyState() {
        guard emptyStateView.superview == nil else { return }
        view.addSubview(emptyStateView)
        NSLayoutConstraint.activate([
            emptyStateView.topAnchor.constraint(equalTo: scrollView.topAnchor),
            emptyStateView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
            emptyStateView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
            emptyStateView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor)
        ])
    }

    private func removeEmptyState() {
        if emptyStateView.superview != nil {
            emptyStateView.removeFromSuperview()
        }
    }

    @objc private func scrollLatestTapped() {
        userScrolledUp = false
        scrollToBottom(animated: true)
    }

    @objc private func handleScroll() {
        let docH = scrollView.documentView?.frame.height ?? 0
        let visibleBottom = scrollView.contentView.bounds.maxY
        let dist = max(0, docH - visibleBottom)
        userScrolledUp = dist > scrollFollowThreshold
        updateScrollLatestVisibility()
    }

    private func updateScrollLatestVisibility() {
        let shouldShow = userScrolledUp
        if shouldShow == !scrollLatestButton.isHidden { return }
        if shouldShow {
            scrollLatestButton.isHidden = false
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.15
                scrollLatestButton.animator().alphaValue = 1
            }
        } else {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                scrollLatestButton.animator().alphaValue = 0
            }, completionHandler: { [weak self] in
                guard let self = self, !self.userScrolledUp else { return }
                self.scrollLatestButton.isHidden = true
            })
        }
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func rebuild() {
        for v in turnViews { v.removeFromSuperview() }
        turnViews.removeAll()
        dividerView?.removeFromSuperview()
        dividerView = nil
        dividerWidthConstraint = nil
        rebuildServerPicker()
        guard let chat = AppState.shared.currentChat else {
            removeEmptyState()
            return
        }
        if chat.turns.isEmpty {
            installEmptyState()
        } else {
            removeEmptyState()
        }
        let lastAssistantIdx = chat.turns.lastIndex(where: { $0.role == .assistant })
        let character = chat.characterId.flatMap { AppState.shared.character(id: $0) }
        for (i, t) in chat.turns.enumerated() {
            let tv = TurnView(turn: t, character: character)
            tv.delegate = self
            tv.isLastAssistant = (i == lastAssistantIdx)
            tv.setVariantState(
                active: t.activeVariant,
                count: t.variants.count,
                activeIsStale: chat.isVariantStale(turnIndex: i, variantIndex: t.activeVariant)
            )
            tv.translatesAutoresizingMaskIntoConstraints = false
            stackView.addArrangedSubview(tv)
            tv.widthAnchor.constraint(
                equalTo: stackView.widthAnchor
            ).isActive = true
            turnViews.append(tv)
        }
        updateTruncationVisuals()
        inputBar.updateButtons()
        userScrolledUp = false
        scrollToBottom()
    }

    @objc private func updateTruncationVisuals() {
        guard let chat = AppState.shared.currentChat else { return }
        let summarized = max(0, min(chat.summarizedThrough, turnViews.count))
        let truncated = AppState.shared.lastTruncatedCount
        let totalDimmed = min(summarized + truncated, turnViews.count)

        for (i, tv) in turnViews.enumerated() {
            if i < summarized {
                tv.alphaValue = 0.55  // folded into summary, still in context as summary
            } else if i < totalDimmed {
                tv.alphaValue = 0.30  // truncated, not in context at all
            } else {
                tv.alphaValue = 1.0
            }
        }

        if totalDimmed > 0 && totalDimmed < turnViews.count {
            let d: ContextDivider
            if let existing = dividerView {
                d = existing
                stackView.removeArrangedSubview(d)
                d.removeFromSuperview()
            } else {
                d = ContextDivider()
                d.translatesAutoresizingMaskIntoConstraints = false
                dividerView = d
            }
            stackView.insertArrangedSubview(d, at: totalDimmed)
            // Activate the width constraint AFTER insertion so it shares an
            // ancestor with stackView. Reuse the same constraint across moves.
            if dividerWidthConstraint == nil {
                let c = d.widthAnchor.constraint(
                    equalTo: stackView.widthAnchor
                )
                c.isActive = true
                dividerWidthConstraint = c
            }
        } else {
            dividerView?.removeFromSuperview()
            dividerView = nil
            dividerWidthConstraint = nil
        }
    }

    @objc private func handleChatUpdated() {
        // If the turns count changed (e.g. user message + empty assistant added),
        // rebuild structurally. If only text changed, leave token stream handling alone.
        guard let chat = AppState.shared.currentChat else { return }
        if chat.turns.count != turnViews.count {
            rebuild()
            return
        }
        // Variant state can change without the turn count moving — regen now
        // adds a variant in place, paging changes the active index, etc.
        // Push the latest tuple to each view so the pager redraws (including
        // the ⚠ stale badge, since paging an earlier turn can change the
        // staleness of every later turn's active variant).
        for (i, t) in chat.turns.enumerated() where i < turnViews.count {
            let tv = turnViews[i]
            tv.setVariantState(
                active: t.activeVariant,
                count: t.variants.count,
                activeIsStale: chat.isVariantStale(turnIndex: i, variantIndex: t.activeVariant)
            )
            // Paging changes which variant's text is mirrored on `text`; the
            // bubble needs to reflect that immediately.
            if tv.currentText != t.text {
                tv.setText(t.text)
            }
        }
        // Update titles potentially in status bar handled elsewhere.
        statusBar.refresh()
    }

    @objc private func handleStreamToken() {
        guard let chat = AppState.shared.currentChat,
              let lastTurn = chat.turns.last,
              let lastView = turnViews.last,
              lastView.turnId == lastTurn.id else {
            return
        }
        lastView.setText(lastTurn.text)
        if lastTurn.role == .assistant && !lastView.isStreaming {
            lastView.isStreaming = true
        }
        if !userScrolledUp {
            scrollToBottom()
        }
    }

    @objc private func handleStreamFinished() {
        AppState.shared.persistCurrent()
        inputBar.updateButtons()
        for tv in turnViews where tv.isStreaming {
            tv.isStreaming = false
        }
        // Stream finish unconditionally clears any lingering Thinking…
        // placeholder, even if the close tag never arrived.
        for tv in turnViews where tv.isThinking {
            tv.isThinking = false
        }
        if !userScrolledUp {
            scrollToBottom(animated: true)
        }
    }

    @objc private func handleThinkingStateChanged() {
        let thinking = AppState.shared.isThinking
        // Only the trailing assistant turn — the one currently streaming —
        // ever shows the placeholder. Earlier turns are settled history.
        guard let lastView = turnViews.last,
              lastView.turnId == AppState.shared.currentChat?.turns.last?.id else {
            return
        }
        lastView.isThinking = thinking
        // The streaming glyph pulse is normally engaged on the first token
        // append, but during a <think> block no displayable text reaches
        // setText(). Engage it here so the user sees a live signal next to
        // the "Thinking…" placeholder, matching the rest of the stream.
        if thinking, !lastView.isStreaming {
            lastView.isStreaming = true
        }
    }

    private func scrollToBottom(animated: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            // Force pending height-constraint changes (from recent setText/recomputeHeight)
            // through layout before reading the document height.
            self.view.layoutSubtreeIfNeeded()
            guard let doc = self.scrollView.documentView else { return }
            let bottom = NSPoint(
                x: 0,
                y: max(0, doc.frame.height - self.scrollView.contentView.bounds.height)
            )
            if animated {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.28
                    ctx.allowsImplicitAnimation = true
                    self.scrollView.contentView.animator().setBoundsOrigin(bottom)
                }
            } else {
                self.scrollView.contentView.scroll(to: bottom)
            }
            self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
        }
    }

    // MARK: - InputBarDelegate

    func inputBarSend(_ bar: InputBar, text: String) {
        AppState.shared.sendUserMessage(text)
        rebuild()
    }

    func inputBarStop(_ bar: InputBar) {
        AppState.shared.stop()
    }

    // MARK: - TurnViewDelegate

    func turnViewDidEditText(_ view: TurnView, newText: String) {
        let id = view.turnId
        AppState.shared.updateCurrent { c in
            guard let idx = c.turns.firstIndex(where: { $0.id == id }) else { return }
            // Assistant turns route through the variant helper so the edit
            // lands on the active variant (and `text` stays mirrored).
            // User turns have no variants, so direct mutation is fine.
            if c.turns[idx].role == .assistant {
                c.turns[idx].setActiveVariantText(newText)
            } else {
                c.turns[idx].text = newText
                c.turns[idx].edited = true
            }
        }
    }

    func turnViewDidRequestDelete(_ view: TurnView) {
        let id = view.turnId
        AppState.shared.updateCurrent { c in
            c.turns.removeAll(where: { $0.id == id })
        }
        rebuild()
    }

    func turnViewDidRequestCopy(_ view: TurnView) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(view.currentText, forType: .string)
    }

    func turnViewDidRequestRegen(_ view: TurnView) {
        AppState.shared.regenerate()
        rebuild()
    }

    func turnViewDidRequestContinue(_ view: TurnView) {
        AppState.shared.continueGeneration()
    }

    func turnViewDidRequestPreviousVariant(_ view: TurnView) {
        AppState.shared.selectPreviousVariant(turnId: view.turnId)
    }

    func turnViewDidRequestDiscardVariant(_ view: TurnView) {
        AppState.shared.deleteActiveVariant(turnId: view.turnId)
    }

    func turnViewDidRequestNextVariant(_ view: TurnView) {
        // ▶ extends past the last variant when this is the trailing assistant
        // turn — the click acts like a swipe-add. On non-trailing turns or
        // when the user is mid-list, just page forward.
        guard let chat = AppState.shared.currentChat,
              let turn = chat.turns.first(where: { $0.id == view.turnId }) else { return }
        let atEnd = turn.activeVariant >= turn.variants.count - 1
        if atEnd && view.isLastAssistant && !AppState.shared.isStreaming {
            AppState.shared.regenerate()
        } else {
            AppState.shared.selectNextVariant(turnId: view.turnId)
        }
    }

    // MARK: - Variant menu actions (⌘← / ⌘→)

    /// Page back through swipes on the trailing assistant turn. Targets the
    /// last assistant turn so the shortcut Just Works without the user having
    /// to focus a particular bubble first.
    @objc func previousVariant(_ sender: Any?) {
        guard let chat = AppState.shared.currentChat,
              !AppState.shared.isStreaming,
              let last = chat.turns.last(where: { $0.role == .assistant }) else { return }
        AppState.shared.selectPreviousVariant(turnId: last.id)
    }

    /// Page forward through swipes on the trailing assistant turn, or
    /// generate a new variant if already on the last one.
    @objc func nextVariant(_ sender: Any?) {
        guard let chat = AppState.shared.currentChat,
              !AppState.shared.isStreaming,
              let last = chat.turns.last(where: { $0.role == .assistant }) else { return }
        let atEnd = last.activeVariant >= last.variants.count - 1
        if atEnd {
            AppState.shared.regenerate()
        } else {
            AppState.shared.selectNextVariant(turnId: last.id)
        }
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let sel = menuItem.action
        if sel == #selector(previousVariant(_:)) {
            guard let chat = AppState.shared.currentChat,
                  !AppState.shared.isStreaming,
                  let last = chat.turns.last(where: { $0.role == .assistant }) else { return false }
            return last.activeVariant > 0
        }
        if sel == #selector(nextVariant(_:)) {
            guard let chat = AppState.shared.currentChat,
                  !AppState.shared.isStreaming,
                  chat.turns.contains(where: { $0.role == .assistant }) else { return false }
            // ▶ on the trailing assistant always lights up: at end-of-list it
            // generates a new variant (AppState.regenerate enforces the cap).
            return true
        }
        return true
    }

    // MARK: - EmptyStateViewDelegate

    func emptyStateDidPickStarter(_ view: EmptyStateView, text: String) {
        inputBar.textView.string = text
        view.window?.makeFirstResponder(inputBar.textView)
    }

    // MARK: - Per-chat server picker

    /// Refill the popup from current settings + select the chat's pin. Called
    /// on chat switch, chat update, and after settings save (which can change
    /// the profile list out from under us).
    private func rebuildServerPicker() {
        let s = AppState.shared.settings
        let chatPin = AppState.shared.currentChat?.serverId
        serverPicker.removeAllItems()
        // Index 0 — "(use default)" sentinel; falls through to
        // settings.defaultServerId at resolve time.
        serverPicker.addItem(withTitle: "(use default)")
        for p in s.servers {
            serverPicker.addItem(withTitle: p.name.isEmpty ? "(unnamed)" : p.name)
        }
        let idx = ChatServerPicker.selectedIndex(chatServerId: chatPin, settings: s)
        if idx < serverPicker.numberOfItems {
            serverPicker.selectItem(at: idx)
        }
    }

    @objc private func handleSettingsChanged() {
        rebuildServerPicker()
    }

    @objc private func serverPickerChanged(_ sender: NSPopUpButton) {
        let id = ChatServerPicker.idAtIndex(sender.indexOfSelectedItem,
                                            settings: AppState.shared.settings)
        AppState.shared.updateCurrent { $0.serverId = id }
    }
}

private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}
