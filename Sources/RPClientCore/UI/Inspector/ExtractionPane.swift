import AppKit

/// Per-chat extractor configuration: priority topics + scan window. Replaces
/// the topic editor that used to live in the debug eval window — that window
/// is now strictly for inspecting raw extractor output. Library presets are
/// global (Settings → Memory) and *copied* on add, so editing the library
/// later does not silently mutate active chats.
final class ExtractionPane: NSViewController, NSTextFieldDelegate {
    private let helpLabel = NSTextField(wrappingLabelWithString: """
        Soft hints that steer auto-extraction toward what matters in this chat. \
        Toggle entries to A/B which phrasings actually move the model. Avoid \
        "ignore X" / "don't track Y" — those tend to backfire. Just list what \
        you do want.
        """)
    /// Shares the suggestions help page — extraction is the "configure" twin
    /// to suggestions' "review" surface, and they read better as one document
    /// than two near-duplicates.
    private let helpButton = HelpButton(pageId: "memory-suggestions")
    /// Live cadence readout: last user turn extracted, current user-turn
    /// count, configured cadence, and the gap until the next auto run. Reads
    /// from `chat.lastExtractedTurn` (persisted on disk) so it survives app
    /// restarts and the value reflects historical state.
    private let cadenceLabel = NSTextField(wrappingLabelWithString: "")
    private let runNowButton = NSButton(title: "Run now", target: nil, action: nil)
    private let scanLabel = NSTextField(labelWithString: "Scan user turns (0 = auto):")
    private let scanField = NSTextField()
    private let scanStepper = NSStepper()
    private let topicsHeader = NSTextField(labelWithString: "Priority topics")
    private let scrollView = NSScrollView()
    private let topicsStack = NSStackView()
    private let addButton = NSButton(title: "+ Add topic", target: nil, action: nil)
    private let libraryButton = NSPopUpButton()
    private let saveToLibraryButton = NSButton(title: "Save active topics to library…", target: nil, action: nil)

    private var lastChatId: UUID?
    private var topics: [FactExtractionPriority] = []

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        helpLabel.font = Theme.font(11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(helpLabel)
        v.addSubview(helpButton)

        cadenceLabel.font = Theme.mono(11)
        cadenceLabel.textColor = .secondaryLabelColor
        cadenceLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(cadenceLabel)

        runNowButton.target = self
        runNowButton.action = #selector(runNowTapped)
        runNowButton.bezelStyle = .rounded
        runNowButton.toolTip = "Force-fire the extractor on the current chat regardless of cadence."
        runNowButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(runNowButton)

        scanLabel.font = Theme.font(11)
        scanLabel.textColor = .secondaryLabelColor
        scanLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scanLabel)

