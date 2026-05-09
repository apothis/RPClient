import AppKit

final class ChatViewController: NSViewController, InputBarDelegate, TurnViewDelegate, EmptyStateViewDelegate, NSMenuItemValidation, NSPopoverDelegate {
    private let scrollView = NSScrollView()
    private let stackView = NSStackView()
    private let inputBar = InputBar()
    private let statusBar = StatusBar()
    private let scrollLatestButton = NSButton()
    /// V2_UI_OVERHAUL §4.5 stage-3 — bottom-centre "Stop response"
    /// pill shown during streaming. Per spec, the transcript carries
    /// streaming state; the cancel affordance is a dedicated pill, not
    /// a send-button morph (ChatGPT's anti-pattern). The InputBar's
    /// existing send→stop morph stays as a redundant secondary
    /// affordance until 4.g (composer redesign) replaces it.
    private let stopButton = NSButton()
    private let emptyStateView = EmptyStateView()
    /// Phase 4 §5.4 — per-chat server pin. nil/(use default) = chat
    /// generation goes to settings.defaultServerId; otherwise pinned to the
    /// chosen profile.
    private let chatHeader = NSView()
    private let serverPicker = NSPopUpButton()
    /// Phase 6 §7.1i — runtime voice toggle. Click flips
    /// `Settings.voiceActive`; greys out when `voiceEnabled` (the subsystem
    /// gate) is off, with a tooltip pointing the user to Settings.
    private let speakerButton = NSButton()
    /// Phase 6 §7.5b — per-chat default narrator voice. nil/(use settings
    /// default) falls through to `Settings.defaultVoice`. Entities with
    /// their own `voice` override both. Speaker layer (§7.4) is the consumer.
    private let voicePicker = NSPopUpButton()
    private let voiceLabel = NSTextField(labelWithString: "Voice:")
    /// Phase 6 §7.5d — per-chat attribution mode picker. Bound to
    /// `Chat.attributionMode`; consumed by `Speaker` via `SpeakerAttribution`.
    private let attributionPicker = NSPopUpButton()
    private let attributionLabel = NSTextField(labelWithString: "Attribution:")
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
        configureSpeakerButton()
        chatHeader.addSubview(speakerButton)

        voiceLabel.font = Theme.font(11)
        voiceLabel.textColor = .secondaryLabelColor
        voiceLabel.translatesAutoresizingMaskIntoConstraints = false
        voicePicker.target = self
        voicePicker.action = #selector(voicePickerChanged(_:))
        voicePicker.bezelStyle = .rounded
        voicePicker.font = Theme.font(11)
        voicePicker.translatesAutoresizingMaskIntoConstraints = false
        chatHeader.addSubview(voiceLabel)
        chatHeader.addSubview(voicePicker)

        attributionLabel.font = Theme.font(11)
        attributionLabel.textColor = .secondaryLabelColor
        attributionLabel.translatesAutoresizingMaskIntoConstraints = false
        attributionPicker.target = self
        attributionPicker.action = #selector(attributionPickerChanged(_:))
        attributionPicker.bezelStyle = .rounded
        attributionPicker.font = Theme.font(11)
        attributionPicker.translatesAutoresizingMaskIntoConstraints = false
        chatHeader.addSubview(attributionLabel)
        chatHeader.addSubview(attributionPicker)

