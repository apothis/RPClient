import AppKit

/// Inspector pane for world-info entries (V2 Phase 1, V5).
/// Lists per-chat entries; only the matched subset (see `WorldInfoInjector`)
/// is actually injected into the prompt at send time.
final class WorldInfoPane: NSViewController, NSTextFieldDelegate, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let helpLabel = NSTextField(labelWithString:
        "World-info entries. Only entries whose keys appear in the recent turns (or set to Always) are injected into the prompt.")
    private let helpButton = HelpButton(pageId: "memory-world-info")
    private let countLabel = NSTextField(labelWithString: "")
    private let addButton = NSButton(title: "+ Add entry", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No entries yet. Click + Add entry to create one.")

    private var lastChatId: UUID?
    private var renderedSignature: String = ""
    private var entryTextViews: [UUID: EntryTextView] = [:]

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        helpLabel.font = Theme.font(11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 0
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(helpLabel)
        v.addSubview(helpButton)

        stack.orientation = .vertical
        stack.spacing = 8
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        emptyLabel.font = Theme.font(11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(emptyLabel)

        addButton.target = self
        addButton.action = #selector(addEntry)
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(addButton)

        countLabel.font = Theme.mono(11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(countLabel)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),

            helpButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            addButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -6),

            countLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            countLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Reload

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else {
            stack.arrangedSubviews.forEach { v in
                stack.removeArrangedSubview(v); v.removeFromSuperview()
            }
            entryTextViews.removeAll()
            countLabel.stringValue = ""
            emptyLabel.isHidden = false
            return
        }
        let editing = view.window?.firstResponder as? NSText
        let isEditing = editing != nil
        let chatChanged = chat.id != lastChatId
        let signature = entriesSignature(chat.worldInfo)
        if !chatChanged && signature == renderedSignature { return }
        // Don't clobber a row the user is mid-typing in unless the chat actually changed.
        if isEditing && !chatChanged { return }
        lastChatId = chat.id
        renderedSignature = signature
        rebuild(chat.worldInfo)
        let total = chat.worldInfo.count
        let enabled = chat.worldInfo.filter(\.enabled).count
        countLabel.stringValue = "\(total) entr\(total == 1 ? "y" : "ies") · \(enabled) enabled"
        emptyLabel.isHidden = total > 0
    }

    private func entriesSignature(_ entries: [WorldInfoEntry]) -> String {
        var bits: [String] = []
        for e in entries {
            bits.append("\(e.id.uuidString):\(e.name):\(e.enabled):\(e.priority):\(e.tokenCap):\(e.injectionMode.rawValue):\(scopeKey(e.matchScope)):\(e.keys.joined(separator: ","))/\(e.secondaryKeys.joined(separator: ",")):\(e.content.hashValue)")
        }
        return bits.joined(separator: "|")
    }

    private func scopeKey(_ scope: WorldInfoMatchScope) -> String {
        switch scope {
        case .recentTurns(let n): return "recent(\(n))"
        case .lastUserTurn: return "lastUser"
        case .entireChat: return "entire"
        }
    }

    private func rebuild(_ entries: [WorldInfoEntry]) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v); v.removeFromSuperview()
        }
        entryTextViews.removeAll()
        for entry in entries {
            let card = makeCard(for: entry)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    // MARK: - Cards

    private func makeCard(for entry: WorldInfoEntry) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        // --- Row 1: name | enabled | delete
        let nameField = NSTextField(string: entry.name)
        nameField.font = Theme.font(13, weight: .semibold)
        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.identifier = identifier("name", entry.id)
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let enabledCheck = NSButton(checkboxWithTitle: "Enabled", target: self, action: #selector(toggleEnabled(_:)))
        enabledCheck.state = entry.enabled ? .on : .off
        enabledCheck.identifier = identifier("enabled", entry.id)
        enabledCheck.font = Theme.font(11)
        enabledCheck.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = NSButton(title: "🗑", target: self, action: #selector(deleteEntry(_:)))
        deleteBtn.bezelStyle = .circular
        deleteBtn.toolTip = "Delete entry"
        deleteBtn.identifier = identifier("delete", entry.id)
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false

        // --- Row 2: mode | scope | (n field) | priority | tokenCap
        let modePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        for m in WorldInfoInjectionMode.allCases {
            modePopup.addItem(withTitle: m.label)
            modePopup.lastItem?.representedObject = m.rawValue
        }
        modePopup.selectItem(withTitle: entry.injectionMode.label)
        modePopup.target = self
        modePopup.action = #selector(modeChanged(_:))
        modePopup.identifier = identifier("mode", entry.id)
        modePopup.translatesAutoresizingMaskIntoConstraints = false

        let scopePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        scopePopup.addItem(withTitle: "Recent turns")
        scopePopup.lastItem?.representedObject = "recent"
        scopePopup.addItem(withTitle: "Last user turn")
        scopePopup.lastItem?.representedObject = "lastUser"
        scopePopup.addItem(withTitle: "Entire chat")
        scopePopup.lastItem?.representedObject = "entire"
        switch entry.matchScope {
        case .recentTurns: scopePopup.selectItem(at: 0)
        case .lastUserTurn: scopePopup.selectItem(at: 1)
        case .entireChat: scopePopup.selectItem(at: 2)
        }
        scopePopup.target = self
        scopePopup.action = #selector(scopeChanged(_:))
        scopePopup.identifier = identifier("scope", entry.id)
        scopePopup.translatesAutoresizingMaskIntoConstraints = false

        let scopeNField = NSTextField()
        scopeNField.placeholderString = "N"
        scopeNField.font = Theme.mono(11)
        scopeNField.alignment = .right
        scopeNField.delegate = self
        scopeNField.identifier = identifier("scopeN", entry.id)
        scopeNField.translatesAutoresizingMaskIntoConstraints = false
        if case .recentTurns(let n) = entry.matchScope {
            scopeNField.integerValue = n
            scopeNField.isHidden = false
        } else {
            scopeNField.isHidden = true
        }

        let priorityLabel = NSTextField(labelWithString: "Pri")
        priorityLabel.font = Theme.font(11)
        priorityLabel.textColor = .secondaryLabelColor
        priorityLabel.translatesAutoresizingMaskIntoConstraints = false

        let priorityField = NSTextField()
        priorityField.integerValue = entry.priority
        priorityField.font = Theme.mono(11)
        priorityField.alignment = .right
        priorityField.delegate = self
        priorityField.identifier = identifier("priority", entry.id)
        priorityField.toolTip = "Higher priority entries win when the budget is exceeded."
        priorityField.translatesAutoresizingMaskIntoConstraints = false

        let capLabel = NSTextField(labelWithString: "Cap")
        capLabel.font = Theme.font(11)
        capLabel.textColor = .secondaryLabelColor
        capLabel.translatesAutoresizingMaskIntoConstraints = false

        let capField = NSTextField()
        capField.integerValue = entry.tokenCap
        capField.font = Theme.mono(11)
        capField.alignment = .right
        capField.delegate = self
        capField.identifier = identifier("cap", entry.id)
        capField.toolTip = "Token cap for this entry's content (≈ 4 chars/token)."
        capField.translatesAutoresizingMaskIntoConstraints = false

        // --- Row 3: keys
        let keysField = NSTextField(string: entry.keys.joined(separator: ", "))
        keysField.placeholderString = "Keys (comma-separated, case-insensitive, word-boundary)"
        keysField.font = Theme.font(11)
        keysField.delegate = self
        keysField.identifier = identifier("keys", entry.id)
        keysField.translatesAutoresizingMaskIntoConstraints = false

        // --- Row 4: secondary keys
        let secondaryField = NSTextField(string: entry.secondaryKeys.joined(separator: ", "))
        secondaryField.placeholderString = "Secondary keys (AND-gate; leave empty to ignore)"
        secondaryField.font = Theme.font(11)
        secondaryField.delegate = self
        secondaryField.identifier = identifier("secondary", entry.id)
        secondaryField.translatesAutoresizingMaskIntoConstraints = false

        // --- Row 5: content (multi-line)
        let contentScroll = NSScrollView()
        contentScroll.borderType = .lineBorder
        contentScroll.hasVerticalScroller = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false

        let contentView = EntryTextView()
        contentView.entryId = entry.id
        contentView.isRichText = false
        contentView.font = Theme.font(12)
        contentView.allowsUndo = true
        contentView.delegate = self
        contentView.string = entry.content
        contentView.isVerticallyResizable = true
        contentView.isHorizontallyResizable = false
        contentView.autoresizingMask = [.width]
        contentView.textContainer?.widthTracksTextView = true
        contentView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        contentView.minSize = NSSize(width: 0, height: 80)
        contentView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        contentScroll.documentView = contentView
        entryTextViews[entry.id] = contentView

        card.addSubview(nameField)
        card.addSubview(enabledCheck)
        card.addSubview(deleteBtn)
        card.addSubview(modePopup)
        card.addSubview(scopePopup)
        card.addSubview(scopeNField)
        card.addSubview(priorityLabel)
        card.addSubview(priorityField)
        card.addSubview(capLabel)
        card.addSubview(capField)
        card.addSubview(keysField)
        card.addSubview(secondaryField)
        card.addSubview(contentScroll)

        NSLayoutConstraint.activate([
            // Row 1
            nameField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            nameField.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: enabledCheck.leadingAnchor, constant: -8),

            enabledCheck.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -6),
            enabledCheck.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),

            deleteBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            deleteBtn.centerYAnchor.constraint(equalTo: nameField.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 24),
            deleteBtn.heightAnchor.constraint(equalToConstant: 22),

            // Row 2
            modePopup.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            modePopup.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 6),
            modePopup.widthAnchor.constraint(equalToConstant: 100),

            scopePopup.leadingAnchor.constraint(equalTo: modePopup.trailingAnchor, constant: 6),
            scopePopup.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
            scopePopup.widthAnchor.constraint(equalToConstant: 130),

            scopeNField.leadingAnchor.constraint(equalTo: scopePopup.trailingAnchor, constant: 4),
            scopeNField.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
            scopeNField.widthAnchor.constraint(equalToConstant: 36),

            priorityLabel.leadingAnchor.constraint(equalTo: scopeNField.trailingAnchor, constant: 8),
            priorityLabel.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),

            priorityField.leadingAnchor.constraint(equalTo: priorityLabel.trailingAnchor, constant: 2),
            priorityField.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
            priorityField.widthAnchor.constraint(equalToConstant: 40),

            capLabel.leadingAnchor.constraint(equalTo: priorityField.trailingAnchor, constant: 8),
            capLabel.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),

            capField.leadingAnchor.constraint(equalTo: capLabel.trailingAnchor, constant: 2),
            capField.centerYAnchor.constraint(equalTo: modePopup.centerYAnchor),
            capField.widthAnchor.constraint(equalToConstant: 56),
            capField.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -8),

            // Row 3
            keysField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            keysField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            keysField.topAnchor.constraint(equalTo: modePopup.bottomAnchor, constant: 6),

            // Row 4
            secondaryField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            secondaryField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            secondaryField.topAnchor.constraint(equalTo: keysField.bottomAnchor, constant: 4),

            // Row 5
            contentScroll.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            contentScroll.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            contentScroll.topAnchor.constraint(equalTo: secondaryField.bottomAnchor, constant: 6),
            contentScroll.heightAnchor.constraint(equalToConstant: 100),
            contentScroll.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        return card
    }

    // MARK: - Identifier helpers

    private func identifier(_ kind: String, _ id: UUID) -> NSUserInterfaceItemIdentifier {
        NSUserInterfaceItemIdentifier("\(kind):\(id.uuidString)")
    }

    private func decodeId(_ ident: NSUserInterfaceItemIdentifier?) -> (kind: String, id: UUID)? {
        guard let raw = ident?.rawValue else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let id = UUID(uuidString: parts[1]) else { return nil }
        return (parts[0], id)
    }

    // MARK: - Actions

    @objc private func addEntry() {
        AppState.shared.updateCurrent { c in
            c.worldInfo.append(WorldInfoEntry(name: "New entry"))
        }
    }

    @objc private func deleteEntry(_ sender: NSButton) {
        guard let (_, id) = decodeId(sender.identifier) else { return }
        AppState.shared.updateCurrent { c in
            c.worldInfo.removeAll { $0.id == id }
        }
    }

    @objc private func toggleEnabled(_ sender: NSButton) {
        guard let (_, id) = decodeId(sender.identifier) else { return }
        let on = sender.state == .on
        AppState.shared.updateCurrent { c in
            if let i = c.worldInfo.firstIndex(where: { $0.id == id }) {
                c.worldInfo[i].enabled = on
            }
        }
    }

    @objc private func modeChanged(_ sender: NSPopUpButton) {
        guard let (_, id) = decodeId(sender.identifier),
              let raw = sender.selectedItem?.representedObject as? String,
              let mode = WorldInfoInjectionMode(rawValue: raw) else { return }
        AppState.shared.updateCurrent { c in
            if let i = c.worldInfo.firstIndex(where: { $0.id == id }) {
                c.worldInfo[i].injectionMode = mode
            }
        }
    }

    @objc private func scopeChanged(_ sender: NSPopUpButton) {
        guard let (_, id) = decodeId(sender.identifier),
              let raw = sender.selectedItem?.representedObject as? String else { return }
        AppState.shared.updateCurrent { c in
            if let i = c.worldInfo.firstIndex(where: { $0.id == id }) {
                let existingN: Int = {
                    if case .recentTurns(let n) = c.worldInfo[i].matchScope { return n }
                    return 4
                }()
                switch raw {
                case "recent":    c.worldInfo[i].matchScope = .recentTurns(existingN)
                case "lastUser":  c.worldInfo[i].matchScope = .lastUserTurn
                case "entire":    c.worldInfo[i].matchScope = .entireChat
                default: break
                }
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let (kind, id) = decodeId(field.identifier) else { return }
        let raw = field.stringValue
        AppState.shared.updateCurrent { c in
            guard let i = c.worldInfo.firstIndex(where: { $0.id == id }) else { return }
            switch kind {
            case "name":
                let trimmed = raw.trimmingCharacters(in: .whitespaces)
                c.worldInfo[i].name = trimmed.isEmpty ? "Untitled" : trimmed
            case "keys":
                c.worldInfo[i].keys = splitKeys(raw)
            case "secondary":
                c.worldInfo[i].secondaryKeys = splitKeys(raw)
            case "priority":
                c.worldInfo[i].priority = field.integerValue
            case "cap":
                c.worldInfo[i].tokenCap = max(0, field.integerValue)
            case "scopeN":
                let n = max(0, field.integerValue)
                c.worldInfo[i].matchScope = .recentTurns(n)
            default: break
            }
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        guard let tv = notification.object as? EntryTextView,
              let id = tv.entryId else { return }
        let value = tv.string
        AppState.shared.updateCurrent { c in
            if let i = c.worldInfo.firstIndex(where: { $0.id == id }) {
                c.worldInfo[i].content = value
            }
        }
    }

    private func splitKeys(_ raw: String) -> [String] {
        raw.components(separatedBy: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

/// NSTextView subclass that carries the world-info entry id, used to route
/// edit notifications back to the right entry.
private final class EntryTextView: NSTextView {
    var entryId: UUID?
}
