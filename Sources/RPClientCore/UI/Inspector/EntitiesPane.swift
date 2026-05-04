import AppKit

/// Inspector pane for the structured entity store (Step C).
/// Renders a flat list of entity cards, each with its facts as nested rows.
/// Edits flow through `AppState.updateChat` so the prompt-builder picks up
/// changes on the next send.
final class EntitiesPane: NSViewController, NSTextFieldDelegate {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let helpLabel = NSTextField(labelWithString: "Structured entities. Only entities mentioned in recent turns are injected into the prompt.")
    private let helpButton = HelpButton(pageId: "memory-entities")
    private let countLabel = NSTextField(labelWithString: "")
    private let searchField = NSSearchField()
    private let addButton = NSButton(title: "+ Add entity", target: nil, action: nil)
    private let emptyLabel = NSTextField(labelWithString: "No entities yet. Promote a suggestion or click + Add entity.")

    private var lastChatId: UUID?
    private var renderedSignature: String = ""
    private var query: String = ""

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

        searchField.placeholderString = "Search entities…"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(searchField)

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
        addButton.action = #selector(addEntity)
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

            searchField.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            searchField.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
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

    @objc private func searchChanged() {
        query = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        renderedSignature = "" // force rebuild
        reload()
    }

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else {
            stack.arrangedSubviews.forEach { v in
                stack.removeArrangedSubview(v); v.removeFromSuperview()
            }
            countLabel.stringValue = ""
            emptyLabel.isHidden = false
            return
        }
        let editing = view.window?.firstResponder as? NSText
        let isEditing = editing?.delegate is NSTextField
        let chatChanged = chat.id != lastChatId
        let userTurns = chat.turns.filter { $0.role == .user }.count
        let visible = filtered(chat.entities)
        let signature = entitiesSignature(visible, currentUserTurn: userTurns)
        if !chatChanged && signature == renderedSignature { return }
        // Don't clobber a row the user is mid-typing in unless chat actually changed.
        if isEditing && !chatChanged { return }
        lastChatId = chat.id
        renderedSignature = signature
        rebuild(visible, currentUserTurn: userTurns)
        let total = chat.entities.count
        let factCount = chat.entities.reduce(0) { $0 + $1.facts.count }
        countLabel.stringValue = "\(total) entit\(total == 1 ? "y" : "ies") · \(factCount) fact\(factCount == 1 ? "" : "s")"
        emptyLabel.isHidden = total > 0
        emptyLabel.stringValue = total == 0
            ? "No entities yet. Promote a suggestion or click + Add entity."
            : "No matches for \"\(query)\"."
        emptyLabel.isHidden = !visible.isEmpty
    }

    private func filtered(_ all: [Entity]) -> [Entity] {
        guard !query.isEmpty else { return all }
        return all.filter { ent in
            if ent.name.lowercased().contains(query) { return true }
            if ent.aliases.contains(where: { $0.lowercased().contains(query) }) { return true }
            if ent.type.rawValue.contains(query) { return true }
            if ent.facts.contains(where: { $0.text.lowercased().contains(query) }) { return true }
            return false
        }
    }

    private func entitiesSignature(_ entities: [Entity], currentUserTurn: Int) -> String {
        // Includes salience fields and the current user-turn so the pane
        // rebuilds when heat decays after a fresh send, not only on edits.
        var bits: [String] = ["t=\(currentUserTurn)"]
        for ent in entities {
            bits.append("\(ent.id.uuidString):\(ent.name):\(ent.type.rawValue):\(ent.pinnedByUser):\(ent.aliases.joined(separator: ","))")
            for f in ent.facts {
                bits.append(" \(f.id.uuidString):\(f.text):\(f.lastReinforcedTurn):\(f.mentionCount):\(f.pinnedByUser)")
            }
        }
        return bits.joined(separator: "|")
    }

    private func rebuild(_ entities: [Entity], currentUserTurn: Int) {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v); v.removeFromSuperview()
        }
        for ent in entities {
            let card = makeCard(for: ent, currentUserTurn: currentUserTurn)
            stack.addArrangedSubview(card)
            card.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -8).isActive = true
        }
    }

    // MARK: - Cards

    private func makeCard(for ent: Entity, currentUserTurn: Int) -> NSView {
        let card = NSView()
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        card.layer?.cornerRadius = 6
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.separatorColor.cgColor
        card.translatesAutoresizingMaskIntoConstraints = false

        let typePopup = NSPopUpButton(frame: .zero, pullsDown: false)
        typePopup.translatesAutoresizingMaskIntoConstraints = false
        for t in EntityType.allCases {
            typePopup.addItem(withTitle: t.label)
            typePopup.lastItem?.representedObject = t.rawValue
        }
        typePopup.selectItem(withTitle: ent.type.label)
        typePopup.identifier = NSUserInterfaceItemIdentifier(ent.id.uuidString)
        typePopup.target = self
        typePopup.action = #selector(typeChanged(_:))

        let nameField = NSTextField(string: ent.name)
        nameField.font = Theme.font(13, weight: .semibold)
        nameField.isBezeled = false
        nameField.drawsBackground = false
        nameField.placeholderString = "Name"
        nameField.delegate = self
        nameField.identifier = NSUserInterfaceItemIdentifier("name:\(ent.id.uuidString)")
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let pinCheck = NSButton(checkboxWithTitle: "pinned", target: self, action: #selector(togglePin(_:)))
        pinCheck.font = Theme.font(10)
        pinCheck.state = ent.pinnedByUser ? .on : .off
        pinCheck.identifier = NSUserInterfaceItemIdentifier(ent.id.uuidString)
        pinCheck.toolTip = "Pinned entities resist auto-eviction"
        pinCheck.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = NSButton(title: "🗑", target: self, action: #selector(deleteEntity(_:)))
        deleteBtn.bezelStyle = .circular
        deleteBtn.toolTip = "Delete entity"
        deleteBtn.identifier = NSUserInterfaceItemIdentifier(ent.id.uuidString)
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false

        let aliasesField = NSTextField(string: ent.aliases.joined(separator: ", "))
        aliasesField.font = Theme.font(11)
        aliasesField.placeholderString = "Aliases (comma-separated, used for keyword matching)"
        aliasesField.delegate = self
        aliasesField.identifier = NSUserInterfaceItemIdentifier("aliases:\(ent.id.uuidString)")
        aliasesField.translatesAutoresizingMaskIntoConstraints = false

        let factsStack = NSStackView()
        factsStack.orientation = .vertical
        factsStack.spacing = 2
        factsStack.alignment = .leading
        factsStack.translatesAutoresizingMaskIntoConstraints = false

        for fact in ent.facts {
            let row = makeFactRow(entityId: ent.id, fact: fact, currentUserTurn: currentUserTurn)
            factsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: factsStack.widthAnchor).isActive = true
        }

        let addFactBtn = NSButton(title: "+ Add fact", target: self, action: #selector(addFact(_:)))
        addFactBtn.bezelStyle = .inline
        addFactBtn.font = Theme.font(11)
        addFactBtn.identifier = NSUserInterfaceItemIdentifier(ent.id.uuidString)
        addFactBtn.translatesAutoresizingMaskIntoConstraints = false

        card.addSubview(typePopup)
        card.addSubview(nameField)
        card.addSubview(pinCheck)
        card.addSubview(deleteBtn)
        card.addSubview(aliasesField)
        card.addSubview(factsStack)
        card.addSubview(addFactBtn)

        NSLayoutConstraint.activate([
            typePopup.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            typePopup.topAnchor.constraint(equalTo: card.topAnchor, constant: 8),
            typePopup.widthAnchor.constraint(equalToConstant: 110),

            nameField.leadingAnchor.constraint(equalTo: typePopup.trailingAnchor, constant: 6),
            nameField.centerYAnchor.constraint(equalTo: typePopup.centerYAnchor),
            nameField.trailingAnchor.constraint(equalTo: pinCheck.leadingAnchor, constant: -6),

            pinCheck.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -6),
            pinCheck.centerYAnchor.constraint(equalTo: typePopup.centerYAnchor),

            deleteBtn.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            deleteBtn.centerYAnchor.constraint(equalTo: typePopup.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 24),
            deleteBtn.heightAnchor.constraint(equalToConstant: 22),

            aliasesField.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            aliasesField.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            aliasesField.topAnchor.constraint(equalTo: typePopup.bottomAnchor, constant: 6),

            factsStack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            factsStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -8),
            factsStack.topAnchor.constraint(equalTo: aliasesField.bottomAnchor, constant: 6),

            addFactBtn.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 8),
            addFactBtn.topAnchor.constraint(equalTo: factsStack.bottomAnchor, constant: 4),
            addFactBtn.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -8)
        ])
        return card
    }

    /// Salience styling thresholds. "Hot" facts were reinforced this turn or
    /// last; "stale" facts haven't been reinforced for ~15+ user turns (or
    /// never). Mid-range facts render normally.
    private static let hotLagThreshold = 1
    private static let staleLagThreshold = 15

    private func makeFactRow(entityId: UUID, fact: Fact, currentUserTurn: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let lag = max(0, currentUserTurn - fact.lastReinforcedTurn)
        let isHot = fact.lastReinforcedTurn > 0 && lag <= Self.hotLagThreshold
        let isStale = fact.lastReinforcedTurn == 0
            ? fact.addedTurn > 0 && (currentUserTurn - fact.addedTurn) > Self.staleLagThreshold
            : lag > Self.staleLagThreshold
        let normalColor: NSColor = isStale ? .tertiaryLabelColor : .labelColor

        let bullet = NSTextField(labelWithString: isHot ? "●" : "•")
        bullet.font = Theme.font(12)
        bullet.textColor = isHot
            ? .systemOrange
            : (isStale ? .quaternaryLabelColor : .tertiaryLabelColor)
        bullet.translatesAutoresizingMaskIntoConstraints = false

        let textField = NSTextField(string: fact.text)
        textField.font = isHot ? Theme.font(12, weight: .semibold) : Theme.font(12)
        textField.textColor = fact.pinnedByUser ? .labelColor : normalColor
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.lineBreakMode = .byWordWrapping
        textField.maximumNumberOfLines = 0
        textField.delegate = self
        textField.identifier = NSUserInterfaceItemIdentifier("fact:\(entityId.uuidString):\(fact.id.uuidString)")
        textField.translatesAutoresizingMaskIntoConstraints = false

        let metaText: String = {
            let mc = "×\(fact.mentionCount)"
            let recency: String
            if fact.lastReinforcedTurn == 0 {
                recency = "—"
            } else if lag == 0 {
                recency = "now"
            } else {
                recency = "Δ\(lag)"
            }
            return "\(mc) · \(recency)"
        }()
        let metaLabel = NSTextField(labelWithString: metaText)
        metaLabel.font = Theme.mono(10)
        metaLabel.textColor = isHot ? .secondaryLabelColor : .tertiaryLabelColor
        metaLabel.toolTip = "mentions × last-reinforced (Δ = user turns since)"
        metaLabel.translatesAutoresizingMaskIntoConstraints = false

        let pinCheck = NSButton(checkboxWithTitle: "", target: self, action: #selector(togglePinFact(_:)))
        pinCheck.state = fact.pinnedByUser ? .on : .off
        pinCheck.toolTip = "Pin this fact (immune from eviction)"
        pinCheck.identifier = NSUserInterfaceItemIdentifier("pin:\(entityId.uuidString):\(fact.id.uuidString)")
        pinCheck.translatesAutoresizingMaskIntoConstraints = false

        let removeBtn = NSButton(title: "×", target: self, action: #selector(removeFact(_:)))
        removeBtn.bezelStyle = .circular
        removeBtn.toolTip = "Remove fact"
        removeBtn.identifier = NSUserInterfaceItemIdentifier("rm:\(entityId.uuidString):\(fact.id.uuidString)")
        removeBtn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(bullet)
        row.addSubview(textField)
        row.addSubview(metaLabel)
        row.addSubview(pinCheck)
        row.addSubview(removeBtn)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 22),

            bullet.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            bullet.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),

            textField.leadingAnchor.constraint(equalTo: bullet.trailingAnchor, constant: 4),
            textField.topAnchor.constraint(equalTo: row.topAnchor, constant: 2),
            textField.bottomAnchor.constraint(equalTo: row.bottomAnchor, constant: -2),
            textField.trailingAnchor.constraint(equalTo: metaLabel.leadingAnchor, constant: -6),

            metaLabel.trailingAnchor.constraint(equalTo: pinCheck.leadingAnchor, constant: -4),
            metaLabel.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

            pinCheck.trailingAnchor.constraint(equalTo: removeBtn.leadingAnchor, constant: -2),
            pinCheck.centerYAnchor.constraint(equalTo: textField.centerYAnchor),

            removeBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            removeBtn.centerYAnchor.constraint(equalTo: textField.centerYAnchor),
            removeBtn.widthAnchor.constraint(equalToConstant: 22),
            removeBtn.heightAnchor.constraint(equalToConstant: 20)
        ])
        return row
    }

    // MARK: - Actions

    private func entityId(from sender: AnyObject) -> UUID? {
        guard let id = (sender as? NSView)?.identifier?.rawValue
                ?? (sender as? NSControl)?.identifier?.rawValue else { return nil }
        return UUID(uuidString: id)
    }

    @objc private func addEntity() {
        let userTurns = AppState.shared.currentChat?.turns.filter { $0.role == .user }.count ?? 0
        AppState.shared.updateCurrent { c in
            c.entities.append(Entity(
                name: "New entity",
                type: .character,
                facts: [],
                pinnedByUser: true,
                createdTurn: userTurns
            ))
        }
    }

    @objc private func deleteEntity(_ sender: NSButton) {
        guard let id = entityId(from: sender) else { return }
        AppState.shared.updateCurrent { c in
            c.entities.removeAll { $0.id == id }
        }
    }

    @objc private func typeChanged(_ sender: NSPopUpButton) {
        guard let id = entityId(from: sender),
              let raw = sender.selectedItem?.representedObject as? String,
              let t = EntityType(rawValue: raw) else { return }
        AppState.shared.updateCurrent { c in
            if let i = c.entities.firstIndex(where: { $0.id == id }) {
                c.entities[i].type = t
            }
        }
    }

    @objc private func togglePin(_ sender: NSButton) {
        guard let id = entityId(from: sender) else { return }
        let on = sender.state == .on
        AppState.shared.updateCurrent { c in
            if let i = c.entities.firstIndex(where: { $0.id == id }) {
                c.entities[i].pinnedByUser = on
            }
        }
    }

    @objc private func addFact(_ sender: NSButton) {
        guard let id = entityId(from: sender) else { return }
        let userTurns = AppState.shared.currentChat?.turns.filter { $0.role == .user }.count ?? 0
        AppState.shared.updateCurrent { c in
            if let i = c.entities.firstIndex(where: { $0.id == id }) {
                c.entities[i].facts.append(Fact(
                    text: "",
                    addedTurn: userTurns,
                    lastReinforcedTurn: userTurns
                ))
            }
        }
    }

    /// Identifier shape: `<verb>:<entityId>:<factId>`. Cheaper than dragging
    /// two-tuple identifiers around through NSControl.
    private func decodeFactId(from sender: NSControl) -> (UUID, UUID)? {
        guard let raw = sender.identifier?.rawValue else { return nil }
        let parts = raw.split(separator: ":")
        guard parts.count == 3,
              let e = UUID(uuidString: String(parts[1])),
              let f = UUID(uuidString: String(parts[2])) else { return nil }
        return (e, f)
    }

    @objc private func removeFact(_ sender: NSButton) {
        guard let (eid, fid) = decodeFactId(from: sender) else { return }
        AppState.shared.updateCurrent { c in
            if let i = c.entities.firstIndex(where: { $0.id == eid }) {
                c.entities[i].facts.removeAll { $0.id == fid }
            }
        }
    }

    @objc private func togglePinFact(_ sender: NSButton) {
        guard let (eid, fid) = decodeFactId(from: sender) else { return }
        let on = sender.state == .on
        AppState.shared.updateCurrent { c in
            if let ei = c.entities.firstIndex(where: { $0.id == eid }),
               let fi = c.entities[ei].facts.firstIndex(where: { $0.id == fid }) {
                c.entities[ei].facts[fi].pinnedByUser = on
            }
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField,
              let raw = field.identifier?.rawValue else { return }
        let parts = raw.split(separator: ":")
        guard let kind = parts.first else { return }
        if kind == "name", parts.count == 2,
           let id = UUID(uuidString: String(parts[1])) {
            let value = field.stringValue.trimmingCharacters(in: .whitespaces)
            AppState.shared.updateCurrent { c in
                if let i = c.entities.firstIndex(where: { $0.id == id }) {
                    c.entities[i].name = value.isEmpty ? "Unnamed" : value
                }
            }
        } else if kind == "aliases", parts.count == 2,
                  let id = UUID(uuidString: String(parts[1])) {
            let aliases = field.stringValue
                .components(separatedBy: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            AppState.shared.updateCurrent { c in
                if let i = c.entities.firstIndex(where: { $0.id == id }) {
                    c.entities[i].aliases = aliases
                }
            }
        } else if kind == "fact", parts.count == 3,
                  let eid = UUID(uuidString: String(parts[1])),
                  let fid = UUID(uuidString: String(parts[2])) {
            let value = field.stringValue
            AppState.shared.updateCurrent { c in
                if let ei = c.entities.firstIndex(where: { $0.id == eid }),
                   let fi = c.entities[ei].facts.firstIndex(where: { $0.id == fid }) {
                    c.entities[ei].facts[fi].text = value
                }
            }
        }
    }
}