        v.addSubview(chatHeader)
        NSLayoutConstraint.activate([
            chatHeader.heightAnchor.constraint(equalToConstant: 28),
            serverLabel.leadingAnchor.constraint(equalTo: chatHeader.leadingAnchor, constant: 12),
            serverLabel.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            serverPicker.leadingAnchor.constraint(equalTo: serverLabel.trailingAnchor, constant: 6),
            serverPicker.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            speakerButton.trailingAnchor.constraint(equalTo: chatHeader.trailingAnchor, constant: -12),
            speakerButton.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            speakerButton.widthAnchor.constraint(equalToConstant: 22),
            speakerButton.heightAnchor.constraint(equalToConstant: 22),
            voicePicker.trailingAnchor.constraint(equalTo: speakerButton.leadingAnchor, constant: -8),
            voicePicker.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            voicePicker.widthAnchor.constraint(lessThanOrEqualToConstant: 220),
            voiceLabel.trailingAnchor.constraint(equalTo: voicePicker.leadingAnchor, constant: -6),
            voiceLabel.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            attributionPicker.trailingAnchor.constraint(equalTo: voiceLabel.leadingAnchor, constant: -12),
            attributionPicker.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
            attributionLabel.trailingAnchor.constraint(equalTo: attributionPicker.leadingAnchor, constant: -6),
            attributionLabel.centerYAnchor.constraint(equalTo: chatHeader.centerYAnchor),
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

        configureStopButton()
        v.addSubview(stopButton)

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
            scrollLatestButton.heightAnchor.constraint(equalToConstant: 30),

            // V2_UI_OVERHAUL §4.5 stage-3 — stop pill bottom-centre,
            // 12pt above the input bar.
            stopButton.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            stopButton.bottomAnchor.constraint(equalTo: inputBar.topAnchor, constant: -12)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleStreamToken),
            name: AppNotification.streamTokenAppended, object: nil)
        nc.addObserver(self, selector: #selector(handleStreamFinished),
            name: AppNotification.streamFinished, object: nil)
        nc.addObserver(self, selector: #selector(handleStreamStarted),
            name: AppNotification.streamStarted, object: nil)
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
        nc.addObserver(self, selector: #selector(refreshSpeakerButton),
            name: AppNotification.voiceActiveChanged, object: nil)
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

    /// V2_UI_OVERHAUL §4.5 stage-3 — Stop pill at the bottom-centre
    /// of the transcript while the stream is active. Click cancels
    /// the request via AppState.shared.stop(), same path as the
    /// InputBar's send→stop morph (which stays in place as a
    /// secondary affordance until 4.g composer redesign).
    private func configureStopButton() {
        stopButton.title = " Stop response"
        stopButton.image = NSImage(
            systemSymbolName: "stop.circle",
            accessibilityDescription: "Stop response"
        )
        stopButton.imagePosition = .imageLeading
        stopButton.imageScaling = .scaleProportionallyDown
        stopButton.bezelStyle = .rounded
        stopButton.controlSize = .small
        stopButton.font = DesignTokens.Typography.subheadline
        stopButton.contentTintColor = .secondaryLabelColor
        stopButton.target = self
        stopButton.action = #selector(stopButtonTapped)
        stopButton.translatesAutoresizingMaskIntoConstraints = false
        stopButton.isHidden = true
        stopButton.toolTip = "Stop the active stream"
    }

    @objc private func stopButtonTapped() {
        AppState.shared.stop()
    }

    @objc private func handleStreamStarted() {
        stopButton.isHidden = false
    }

