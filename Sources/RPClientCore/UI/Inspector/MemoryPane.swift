import AppKit

/// Inspector pane showing pinned memory as a row-per-fact list with add /
/// remove controls. Internally still serialises to `chat.memory` as a single
/// newline-joined string so PromptBuilder, the tail-reinforce digest, and the
/// fact extractor's "Already known" block all keep working unchanged.
final class MemoryPane: NSViewController, NSTextFieldDelegate {
    private let scrollView = NSScrollView()
    private let factsStack = NSStackView()
    private let addButton = NSButton(title: "+ Add fact", target: nil, action: nil)
    private let tokenLabel = NSTextField(labelWithString: "0 / 800 tok")
    private let helpLabel = NSTextField(labelWithString: "Pinned facts. Always injected near the top of the prompt.")
    private let helpButton = HelpButton(pageId: "memory-pinned-facts")
    private let reinforceCheck = NSButton(checkboxWithTitle: "Reinforce in latest user turn (counters drift on long Gemma chats)", target: nil, action: nil)

    /// Read-only display of the card's description/personality/scenario when
    /// the chat is bound to a Character. Lives just above the editable facts
    /// list so it's clear those lines are *also* memory but not user-owned.
    /// Hidden when no character is attached. See V2_PLAN §4.4 step 4g.
    private let cardSection = NSStackView()
    private let cardBadge = NSTextField(labelWithString: "From card (read-only)")
    private let cardTextScroll = NSScrollView()
    private let cardTextView = NSTextView()

    /// Per-chat picker for `Chat.systemPromptMode`. Hidden when no character
    /// is attached because the toggle is meaningless without a card-supplied
    /// `system_prompt`.
    private let modeSection = NSStackView()
    private let modeLabel = NSTextField(labelWithString: "system_prompt:")
    private let modePicker = NSSegmentedControl(
        labels: ["Override", "Merge"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )

    private var tokenCountTimer: DispatchWorkItem?
    private var lastChatId: UUID?
    private var facts: [String] = []

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

        // Card section (4g) — read-only display of the card's
        // description/personality/scenario. NSStackView so toggling
        // `isHidden` collapses it cleanly when no character is attached.
        cardBadge.font = Theme.font(10)
        cardBadge.textColor = .secondaryLabelColor
        cardBadge.translatesAutoresizingMaskIntoConstraints = false

        cardTextView.isEditable = false
        cardTextView.isSelectable = true
        cardTextView.drawsBackground = true
        cardTextView.backgroundColor = NSColor.windowBackgroundColor
        cardTextView.textContainerInset = NSSize(width: 6, height: 6)
        cardTextView.font = Theme.font(11)
        cardTextView.textColor = .secondaryLabelColor
        cardTextView.isVerticallyResizable = true
        cardTextView.isHorizontallyResizable = false
        cardTextView.autoresizingMask = [.width]
        cardTextView.textContainer?.widthTracksTextView = true

        cardTextScroll.documentView = cardTextView
        cardTextScroll.hasVerticalScroller = true
        cardTextScroll.borderType = .lineBorder
        cardTextScroll.translatesAutoresizingMaskIntoConstraints = false
        cardTextScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true

        cardSection.orientation = .vertical
        cardSection.alignment = .leading
        cardSection.spacing = 2
        cardSection.translatesAutoresizingMaskIntoConstraints = false
        cardSection.addArrangedSubview(cardBadge)
        cardSection.addArrangedSubview(cardTextScroll)
        cardTextScroll.widthAnchor.constraint(equalTo: cardSection.widthAnchor).isActive = true
        v.addSubview(cardSection)

        // Mode section (4g) — override/merge picker for systemPromptMode.
        modeLabel.font = Theme.font(11)
        modeLabel.textColor = .secondaryLabelColor
        modePicker.target = self
        modePicker.action = #selector(modeChanged)
        // Match the existing pane's segmented controls (small/control-sized).
        modePicker.controlSize = .small
        modePicker.font = Theme.font(11)

        modeSection.orientation = .horizontal
        modeSection.alignment = .centerY
        modeSection.spacing = 6
        modeSection.translatesAutoresizingMaskIntoConstraints = false
        modeSection.addArrangedSubview(modeLabel)
        modeSection.addArrangedSubview(modePicker)
        v.addSubview(modeSection)

        factsStack.orientation = .vertical
        factsStack.spacing = 4
        factsStack.alignment = .leading
        factsStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        factsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = factsStack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        // Pin stack width to the scroll view's content width so rows have a
        // real horizontal extent — without this, rows collapse to zero width.
        factsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        addButton.target = self
        addButton.action = #selector(addFact)
        addButton.bezelStyle = .rounded
        addButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(addButton)

        tokenLabel.font = Theme.mono(11)
        tokenLabel.textColor = .secondaryLabelColor
        tokenLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(tokenLabel)

        reinforceCheck.font = Theme.font(11)
        reinforceCheck.target = self
        reinforceCheck.action = #selector(toggleReinforce)
        reinforceCheck.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(reinforceCheck)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),

            helpButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            cardSection.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            cardSection.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            cardSection.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            modeSection.topAnchor.constraint(equalTo: cardSection.bottomAnchor, constant: 6),
            modeSection.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            modeSection.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: modeSection.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -6),

            addButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            addButton.bottomAnchor.constraint(equalTo: reinforceCheck.topAnchor, constant: -8),

            reinforceCheck.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            reinforceCheck.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -10),
            reinforceCheck.bottomAnchor.constraint(equalTo: tokenLabel.topAnchor, constant: -6),

            tokenLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            tokenLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        helpLabel.font = Theme.font(11)
        tokenLabel.font = Theme.mono(11)
        reinforceCheck.font = Theme.font(11)
        for view in factsStack.arrangedSubviews {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                field.font = Theme.font(12)
            }
        }
    }

    // MARK: - Reload / sync with chat

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else {
            facts = []
            rebuildFactsUI()
            tokenLabel.stringValue = ""
            reinforceCheck.state = .off
            cardSection.isHidden = true
            modeSection.isHidden = true
            return
        }
        // External update detection — only rebuild if memory actually changed.
        // Without this, every chatUpdated would clobber a row the user is
        // currently typing into.
        let chatChanged = chat.id != lastChatId
        let editingField = view.window?.firstResponder as? NSText
        let currentlyEditing = editingField?.delegate is NSTextField
        let memoryDiffers = parse(chat.memory) != facts

        if chatChanged || (memoryDiffers && !currentlyEditing) {
            lastChatId = chat.id
            facts = parse(chat.memory)
            rebuildFactsUI()
            scheduleTokenCount()
        }
        reinforceCheck.state = chat.tailReinforceMemory ? .on : .off
        updateTokenLabel(localCount: chat.memory)
        refreshCardSection(chat: chat)
    }

    /// Pull the current character (if any) and populate the read-only "from
    /// card" text view + the systemPromptMode picker. Hides both sections
    /// when no character is attached. Reads live from `AppState.character`
    /// so card edits propagate without writing the data into the chat.
    private func refreshCardSection(chat: Chat) {
        guard let card = AppState.shared.character(id: chat.characterId) else {
            cardSection.isHidden = true
            modeSection.isHidden = true
            return
        }
        // Render exactly the same body the prompt sees, minus the framing
        // header (the user already knows what they're looking at — the badge
        // says "From card"). Empty fields are dropped.
        let pieces: [(String, String)] = [
            ("Description", card.description),
            ("Personality", card.personality),
            ("Scenario", card.scenario),
        ]
        let body = pieces
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n\n")

        if body.isEmpty {
            cardSection.isHidden = true
        } else {
            cardSection.isHidden = false
            cardTextView.string = body
            cardBadge.stringValue = "From card (read-only) · \(card.name)"
        }

        modeSection.isHidden = false
        modePicker.selectedSegment = chat.systemPromptMode == .merge ? 1 : 0
    }

    @objc private func modeChanged() {
        let mode: CardPromptMode = modePicker.selectedSegment == 1 ? .merge : .override
        AppState.shared.updateCurrent { c in
            c.systemPromptMode = mode
        }
    }

    /// Split memory text into individual fact rows. Blank lines are dropped;
    /// trailing whitespace trimmed per line so casual edits don't create
    /// phantom whitespace rows.
    private func parse(_ memory: String) -> [String] {
        memory.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// Rejoin the in-memory `facts` array into the canonical `\n`-joined string
    /// and persist via AppState. Empty trailing rows (e.g. user just pressed
    /// Add but hasn't typed) are kept locally so the row stays editable, but
    /// dropped from the persisted string so they don't accumulate as blanks.
    private func save() {
        guard let id = lastChatId else { return }
        let serialised = facts
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
        AppState.shared.updateChat(id: id) { c in
            c.memory = serialised
        }
        scheduleTokenCount()
    }

    // MARK: - Row UI

    private func rebuildFactsUI() {
        for v in factsStack.arrangedSubviews { factsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (idx, fact) in facts.enumerated() {
            let row = makeRow(text: fact, index: idx)
            factsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: factsStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(text: String, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: text)
        field.placeholderString = "fact"
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
        field.action = #selector(fieldCommitted(_:))

        let remove = NSButton(title: "×", target: self, action: #selector(removeFact(_:)))
        remove.tag = index
        remove.bezelStyle = .circular
        remove.toolTip = "Remove this fact"
        remove.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(field)
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),

            field.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            field.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -6),

            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            remove.widthAnchor.constraint(equalToConstant: 24),
            remove.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    private func commitFactsFromUI() {
        for (idx, view) in factsStack.arrangedSubviews.enumerated() where idx < facts.count {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                facts[idx] = field.stringValue
            }
        }
    }

    @objc private func addFact() {
        commitFactsFromUI()
        facts.append("")
        rebuildFactsUI()
        // Don't save yet — empty row would just get filtered. Wait for type.
        if let lastField = factsStack.arrangedSubviews.last?
            .subviews.compactMap({ $0 as? NSTextField }).first {
            view.window?.makeFirstResponder(lastField)
        }
    }

    @objc private func removeFact(_ sender: NSButton) {
        commitFactsFromUI()
        let idx = sender.tag
        guard facts.indices.contains(idx) else { return }
        facts.remove(at: idx)
        rebuildFactsUI()
        save()
    }

    @objc private func fieldCommitted(_ sender: NSTextField) {
        let idx = sender.tag
        guard facts.indices.contains(idx) else { return }
        facts[idx] = sender.stringValue
        save()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        guard let field = obj.object as? NSTextField else { return }
        let idx = field.tag
        guard facts.indices.contains(idx) else { return }
        facts[idx] = field.stringValue
        save()
    }

    @objc private func toggleReinforce() {
        let on = reinforceCheck.state == .on
        AppState.shared.updateCurrent { c in
            c.tailReinforceMemory = on
        }
    }

    // MARK: - Token count

    private func updateTokenLabel(localCount text: String) {
        guard let chat = AppState.shared.currentChat else { return }
        let cap = chat.memoryTokenCap
        let approx = max(0, text.count / 4)
        tokenLabel.stringValue = "≈ \(approx) / \(cap) tok · \(facts.count) fact\(facts.count == 1 ? "" : "s")"
        tokenLabel.textColor = .secondaryLabelColor
    }

    private func scheduleTokenCount() {
        tokenCountTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.fetchTokenCount()
        }
        tokenCountTimer = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
        if let chat = AppState.shared.currentChat {
            updateTokenLabel(localCount: chat.memory)
        }
    }

    private func fetchTokenCount() {
        guard let chat = AppState.shared.currentChat else { return }
        let text = chat.memory
        let cap = chat.memoryTokenCap
        let count = facts.count
        guard !text.isEmpty else {
            tokenLabel.stringValue = "0 / \(cap) tok · \(count) fact\(count == 1 ? "" : "s")"
            return
        }
        AppState.shared.kobold.tokenCount(text: text) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self,
                      case .success(let n) = result,
                      let chat = AppState.shared.currentChat else { return }
                let cap = chat.memoryTokenCap
                let count = self.facts.count
                self.tokenLabel.stringValue = "\(n) / \(cap) tok · \(count) fact\(count == 1 ? "" : "s")"
                self.tokenLabel.textColor = n > cap ? .systemRed : .secondaryLabelColor
            }
        }
    }
}