        let scanIntF = NumberFormatter()
        scanIntF.allowsFloats = false
        scanIntF.minimum = 0
        scanIntF.maximum = 200
        scanField.formatter = scanIntF
        scanField.alignment = .right
        scanField.isEditable = true
        scanField.isBezeled = true
        scanField.bezelStyle = .roundedBezel
        scanField.target = self
        scanField.action = #selector(scanFieldChanged)
        scanField.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scanField)

        scanStepper.minValue = 0
        scanStepper.maxValue = 200
        scanStepper.increment = 1
        scanStepper.target = self
        scanStepper.action = #selector(scanStepperChanged)
        scanStepper.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scanStepper)

        topicsHeader.font = Theme.bold(12)
        topicsHeader.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(topicsHeader)

        topicsStack.orientation = .vertical
        topicsStack.spacing = 4
        topicsStack.alignment = .leading
        topicsStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        topicsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = topicsStack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        topicsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        addButton.target = self
        addButton.action = #selector(addBlankTopic)
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(addButton)

        libraryButton.translatesAutoresizingMaskIntoConstraints = false
        libraryButton.target = self
        libraryButton.action = #selector(librarySelected(_:))
        libraryButton.pullsDown = true
        v.addSubview(libraryButton)

        saveToLibraryButton.target = self
        saveToLibraryButton.action = #selector(saveActiveTopicsToLibrary)
        saveToLibraryButton.bezelStyle = .rounded
        saveToLibraryButton.toolTip = "Copy enabled topics into the global library so other chats can add them."
        saveToLibraryButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(saveToLibraryButton)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),

            helpButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            cadenceLabel.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 10),
            cadenceLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            cadenceLabel.trailingAnchor.constraint(equalTo: runNowButton.leadingAnchor, constant: -8),

            runNowButton.centerYAnchor.constraint(equalTo: cadenceLabel.centerYAnchor),
            runNowButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scanLabel.topAnchor.constraint(equalTo: cadenceLabel.bottomAnchor, constant: 10),
            scanLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            scanField.centerYAnchor.constraint(equalTo: scanLabel.centerYAnchor),
            scanField.leadingAnchor.constraint(equalTo: scanLabel.trailingAnchor, constant: 6),
            scanField.widthAnchor.constraint(equalToConstant: 60),

            scanStepper.centerYAnchor.constraint(equalTo: scanLabel.centerYAnchor),
            scanStepper.leadingAnchor.constraint(equalTo: scanField.trailingAnchor, constant: 4),

            topicsHeader.topAnchor.constraint(equalTo: scanLabel.bottomAnchor, constant: 14),
            topicsHeader.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),

            scrollView.topAnchor.constraint(equalTo: topicsHeader.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            addButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: libraryButton.topAnchor, constant: -6),

            libraryButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            libraryButton.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            libraryButton.bottomAnchor.constraint(equalTo: saveToLibraryButton.topAnchor, constant: -6),

            saveToLibraryButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            saveToLibraryButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refreshCadence),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        helpLabel.font = Theme.font(11)
        cadenceLabel.font = Theme.mono(11)
        scanLabel.font = Theme.font(11)
        topicsHeader.font = Theme.bold(12)
        for view in topicsStack.arrangedSubviews {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                field.font = Theme.font(12)
            }
        }
    }

    /// Render the cadence status row. Called from `reload` and on the
    /// `statusChanged` notification so the countdown ticks down without the
    /// user having to switch chats. Disables the "Run now" button while
    /// extraction or another exclusive side-call is in flight.
    @objc private func refreshCadence() {
        let s = AppState.shared
        guard let chat = s.currentChat else {
            cadenceLabel.stringValue = "—"
            runNowButton.isEnabled = false
            return
        }
        let userTurnsNow = chat.turns.filter { $0.role == .user }.count
        let cadence = max(1, s.settings.factExtractionEveryNTurns)
        let lastSeen = min(chat.lastExtractedTurn, userTurnsNow)
        let unseen = max(0, userTurnsNow - lastSeen)
        let until = max(0, cadence - unseen)
        let enabled = s.settings.factExtractionEnabled

        var line = "auto-extract: "
        if !enabled {
            line += "disabled in Settings"
        } else if s.isExtracting {
            line += "running now…"
        } else {
            let lastDescriptor: String
            if chat.lastExtractedTurn == 0 && userTurnsNow > 0 {
                lastDescriptor = "never"
            } else {
                lastDescriptor = "user turn \(chat.lastExtractedTurn)"
            }
            line += "last \(lastDescriptor)  ·  now \(userTurnsNow)  ·  every \(cadence)"
            if userTurnsNow == 0 {
                line += "  ·  waiting for first turn"
            } else if until == 0 {
                line += "  ·  ready (fires after next assistant reply)"
            } else {
                line += "  ·  next in \(until) user turn\(until == 1 ? "" : "s")"
            }
        }
        if let err = s.lastExtractError {
            line += "\nlast error: \(err)"
        }
        cadenceLabel.stringValue = line
        runNowButton.isEnabled = enabled
            && !s.isExtracting && !s.isStreaming && !s.isSummarizing && !s.isRetrieving
            && userTurnsNow > 0
    }

    @objc private func runNowTapped() {
        AppState.shared.maybeAutoExtract(force: true)
    }

    // MARK: - Reload

    @objc private func reload() {
        refreshCadence()
        guard let chat = AppState.shared.currentChat else {
            topics = []
            rebuildTopicsUI()
            scanField.integerValue = 0
            scanStepper.integerValue = 0
            rebuildLibraryMenu()
            return
        }
        let chatChanged = chat.id != lastChatId
        let editingField = view.window?.firstResponder as? NSText
        let currentlyEditing = editingField?.delegate is NSTextField

        if chatChanged || (chat.factExtractionPriorities != topics && !currentlyEditing) {
            lastChatId = chat.id
            topics = chat.factExtractionPriorities
            rebuildTopicsUI()
        }
        if !currentlyEditing || chatChanged {
            scanField.integerValue = chat.factExtractionScanTurns
            scanStepper.integerValue = chat.factExtractionScanTurns
        }
        rebuildLibraryMenu()
    }

    private func saveTopics() {
        guard let id = lastChatId else { return }
        let snapshot = topics
        AppState.shared.updateChat(id: id) { c in
            c.factExtractionPriorities = snapshot
        }
    }

    // MARK: - Topic rows

    private func rebuildTopicsUI() {
        for v in topicsStack.arrangedSubviews { topicsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (idx, topic) in topics.enumerated() {
            let row = makeRow(topic: topic, index: idx)
            topicsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: topicsStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(topic: FactExtractionPriority, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let check = NSButton(checkboxWithTitle: "", target: self, action: #selector(toggleEnabled(_:)))
        check.tag = index
        check.state = topic.enabled ? .on : .off
        check.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: topic.text)
        field.placeholderString = "topic phrase"
        field.font = Theme.font(12)
        field.delegate = self
        field.tag = index
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(textCommitted(_:))

        let remove = NSButton(title: "×", target: self, action: #selector(removeTopic(_:)))
        remove.tag = index
        remove.bezelStyle = .circular
        remove.toolTip = "Remove this topic"
        remove.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(check)
        row.addSubview(field)
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),

            check.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            check.centerYAnchor.constraint(equalTo: row.centerYAnchor),

            field.leadingAnchor.constraint(equalTo: check.trailingAnchor, constant: 6),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -6),

            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    private func commitTopicsFromUI() {
        for (idx, view) in topicsStack.arrangedSubviews.enumerated() where idx < topics.count {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                topics[idx].text = field.stringValue
            }
        }
    }

    @objc private func addBlankTopic() {
        commitTopicsFromUI()
        topics.append(FactExtractionPriority(text: "", enabled: true))
        rebuildTopicsUI()
        saveTopics()
        if let lastField = topicsStack.arrangedSubviews.last?
            .subviews.compactMap({ $0 as? NSTextField }).first {
            view.window?.makeFirstResponder(lastField)
        }
    }

    @objc private func removeTopic(_ sender: NSButton) {
        commitTopicsFromUI()
        let idx = sender.tag
        guard topics.indices.contains(idx) else { return }
        topics.remove(at: idx)
        rebuildTopicsUI()
        saveTopics()
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        let idx = sender.tag
        guard topics.indices.contains(idx) else { return }
        commitTopicsFromUI()
        topics[idx].enabled = sender.state == .on
        saveTopics()
    }

    @objc private func textCommitted(_ sender: NSTextField) {
        let idx = sender.tag
        guard topics.indices.contains(idx) else { return }
        topics[idx].text = sender.stringValue
        saveTopics()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        // The scan field uses the same delegate path; treat it specially.
        if field === scanField {
            commitScanFieldToChat()
            return
        }
        let idx = field.tag
        guard topics.indices.contains(idx) else { return }
        topics[idx].text = field.stringValue
        saveTopics()
    }

    // MARK: - Scan window

    @objc private func scanFieldChanged() {
        scanStepper.integerValue = max(0, min(200, scanField.integerValue))
        scanField.integerValue = scanStepper.integerValue
        commitScanFieldToChat()
    }

    @objc private func scanStepperChanged() {
        scanField.integerValue = scanStepper.integerValue
        commitScanFieldToChat()
    }

    private func commitScanFieldToChat() {
        guard let id = lastChatId else { return }
        let v = max(0, min(200, scanField.integerValue))
        AppState.shared.updateChat(id: id) { c in
            c.factExtractionScanTurns = v
        }
    }

    // MARK: - Library

    private func rebuildLibraryMenu() {
        libraryButton.removeAllItems()
        // First menu item is the visible title (pull-down style).
        libraryButton.addItem(withTitle: "Add from library…")
        let library = AppState.shared.settings.priorityTopicLibrary
        if library.isEmpty {
            let empty = NSMenuItem(title: "(library empty — add presets in Settings)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            libraryButton.menu?.addItem(empty)
            return
        }
        for entry in library {
            let item = NSMenuItem(title: entry.text, action: #selector(librarySelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = entry.id.uuidString
            libraryButton.menu?.addItem(item)
        }
    }

    @objc private func librarySelected(_ sender: Any) {
        // Triggered both by the popup's action and by individual menu-item targets.
        guard let id = (libraryButton.selectedItem?.representedObject as? String).flatMap(UUID.init(uuidString:)) ?? extractIdFromMenuSender(sender) else {
            return
        }
        let library = AppState.shared.settings.priorityTopicLibrary
        guard let entry = library.first(where: { $0.id == id }) else { return }
        // Skip if an enabled topic with this exact text already exists.
        commitTopicsFromUI()
        if topics.contains(where: { $0.text == entry.text }) {
            return
        }
        topics.append(FactExtractionPriority(text: entry.text, enabled: true))
        rebuildTopicsUI()
        saveTopics()
        // Reset the popup's visible title back to the prompt.
        libraryButton.selectItem(at: 0)
    }

    private func extractIdFromMenuSender(_ sender: Any) -> UUID? {
        if let item = sender as? NSMenuItem,
           let raw = item.representedObject as? String {
            return UUID(uuidString: raw)
        }
        return nil
    }

    @objc private func saveActiveTopicsToLibrary() {
        commitTopicsFromUI()
        let active = topics.filter {
            $0.enabled && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        guard !active.isEmpty else { return }
        var s = AppState.shared.settings
        var added = 0
        for t in active {
            let trimmed = t.text.trimmingCharacters(in: .whitespaces)
            if s.priorityTopicLibrary.contains(where: { $0.text == trimmed }) { continue }
            s.priorityTopicLibrary.append(LibraryTopic(text: trimmed))
            added += 1
        }
        guard added > 0 else { return }
        AppState.shared.saveSettings(s)
        rebuildLibraryMenu()
    }
}