    private func installEmptyState() {
        // V2_UI_OVERHAUL §4.6 — configure with the active chat's
        // character (if any) so the empty state shows the avatar +
        // name + scenario. Free-form chats fall back to the SF Symbol
        // person glyph via EmptyStateView.configure(nil).
        let character = AppState.shared.currentChat?.characterId
            .flatMap { AppState.shared.character(id: $0) }
        emptyStateView.configure(character: character)
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
        rebuildVoicePicker()
        rebuildAttributionPicker()
        guard let chat = AppState.shared.currentChat else {
            DebugLog.shared.write("ui: rebuild — no current chat")
            removeEmptyState()
            return
        }
        DebugLog.shared.write(
            "ui: rebuild chat=\(chat.id) turns=\(chat.turns.count) activePath=\(chat.activePath.count)"
        )
        // Phase 7 §3.3b — the renderable list is the active path, not the
        // storage `turns` array. Off-path siblings (created by fork) live in
        // `chat.turns` so a later branch switch can re-surface them, but
        // they don't show in the visible chat.
        let active = chat.activeTurns
        if active.isEmpty {
            installEmptyState()
        } else {
            removeEmptyState()
        }
        let lastAssistantIdx = active.lastIndex(where: { $0.role == .assistant })
        let chatCharacter = chat.characterId.flatMap { AppState.shared.character(id: $0) }
        let isMultiCast = chat.cast.count > 1
        for (i, t) in active.enumerated() {
            // Phase 8 §4.3 — per-turn character resolution. Assistant
            // turns with a speakerId resolve to that cast member's card;
            // unresolved or nil falls back to the chat-level character
            // so legacy single-character chats render exactly as today.
            // User turns get nil (no speaker chip on user bubbles).
            let character: Character? = {
                guard t.role == .assistant else { return nil }
                if let sid = t.speakerId,
                   let resolved = AppState.shared.character(id: sid) {
                    return resolved
                }
                return chatCharacter
            }()
            // V2_UI_OVERHAUL §4.c — user-turn caption resolves through
            // (chat persona → settings.userName → "You"). Assistant
            // turns get nil here; the assistant header drives off
            // `character.name`.
            let personaName: String? = (t.role == .user)
                ? TurnView.userTurnDisplayName(
                    personaName: AppState.shared.persona(id: chat.personaId)?.name,
                    settingsUserName: AppState.shared.settings.userName
                  )
                : nil
            let tv = TurnView(
                turn: t,
                character: character,
                personaName: personaName,
                multiCast: isMultiCast
            )
            tv.delegate = self
            tv.isLastAssistant = (i == lastAssistantIdx)
            tv.setVariantState(
                active: t.activeVariant,
                count: t.variants.count,
                activeIsStale: chat.isVariantStale(turnId: t.id, variantIndex: t.activeVariant)
            )
            // Branch glyph in the gutter when this turn has siblings —
            // i.e., the parent has more than one child. Only meaningful for
            // non-root turns. Also push N/M position so the glyph can show
            // "2/3" inline.
            if let pid = t.parentId {
                let siblings = chat.children(of: pid)
                tv.hasSiblings = siblings.count > 1
                tv.siblingCount = siblings.count
                tv.siblingIndex = (siblings.firstIndex(where: { $0.id == t.id }) ?? 0) + 1
                if siblings.count > 1 {
                    DebugLog.shared.write(
                        "ui: glyph on i=\(i) (\(tv.siblingIndex)/\(siblings.count) siblings)"
                    )
                }
                // Toolbar fork button is meaningful on every assistant turn
                // with a parent (i.e., not the root greeting).
                tv.canFork = (t.role == .assistant)
            }
            tv.setBranchPopoverOpen(false)
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
        // If the active-path count changed (e.g. user message + empty
        // assistant added, or a fork landed and rewrote the path), rebuild
        // structurally. Pure text edits leave the path stable and update
        // in place. §3.3b: count is over `activeTurns`, not storage —
        // off-path siblings live in `turns` and don't render.
        guard let chat = AppState.shared.currentChat else { return }
        let active = chat.activeTurns
        if active.count != turnViews.count {
            rebuild()
            return
        }
        // Same count, different IDs = a fork swapped a turn in place (forkFrom
        // truncates after the parent and pushes a new sibling, so the leaf
        // index stays the same but the turn at that index is a fresh UUID).
        // TurnView.turnId is `let`, so a stale match would route stream tokens
        // through `lastView.turnId == lastTurn.id` checks that silently fail.
        // Force a structural rebuild when ids drift.
        for (i, t) in active.enumerated() where i < turnViews.count {
            if turnViews[i].turnId != t.id {
                DebugLog.shared.write("ui: rebuild — id mismatch at i=\(i)")
                rebuild()
                return
            }
        }
        DebugLog.shared.write("ui: in-place update (active.count=\(active.count))")
        // Variant state can change without the turn count moving — regen now
        // adds a variant in place, paging changes the active index, etc.
        // Push the latest tuple to each view so the pager redraws (including
        // the ⚠ stale badge, since paging an earlier turn can change the
        // staleness of every later turn's active variant).
        for (i, t) in active.enumerated() where i < turnViews.count {
            let tv = turnViews[i]
            tv.setVariantState(
                active: t.activeVariant,
                count: t.variants.count,
                activeIsStale: chat.isVariantStale(turnId: t.id, variantIndex: t.activeVariant)
            )
            if let pid = t.parentId {
                let siblings = chat.children(of: pid)
                tv.hasSiblings = siblings.count > 1
                tv.siblingCount = siblings.count
                tv.siblingIndex = (siblings.firstIndex(where: { $0.id == t.id }) ?? 0) + 1
                tv.canFork = (t.role == .assistant)
            }
            // Paging changes which variant's text is mirrored on `text`; the
            // bubble needs to reflect that immediately.
            if tv.currentText != t.text {
                tv.setText(t.text)
            }
            // Phase 11 §D.11 — paging also changes which variant's
            // thinkingTrace applies. Push the matching trace through
            // every in-place update so the disclosure pill always
            // reflects the active variant. No-op when unchanged.
            if t.role == .assistant {
                let active = t.activeVariant
                let trace = t.variants.indices.contains(active)
                    ? t.variants[active].thinkingTrace
                    : nil
                tv.setThinkingTrace(trace)
            }
        }
        // Update titles potentially in status bar handled elsewhere.
        statusBar.refresh()
    }

    @objc private func handleStreamToken() {
        // Stream tokens land in the active leaf — that's the turn AppState
        // appended/forked into. Storage's `turns.last` may be off-path
        // (e.g., user just switched away from a recent fork), so always go
        // through activePath.
        guard let chat = AppState.shared.currentChat,
              let leafId = chat.activePath.last,
              let lastTurn = chat.turn(id: leafId),
              let lastView = turnViews.last else {
            DebugLog.shared.write("ui: stream-token dropped — no chat / no leaf / no view")
            return
        }
        guard lastView.turnId == lastTurn.id else {
            DebugLog.shared.write(
                "ui: stream-token dropped — leaf=\(leafId) lastView.turnId=\(lastView.turnId) (id mismatch)"
            )
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
        let leafId = AppState.shared.currentChat?.activePath.last
        DebugLog.shared.write(
            "ui: stream-finished leaf=\(leafId.map { $0.uuidString } ?? "nil") views=\(turnViews.count)"
        )
        AppState.shared.persistCurrent()
        inputBar.updateButtons()
        // V2_UI_OVERHAUL §4.5 stage-3 — hide the bottom-centre Stop
        // pill once the stream's done (or cancelled).
        stopButton.isHidden = true
        for tv in turnViews where tv.isStreaming {
            tv.isStreaming = false
        }
        // Stream finish unconditionally clears any lingering Thinking…
        // placeholder, even if the close tag never arrived.
        for tv in turnViews where tv.isThinking {
            tv.isThinking = false
        }
        // Phase 11 §D.11 — the streaming filter has now written the
        // captured `<think>` trace onto the active variant. Push it
        // into the trailing assistant TurnView so the disclosure pill
        // can surface. The placeholder TurnView was created at
        // stream-start when the variant was still empty, so its
        // init-time read got nil; this is the catch-up.
        if let chat = AppState.shared.currentChat,
           let leafId = chat.activePath.last,
           let lastTurn = chat.turn(id: leafId),
           let lastView = turnViews.last,
           lastView.turnId == lastTurn.id,
           lastTurn.role == .assistant {
            let active = lastTurn.activeVariant
            let trace = lastTurn.variants.indices.contains(active)
                ? lastTurn.variants[active].thinkingTrace
                : nil
            lastView.setThinkingTrace(trace)
        }
        if !userScrolledUp {
            scrollToBottom(animated: true)
        }
    }

    @objc private func handleThinkingStateChanged() {
        let thinking = AppState.shared.isThinking
        // Only the trailing assistant turn — the one currently streaming —
        // ever shows the placeholder. Earlier turns are settled history.
        // §3.3b: target via activePath leaf, not storage's `turns.last`.
        guard let lastView = turnViews.last,
              let leafId = AppState.shared.currentChat?.activePath.last,
              lastView.turnId == leafId else {
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
            // Drop the deleted id from activePath so subsequent reads stay
            // consistent with the tree. Branches pane / minimap rely on
            // this for correct leaf detection (§3.4 +).
            c.activePath.removeAll(where: { $0 == id })
        }
        NotificationCenter.default.post(name: AppNotification.chatTreeChanged, object: nil)
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

    func turnViewDidRequestForkFrom(_ view: TurnView) {
        AppState.shared.forkFrom(turnId: view.turnId)
    }

    func turnViewDidRequestContinue(_ view: TurnView) {
        AppState.shared.continueGeneration()
    }

    func turnViewDidRequestReplayAudio(_ view: TurnView) {
        AppState.shared.speaker.replay(turnId: view.turnId)
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

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        siblingPopoverAnchorView?.setBranchPopoverOpen(false)
        siblingPopoverAnchorView = nil
        siblingPopover = nil
    }

    func turnViewDidRequestSiblingPopover(_ view: TurnView, anchor: NSView) {
        guard let chat = AppState.shared.currentChat,
              let turn = chat.turn(id: view.turnId),
              let pid = turn.parentId else { return }
        let siblings = chat.children(of: pid)
        guard siblings.count > 1 else { return }
        presentSiblingPopover(siblings: siblings, activeId: view.turnId, anchor: anchor)
    }

    private var siblingPopover: NSPopover?
    /// The TurnView whose gutter glyph triggered the currently-open popover.
    /// Held weakly so we can flip its glyph highlight off when the popover
    /// closes (NSPopoverDelegate.popoverDidClose) without leaking when the
    /// view is rebuilt out from under us.
    private weak var siblingPopoverAnchorView: TurnView?

    private func presentSiblingPopover(siblings: [Turn], activeId: UUID, anchor: NSView) {
        siblingPopover?.close()
        let pop = NSPopover()
        pop.behavior = .transient
        pop.delegate = self
        pop.contentViewController = SiblingPickerViewController(
            siblings: siblings,
            activeId: activeId,
            onPick: { [weak self] turnId in
                self?.siblingPopover?.close()
                self?.siblingPopover = nil
                AppState.shared.switchBranch(to: turnId)
            }
        )
        siblingPopover = pop
        siblingPopoverAnchorView = anchor.enclosingTurnView()
        siblingPopoverAnchorView?.setBranchPopoverOpen(true)
        pop.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxX)
    }

    // MARK: - Variant menu actions (⌘← / ⌘→)

    /// Page back through swipes on the trailing assistant turn. Targets the
    /// last assistant turn so the shortcut Just Works without the user having
    /// to focus a particular bubble first. §3.3b: looks at activeTurns —
    /// off-path siblings (forked alternatives) live in storage but never
    /// claim "trailing".
    @objc func previousVariant(_ sender: Any?) {
        guard let chat = AppState.shared.currentChat,
              !AppState.shared.isStreaming,
              let last = chat.activeTurns.last(where: { $0.role == .assistant }) else { return }
        AppState.shared.selectPreviousVariant(turnId: last.id)
    }

    /// Page forward through swipes on the trailing assistant turn, or
    /// generate a new variant if already on the last one.
    @objc func nextVariant(_ sender: Any?) {
        guard let chat = AppState.shared.currentChat,
              !AppState.shared.isStreaming,
              let last = chat.activeTurns.last(where: { $0.role == .assistant }) else { return }
        let atEnd = last.activeVariant >= last.variants.count - 1
        if atEnd {
            AppState.shared.regenerate()
        } else {
            AppState.shared.selectNextVariant(turnId: last.id)
        }
    }

    /// Phase 7 §3.3b — Cmd-B menu action. Forks the trailing assistant turn
    /// (creates a new sibling, stream into it). The design-doc target is
    /// "focused turn's parent → fall back to trailing"; today the only
    /// in-app focus is text-edit mode, so the fallback is the load-bearing
    /// path. Future work: track a soft-focused turn via click-without-edit
    /// and prefer it here.
    @objc func forkBranch(_ sender: Any?) {
        guard let chat = AppState.shared.currentChat,
              !AppState.shared.isStreaming,
              let last = chat.activeTurns.last(where: { $0.role == .assistant }),
              last.parentId != nil else { return }
        AppState.shared.forkFrom(turnId: last.id)
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let sel = menuItem.action
        if sel == #selector(previousVariant(_:)) {
            guard let chat = AppState.shared.currentChat,
                  !AppState.shared.isStreaming,
                  let last = chat.activeTurns.last(where: { $0.role == .assistant }) else { return false }
            return last.activeVariant > 0
        }
        if sel == #selector(nextVariant(_:)) {
            guard let chat = AppState.shared.currentChat,
                  !AppState.shared.isStreaming,
                  chat.activeTurns.contains(where: { $0.role == .assistant }) else { return false }
            // ▶ on the trailing assistant always lights up: at end-of-list it
            // generates a new variant (AppState.regenerate enforces the cap).
            return true
        }
        if sel == #selector(forkBranch(_:)) {
            // Disabled when streaming, or when there's no assistant turn yet
            // (root-only chats), or when the trailing asst is the root (no
            // parent to fork from — currently impossible in production but
            // defensive).
            guard let chat = AppState.shared.currentChat,
                  !AppState.shared.isStreaming,
                  let last = chat.activeTurns.last(where: { $0.role == .assistant }),
                  last.parentId != nil else { return false }
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
        rebuildVoicePicker()
        rebuildAttributionPicker()
        refreshSpeakerButton()
    }

    private func rebuildVoicePicker() {
        VoicePopupBuilder.populate(
            voicePicker,
            options: VoicePopupBuilder.currentOptions(),
            current: AppState.shared.currentChat?.voice,
            sentinelTitle: "(use settings default)"
        )
        voicePicker.isEnabled = AppState.shared.currentChat != nil
    }

    @objc private func voicePickerChanged(_ sender: NSPopUpButton) {
        AppState.shared.updateCurrent { c in
            c.voice = VoicePopupBuilder.preference(
                fromSelectionOf: sender,
                previous: c.voice
            )
        }
    }

    /// Phase 6 §7.5d — populate the two-item attribution mode popup and select
    /// the chat's current mode. `representedObject` carries the rawValue so the
    /// action handler is decoupled from menu order.
    private func rebuildAttributionPicker() {
        attributionPicker.removeAllItems()
        let modes: [AttributionMode] = [.heuristic, .tagged]
        for mode in modes {
            attributionPicker.addItem(withTitle: mode.displayName)
            attributionPicker.lastItem?.representedObject = mode.rawValue
        }
        let current = AppState.shared.currentChat?.attributionMode ?? .heuristic
        for (i, item) in (attributionPicker.menu?.items ?? []).enumerated() {
            if (item.representedObject as? String) == current.rawValue {
                attributionPicker.selectItem(at: i)
                break
            }
        }
        attributionPicker.isEnabled = AppState.shared.currentChat != nil
    }

    @objc private func attributionPickerChanged(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let mode = AttributionMode(rawValue: raw) else { return }
        AppState.shared.updateCurrent { c in
            c.attributionMode = mode
        }
    }

    // MARK: - Voice toggle (Phase 6 §7.1i)

    private func configureSpeakerButton() {
        speakerButton.bezelStyle = .accessoryBarAction
        speakerButton.isBordered = false
        speakerButton.imagePosition = .imageOnly
        speakerButton.imageScaling = .scaleProportionallyDown
        speakerButton.target = self
        speakerButton.action = #selector(speakerButtonTapped)
        speakerButton.translatesAutoresizingMaskIntoConstraints = false
        refreshSpeakerButton()
    }

    @objc private func refreshSpeakerButton() {
        let s = AppState.shared.settings
        let symbol = s.voiceActive ? "speaker.wave.2.fill" : "speaker.slash.fill"
        let label = s.voiceActive ? "Voice on" : "Voice muted"
        speakerButton.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        speakerButton.isEnabled = s.voiceEnabled
        speakerButton.alphaValue = s.voiceEnabled ? 1.0 : 0.4
        // Orange when active so the on/off state is visible at a glance —
        // a black-on-black SF Symbol icon left the user guessing whether
        // voice was actually enabled. nil reverts to the default template
        // tint when muted.
        speakerButton.contentTintColor = s.voiceActive ? .systemOrange : nil
        speakerButton.toolTip = s.voiceEnabled
            ? (s.voiceActive ? "Mute voice for this chat" : "Unmute voice for this chat")
            : "Enable the voice subsystem in Settings"
    }

    @objc private func speakerButtonTapped() {
        var s = AppState.shared.settings
        guard s.voiceEnabled else { return }
        s.voiceActive.toggle()
        AppState.shared.saveSettings(s)
        NotificationCenter.default.post(name: AppNotification.voiceActiveChanged, object: nil)
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

private extension NSView {
    /// Walk up the superview chain until we hit a TurnView (or run out).
    /// Used by the sibling-popover routing so we can pin glyph highlight
    /// to the right TurnView regardless of which inner element fired.
    func enclosingTurnView() -> TurnView? {
        var v: NSView? = self
        while let cur = v {
            if let tv = cur as? TurnView { return tv }
            v = cur.superview
        }
        return nil
    }
}
