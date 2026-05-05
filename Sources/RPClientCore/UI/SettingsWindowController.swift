import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    // Servers (Phase 4 §5.3) — list of koboldcpp profiles + role assignment.
    private var serversDraft: [ServerProfile] = []
    private var defaultServerIdDraft: UUID = UUID()
    private var summarizerServerIdDraft: UUID?
    private var extractorServerIdDraft: UUID?
    private var embeddingsServerIdDraft: UUID?
    private let serversScroll = NSScrollView()
    private let serversStack = NSStackView()
    private let addServerButton = NSButton(title: "+ Add server", target: nil, action: nil)
    private let defaultServerPopup = NSPopUpButton()
    private let summarizerServerPopup = NSPopUpButton()
    private let extractorServerPopup = NSPopUpButton()
    private let embeddingsServerPopup = NSPopUpButton()
    /// Probe status per profile id, refreshed by Test buttons. Persisted on
    /// save so the dot reflects the last-probed state across opens.
    private var probeStatusDraft: [UUID: String] = [:]

    private let userNameField = NSTextField()
    private let templatePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let personaPopup = NSPopUpButton()
    private let voiceCheck = NSButton(checkboxWithTitle: "Enable voice subsystem", target: nil, action: nil)
    private let qwenThinkingCheck = NSButton(
        checkboxWithTitle: "Qwen 3: enable thinking mode (strips <think>…</think> from replies)",
        target: nil, action: nil)
    private let ctxField = NSTextField()

    // Retrieval
    private let retrievalCheck = NSButton(
        checkboxWithTitle: "Enable vector retrieval (requires --embeddingsmodel on the server)",
        target: nil, action: nil)
    private let topKField = NSTextField()
    private let thresholdField = NSTextField()
    private let recencyField = NSTextField()

    // Appearance
    private let fontOffsetStepper = NSStepper()
    private let fontOffsetField = NSTextField()

    // Generation
    private let replyTokensStepper = NSStepper()
    private let replyTokensField = NSTextField()

    // Memory
    private let factExtractCheck = NSButton(
        checkboxWithTitle: "Auto-extract fact suggestions after every N user turns",
        target: nil, action: nil)
    private let factExtractStepper = NSStepper()
    private let factExtractField = NSTextField()
    private let libraryScroll = NSScrollView()
    private let libraryStack = NSStackView()
    private let libraryAddButton = NSButton(title: "+ Add preset", target: nil, action: nil)
    private var libraryDraft: [LibraryTopic] = []

    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 720),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 520, height: 360)
        w.title = "Settings"
        self.init(window: w)
        w.delegate = self
        buildUI()
        loadValues()
    }

    override func showWindow(_ sender: Any?) {
        // The controller is cached in AppDelegate, so subsequent opens must
        // re-pull from AppState — otherwise edits made elsewhere (e.g. "Save
        // active topics to library" from the Extraction pane) don't appear.
        loadValues()
        super.showWindow(sender)
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        let serversHeader = NSTextField(labelWithString: "Servers")
        serversHeader.font = Theme.bold(12)
        let serversHelp = NSTextField(wrappingLabelWithString: "Each server is a koboldcpp endpoint. Use Default for chat generation; route side-calls (summary, extraction, embeddings) to a different server to keep the chat path snappy while a beefier model handles memory upkeep.")
        serversHelp.font = Theme.font(10)
        serversHelp.textColor = .secondaryLabelColor
        serversHelp.translatesAutoresizingMaskIntoConstraints = false

        let userNameLabel = NSTextField(labelWithString: "Your name:")
        let templateLabel = NSTextField(labelWithString: "Default template:")
        let presetLabel = NSTextField(labelWithString: "Default sampler preset:")
        let personaLabel = NSTextField(labelWithString: "Default persona:")
        let ctxLabel = NSTextField(labelWithString: "Max context (0 = server max):")
        let appearanceHeader = NSTextField(labelWithString: "Appearance")
        appearanceHeader.font = Theme.bold(12)
        let fontOffsetLabel = NSTextField(labelWithString: "UI font size adjust:")
        let replyTokensLabel = NSTextField(labelWithString: "Reply token cap (0 = preset):")
        let memoryHeader = NSTextField(labelWithString: "Memory (fact extraction)")
        memoryHeader.font = Theme.bold(12)
        let factExtractLabel = NSTextField(labelWithString: "Run every N user turns:")
        let libraryLabel = NSTextField(labelWithString: "Priority topic library:")
        let libraryHelp = NSTextField(wrappingLabelWithString: "Reusable topic phrases. Pick from this list per chat in inspector → Extraction. Edits here don't change topics already added to a chat.")
        libraryHelp.font = Theme.font(10)
        libraryHelp.textColor = .secondaryLabelColor
        libraryHelp.translatesAutoresizingMaskIntoConstraints = false

        let retrievalHeader = NSTextField(labelWithString: "Retrieval (vector search over chat history)")
        retrievalHeader.font = Theme.bold(12)
        let topKLabel = NSTextField(labelWithString: "Top-K hits:")
        let thresholdLabel = NSTextField(labelWithString: "Cosine threshold (0–1):")
        let recencyLabel = NSTextField(labelWithString: "Exclude last N turns:")

        userNameField.placeholderString = "(blank — model won't address you by name)"
        ctxField.placeholderString = "0"
        let intF = NumberFormatter()
        intF.allowsFloats = false
        intF.minimum = 0
        intF.maximum = 1_000_000
        ctxField.formatter = intF

        let smallIntF = NumberFormatter()
        smallIntF.allowsFloats = false
        smallIntF.minimum = 1
        smallIntF.maximum = 50
        topKField.formatter = smallIntF

        let smallIntF2 = NumberFormatter()
        smallIntF2.allowsFloats = false
        smallIntF2.minimum = 0
        smallIntF2.maximum = 200
        recencyField.formatter = smallIntF2

        let floatF = NumberFormatter()
        floatF.allowsFloats = true
        floatF.minimum = 0
        floatF.maximum = 1
        floatF.maximumFractionDigits = 2
        thresholdField.formatter = floatF

        for t in Templates.all {
            templatePopup.addItem(withTitle: t.name)
            templatePopup.lastItem?.representedObject = t.id
        }
        for p in SamplerPreset.presets {
            presetPopup.addItem(withTitle: p.name)
            presetPopup.lastItem?.representedObject = p.id
        }
        rebuildPersonaPopup()

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        let separator2 = NSBox()
        separator2.boxType = .separator
        separator2.translatesAutoresizingMaskIntoConstraints = false

        fontOffsetStepper.minValue = -2
        fontOffsetStepper.maxValue = 8
        fontOffsetStepper.increment = 1
        fontOffsetStepper.valueWraps = false
        fontOffsetStepper.target = self
        fontOffsetStepper.action = #selector(fontStepperChanged)
        let fontIntF = NumberFormatter()
        fontIntF.allowsFloats = false
        fontIntF.minimum = -2
        fontIntF.maximum = 8
        fontOffsetField.formatter = fontIntF
        fontOffsetField.alignment = .right
        fontOffsetField.target = self
        fontOffsetField.action = #selector(fontFieldChanged)

        let fontStack = NSStackView(views: [fontOffsetField, fontOffsetStepper])
        fontStack.orientation = .horizontal
        fontStack.spacing = 6

        replyTokensStepper.minValue = 0
        replyTokensStepper.maxValue = 8192
        replyTokensStepper.increment = 128
        replyTokensStepper.valueWraps = false
        replyTokensStepper.target = self
        replyTokensStepper.action = #selector(replyTokensStepperChanged)
        let replyIntF = NumberFormatter()
        replyIntF.allowsFloats = false
        replyIntF.minimum = 0
        replyIntF.maximum = 8192
        replyTokensField.formatter = replyIntF
        replyTokensField.alignment = .right
        replyTokensField.target = self
        replyTokensField.action = #selector(replyTokensFieldChanged)
        let replyStack = NSStackView(views: [replyTokensField, replyTokensStepper])
        replyStack.orientation = .horizontal
        replyStack.spacing = 6

        factExtractStepper.minValue = 1
        factExtractStepper.maxValue = 100
        factExtractStepper.increment = 1
        factExtractStepper.valueWraps = false
        factExtractStepper.target = self
        factExtractStepper.action = #selector(factExtractStepperChanged)
        let factExtractIntF = NumberFormatter()
        factExtractIntF.allowsFloats = false
        factExtractIntF.minimum = 1
        factExtractIntF.maximum = 100
        factExtractField.formatter = factExtractIntF
        factExtractField.alignment = .right
        factExtractField.target = self
        factExtractField.action = #selector(factExtractFieldChanged)
        let factExtractStack = NSStackView(views: [factExtractField, factExtractStepper])
        factExtractStack.orientation = .horizontal
        factExtractStack.spacing = 6

        let separator3 = NSBox()
        separator3.boxType = .separator
        separator3.translatesAutoresizingMaskIntoConstraints = false

        libraryStack.orientation = .vertical
        libraryStack.spacing = 4
        libraryStack.alignment = .leading
        libraryStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        libraryStack.translatesAutoresizingMaskIntoConstraints = false

        libraryScroll.documentView = libraryStack
        libraryScroll.hasVerticalScroller = true
        libraryScroll.borderType = .lineBorder
        libraryScroll.translatesAutoresizingMaskIntoConstraints = false
        libraryStack.widthAnchor.constraint(equalTo: libraryScroll.contentView.widthAnchor).isActive = true
        libraryScroll.heightAnchor.constraint(equalToConstant: 110).isActive = true

        libraryAddButton.target = self
        libraryAddButton.action = #selector(addLibraryEntry)
        libraryAddButton.bezelStyle = .rounded

        // Servers list (vertical stack of profile rows, scrollable).
        serversStack.orientation = .vertical
        serversStack.spacing = 6
        serversStack.alignment = .leading
        serversStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        serversStack.translatesAutoresizingMaskIntoConstraints = false
        serversScroll.documentView = serversStack
        serversScroll.hasVerticalScroller = true
        serversScroll.borderType = .lineBorder
        serversScroll.translatesAutoresizingMaskIntoConstraints = false
        serversStack.widthAnchor.constraint(equalTo: serversScroll.contentView.widthAnchor).isActive = true
        serversScroll.heightAnchor.constraint(equalToConstant: 160).isActive = true

        addServerButton.target = self
        addServerButton.action = #selector(addServer)
        addServerButton.bezelStyle = .rounded

        defaultServerPopup.target = self
        defaultServerPopup.action = #selector(roleAssignmentChanged(_:))
        defaultServerPopup.tag = 0
        summarizerServerPopup.target = self
        summarizerServerPopup.action = #selector(roleAssignmentChanged(_:))
        summarizerServerPopup.tag = 1
        extractorServerPopup.target = self
        extractorServerPopup.action = #selector(roleAssignmentChanged(_:))
        extractorServerPopup.tag = 2
        embeddingsServerPopup.target = self
        embeddingsServerPopup.action = #selector(roleAssignmentChanged(_:))
        embeddingsServerPopup.tag = 3

        let defaultRoleLabel = NSTextField(labelWithString: "Default (chat):")
        let summarizerRoleLabel = NSTextField(labelWithString: "Summarizer:")
        let extractorRoleLabel = NSTextField(labelWithString: "Extractor:")
        let embeddingsRoleLabel = NSTextField(labelWithString: "Embeddings:")

        let separator0 = NSBox()
        separator0.boxType = .separator
        separator0.translatesAutoresizingMaskIntoConstraints = false

        let grid = NSGridView(views: [
            [NSView(), serversHeader],
            [NSView(), serversHelp],
            [NSView(), serversScroll],
            [NSView(), addServerButton],
            [defaultRoleLabel, defaultServerPopup],
            [summarizerRoleLabel, summarizerServerPopup],
            [extractorRoleLabel, extractorServerPopup],
            [embeddingsRoleLabel, embeddingsServerPopup],
            [NSView(), separator0],
            [userNameLabel, userNameField],
            [templateLabel, templatePopup],
            [presetLabel, presetPopup],
            [personaLabel, personaPopup],
            [ctxLabel, ctxField],
            [NSView(), qwenThinkingCheck],
            [NSView(), voiceCheck],
            [NSView(), separator],
            [NSView(), appearanceHeader],
            [fontOffsetLabel, fontStack],
            [replyTokensLabel, replyStack],
            [NSView(), separator2],
            [NSView(), memoryHeader],
            [NSView(), factExtractCheck],
            [factExtractLabel, factExtractStack],
            [libraryLabel, libraryHelp],
            [NSView(), libraryScroll],
            [NSView(), libraryAddButton],
            [NSView(), separator3],
            [NSView(), retrievalHeader],
            [NSView(), retrievalCheck],
            [topKLabel, topKField],
            [thresholdLabel, thresholdField],
            [recencyLabel, recencyField]
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.translatesAutoresizingMaskIntoConstraints = false

        // Wrap the grid in an NSScrollView so the dialog stays usable when
        // the window is shorter than the content. Without this, the rows
        // below the buttons get clipped and unreachable.
        let docContainer = FlippedView()
        docContainer.translatesAutoresizingMaskIntoConstraints = false
        docContainer.addSubview(grid)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.documentView = docContainer
        cv.addSubview(scroll)

        let buttons = NSStackView(views: [cancelButton, saveButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false
        cv.addSubview(buttons)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: cv.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: buttons.topAnchor, constant: -12),

            // Document container tracks the scroll view's width so rows
            // wrap/lay out at the visible width — only vertical scrolling.
            docContainer.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            docContainer.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),

            grid.topAnchor.constraint(equalTo: docContainer.topAnchor, constant: 20),
            grid.leadingAnchor.constraint(equalTo: docContainer.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(equalTo: docContainer.trailingAnchor, constant: -20),
            grid.bottomAnchor.constraint(equalTo: docContainer.bottomAnchor, constant: -20),

            buttons.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -20),
            buttons.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),

            serversScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            topKField.widthAnchor.constraint(equalToConstant: 80),
            thresholdField.widthAnchor.constraint(equalToConstant: 80),
            recencyField.widthAnchor.constraint(equalToConstant: 80),
            fontOffsetField.widthAnchor.constraint(equalToConstant: 50),
            replyTokensField.widthAnchor.constraint(equalToConstant: 70),
            factExtractField.widthAnchor.constraint(equalToConstant: 60)
        ])
    }

    @objc private func fontStepperChanged() {
        fontOffsetField.integerValue = fontOffsetStepper.integerValue
    }

    @objc private func fontFieldChanged() {
        fontOffsetStepper.integerValue = fontOffsetField.integerValue
    }

    @objc private func replyTokensStepperChanged() {
        replyTokensField.integerValue = replyTokensStepper.integerValue
    }

    @objc private func replyTokensFieldChanged() {
        replyTokensStepper.integerValue = replyTokensField.integerValue
    }

    @objc private func factExtractStepperChanged() {
        factExtractField.integerValue = factExtractStepper.integerValue
    }

    @objc private func factExtractFieldChanged() {
        factExtractStepper.integerValue = factExtractField.integerValue
    }

    // MARK: - Library editor

    private func rebuildLibraryUI() {
        for v in libraryStack.arrangedSubviews { libraryStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for (idx, entry) in libraryDraft.enumerated() {
            let row = makeLibraryRow(entry: entry, index: idx)
            libraryStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: libraryStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeLibraryRow(entry: LibraryTopic, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let field = NSTextField(string: entry.text)
        field.placeholderString = "topic phrase"
        field.font = Theme.font(12)
        field.tag = index
        field.isEditable = true
        field.isSelectable = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.drawsBackground = true
        field.translatesAutoresizingMaskIntoConstraints = false
        field.target = self
        field.action = #selector(libraryFieldCommitted(_:))

        let remove = NSButton(title: "×", target: self, action: #selector(removeLibraryEntry(_:)))
        remove.tag = index
        remove.bezelStyle = .circular
        remove.toolTip = "Remove this preset"
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

    private func commitLibraryFromUI() {
        for (idx, view) in libraryStack.arrangedSubviews.enumerated() where idx < libraryDraft.count {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                libraryDraft[idx].text = field.stringValue
            }
        }
    }

    @objc private func addLibraryEntry() {
        commitLibraryFromUI()
        libraryDraft.append(LibraryTopic(text: ""))
        rebuildLibraryUI()
        if let lastField = libraryStack.arrangedSubviews.last?
            .subviews.compactMap({ $0 as? NSTextField }).first {
            window?.makeFirstResponder(lastField)
        }
    }

    @objc private func removeLibraryEntry(_ sender: NSButton) {
        commitLibraryFromUI()
        let idx = sender.tag
        guard libraryDraft.indices.contains(idx) else { return }
        libraryDraft.remove(at: idx)
        rebuildLibraryUI()
    }

    @objc private func libraryFieldCommitted(_ sender: NSTextField) {
        let idx = sender.tag
        guard libraryDraft.indices.contains(idx) else { return }
        libraryDraft[idx].text = sender.stringValue
    }

    private func loadValues() {
        let s = AppState.shared.settings
        serversDraft = s.servers
        defaultServerIdDraft = s.defaultServerId
        summarizerServerIdDraft = s.summarizerServerId
        extractorServerIdDraft = s.extractorServerId
        embeddingsServerIdDraft = s.embeddingsServerId
        probeStatusDraft.removeAll()
        for p in s.servers {
            // Last-probed dot derived from cached capabilities. No
            // capabilities = never probed; presence = "ok" until next probe.
            probeStatusDraft[p.id] = (p.capabilities?.modelName != nil) ? "ok" : ""
        }
        rebuildServersUI()
        rebuildRolePopups()
        userNameField.stringValue = s.userName
        if let i = Templates.all.firstIndex(where: { $0.id == s.defaultTemplateId }) {
            templatePopup.selectItem(at: i)
        }
        if let i = SamplerPreset.presets.firstIndex(where: { $0.id == s.defaultSamplerPresetId }) {
            presetPopup.selectItem(at: i)
        }
        rebuildPersonaPopup()
        selectPersonaInPopup(s.defaultPersonaId)
        voiceCheck.state = s.voiceEnabled ? .on : .off
        qwenThinkingCheck.state = s.qwenThinkingEnabled ? .on : .off
        ctxField.integerValue = s.maxContextOverride

        retrievalCheck.state = s.retrieval.enabled ? .on : .off
        topKField.integerValue = s.retrieval.topK
        thresholdField.doubleValue = Double(s.retrieval.threshold)
        recencyField.integerValue = s.retrieval.recencyExclusion

        fontOffsetStepper.integerValue = s.uiFontOffset
        fontOffsetField.integerValue = s.uiFontOffset

        replyTokensStepper.integerValue = s.replyTokensOverride
        replyTokensField.integerValue = s.replyTokensOverride

        factExtractCheck.state = s.factExtractionEnabled ? .on : .off
        factExtractStepper.integerValue = s.factExtractionEveryNTurns
        factExtractField.integerValue = s.factExtractionEveryNTurns

        libraryDraft = s.priorityTopicLibrary
        rebuildLibraryUI()
    }

    /// Rebuild the persona popup from the live `AppState.personas` list.
    /// Item 0 is always "(none — anonymous)" so the user can clear the
    /// default; subsequent items carry the persona id in `representedObject`
    /// for save() to read back.
    private func rebuildPersonaPopup() {
        personaPopup.removeAllItems()
        personaPopup.addItem(withTitle: "(none — anonymous)")
        personaPopup.lastItem?.representedObject = nil
        for p in AppState.shared.personas {
            let title = p.name.isEmpty ? "(unnamed)" : p.name
            personaPopup.addItem(withTitle: title)
            personaPopup.lastItem?.representedObject = p.id.uuidString
        }
    }

    private func selectPersonaInPopup(_ id: UUID?) {
        guard let id = id else {
            personaPopup.selectItem(at: 0)
            return
        }
        // Items 1+ carry the persona id; item 0 is the "none" sentinel.
        for i in 1..<personaPopup.numberOfItems {
            let raw = personaPopup.item(at: i)?.representedObject as? String
            if raw == id.uuidString {
                personaPopup.selectItem(at: i)
                return
            }
        }
        // Persona referenced but not found (deleted while settings closed).
        // Fall back to "none" so save doesn't write a dangling pointer back.
        personaPopup.selectItem(at: 0)
    }

    @objc private func save() {
        let templateId = (templatePopup.selectedItem?.representedObject as? String) ?? "gemma"
        let presetId = (presetPopup.selectedItem?.representedObject as? String) ?? "balanced"
        var s = AppState.shared.settings
        commitServersDraftFromUI()
        s.servers = serversDraft
        s.defaultServerId = defaultServerIdDraft
        s.summarizerServerId = summarizerServerIdDraft
        s.extractorServerId = extractorServerIdDraft
        s.embeddingsServerId = embeddingsServerIdDraft
        s.userName = userNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.defaultTemplateId = templateId
        s.defaultSamplerPresetId = presetId
        if let raw = personaPopup.selectedItem?.representedObject as? String,
           let id = UUID(uuidString: raw) {
            s.defaultPersonaId = id
        } else {
            s.defaultPersonaId = nil
        }
        s.voiceEnabled = voiceCheck.state == .on
        s.qwenThinkingEnabled = qwenThinkingCheck.state == .on
        s.maxContextOverride = max(0, ctxField.integerValue)

        s.retrieval.enabled = retrievalCheck.state == .on
        s.retrieval.topK = max(1, min(50, topKField.integerValue))
        s.retrieval.threshold = Float(min(1.0, max(0.0, thresholdField.doubleValue)))
        s.retrieval.recencyExclusion = max(0, recencyField.integerValue)

        let oldOffset = AppState.shared.settings.uiFontOffset
        s.uiFontOffset = max(-2, min(8, fontOffsetStepper.integerValue))
        s.replyTokensOverride = max(0, min(8192, replyTokensStepper.integerValue))

        s.factExtractionEnabled = factExtractCheck.state == .on
        s.factExtractionEveryNTurns = max(1, min(100, factExtractStepper.integerValue))

        commitLibraryFromUI()
        s.priorityTopicLibrary = libraryDraft
            .map { LibraryTopic(id: $0.id, text: $0.text.trimmingCharacters(in: .whitespaces)) }
            .filter { !$0.text.isEmpty }

        AppState.shared.saveSettings(s)
        if oldOffset != s.uiFontOffset {
            NotificationCenter.default.post(name: AppNotification.fontChanged, object: nil)
        }
        window?.close()
    }

    @objc private func cancel() {
        window?.close()
    }

    // MARK: - Servers editor

    private func rebuildServersUI() {
        for v in serversStack.arrangedSubviews {
            serversStack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        for (idx, profile) in serversDraft.enumerated() {
            let row = makeServerRow(profile: profile, index: idx)
            serversStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: serversStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeServerRow(profile: ServerProfile, index: Int) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let nameField = NSTextField(string: profile.name)
        nameField.placeholderString = "name"
        nameField.tag = index
        nameField.identifier = NSUserInterfaceItemIdentifier("server-name")
        nameField.font = Theme.font(12)
        nameField.target = self
        nameField.action = #selector(serverFieldCommitted(_:))
        nameField.translatesAutoresizingMaskIntoConstraints = false

        let urlF = NSTextField(string: profile.baseURL.absoluteString)
        urlF.placeholderString = "http://host:port"
        urlF.tag = index
        urlF.identifier = NSUserInterfaceItemIdentifier("server-url")
        urlF.font = Theme.font(12)
        urlF.target = self
        urlF.action = #selector(serverFieldCommitted(_:))
        urlF.translatesAutoresizingMaskIntoConstraints = false

        let statusDot = NSTextField(labelWithString: probeDotLabel(for: profile.id))
        statusDot.identifier = NSUserInterfaceItemIdentifier("server-status")
        statusDot.font = Theme.font(11)
        statusDot.translatesAutoresizingMaskIntoConstraints = false
        statusDot.toolTip = profile.capabilities?.modelName ?? "Not yet probed"

        let testBtn = NSButton(title: "Test", target: self, action: #selector(testServer(_:)))
        testBtn.tag = index
        testBtn.bezelStyle = .rounded
        testBtn.translatesAutoresizingMaskIntoConstraints = false

        let deleteBtn = NSButton(title: "×", target: self, action: #selector(removeServer(_:)))
        deleteBtn.tag = index
        deleteBtn.bezelStyle = .circular
        deleteBtn.toolTip = profile.id == defaultServerIdDraft
            ? "Default server cannot be deleted (re-point Default first)"
            : "Delete this server"
        deleteBtn.isEnabled = profile.id != defaultServerIdDraft
        deleteBtn.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(nameField)
        row.addSubview(urlF)
        row.addSubview(statusDot)
        row.addSubview(testBtn)
        row.addSubview(deleteBtn)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),

            nameField.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            nameField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            nameField.widthAnchor.constraint(equalToConstant: 100),

            urlF.leadingAnchor.constraint(equalTo: nameField.trailingAnchor, constant: 6),
            urlF.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            urlF.trailingAnchor.constraint(equalTo: statusDot.leadingAnchor, constant: -6),

            statusDot.widthAnchor.constraint(equalToConstant: 18),
            statusDot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            statusDot.trailingAnchor.constraint(equalTo: testBtn.leadingAnchor, constant: -4),

            testBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            testBtn.trailingAnchor.constraint(equalTo: deleteBtn.leadingAnchor, constant: -4),

            deleteBtn.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            deleteBtn.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            deleteBtn.widthAnchor.constraint(equalToConstant: 24),
            deleteBtn.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    private func probeDotLabel(for id: UUID) -> String {
        switch probeStatusDraft[id] ?? "" {
        case "ok": return "●"      // green-ish via system; tinted by tooltip
        case "fail": return "●"
        default: return "○"        // never probed
        }
    }

    /// Pull edits out of the row text fields back into `serversDraft`. Called
    /// before any structural change (add/remove) and at save time, mirroring
    /// the library editor's `commitLibraryFromUI`.
    private func commitServersDraftFromUI() {
        for (idx, view) in serversStack.arrangedSubviews.enumerated() where idx < serversDraft.count {
            for sub in view.subviews {
                guard let f = sub as? NSTextField, let id = f.identifier?.rawValue else { continue }
                switch id {
                case "server-name":
                    serversDraft[idx].name = f.stringValue.trimmingCharacters(in: .whitespaces)
                case "server-url":
                    if let url = ServerEditing.validateBaseURL(f.stringValue) {
                        serversDraft[idx].baseURL = url
                    }
                default: break
                }
            }
        }
    }

    @objc private func serverFieldCommitted(_ sender: NSTextField) {
        let idx = sender.tag
        guard serversDraft.indices.contains(idx),
              let id = sender.identifier?.rawValue else { return }
        switch id {
        case "server-name":
            serversDraft[idx].name = sender.stringValue.trimmingCharacters(in: .whitespaces)
        case "server-url":
            if let url = ServerEditing.validateBaseURL(sender.stringValue) {
                serversDraft[idx].baseURL = url
            }
        default: break
        }
        rebuildRolePopups()
    }

    @objc private func addServer() {
        commitServersDraftFromUI()
        let new = ServerProfile(name: "New", baseURL: URL(string: "http://localhost:5001")!)
        serversDraft.append(new)
        rebuildServersUI()
        rebuildRolePopups()
    }

    @objc private func removeServer(_ sender: NSButton) {
        commitServersDraftFromUI()
        let idx = sender.tag
        guard serversDraft.indices.contains(idx) else { return }
        let target = serversDraft[idx]
        // Tunnel through ServerEditing so the role-pointer cleanup rule is
        // applied in lockstep with the deletion (and the no-default guard
        // refuses if the user somehow clicks on a default row).
        var snapshot = AppState.shared.settings
        snapshot.servers = serversDraft
        snapshot.defaultServerId = defaultServerIdDraft
        snapshot.summarizerServerId = summarizerServerIdDraft
        snapshot.extractorServerId = extractorServerIdDraft
        snapshot.embeddingsServerId = embeddingsServerIdDraft
        ServerEditing.removeProfile(target.id, from: &snapshot)
        serversDraft = snapshot.servers
        defaultServerIdDraft = snapshot.defaultServerId
        summarizerServerIdDraft = snapshot.summarizerServerId
        extractorServerIdDraft = snapshot.extractorServerId
        embeddingsServerIdDraft = snapshot.embeddingsServerId
        probeStatusDraft.removeValue(forKey: target.id)
        rebuildServersUI()
        rebuildRolePopups()
    }

    @objc private func testServer(_ sender: NSButton) {
        commitServersDraftFromUI()
        let idx = sender.tag
        guard serversDraft.indices.contains(idx) else { return }
        let profile = serversDraft[idx]
        sender.isEnabled = false
        let pid = profile.id
        ServerProbe.probe(baseURL: profile.baseURL) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let row = sender.superview {
                    sender.isEnabled = true
                    if let dot = row.subviews.first(where: {
                        ($0 as? NSTextField)?.identifier?.rawValue == "server-status"
                    }) as? NSTextField {
                        switch result {
                        case .success(let caps):
                            self.probeStatusDraft[pid] = "ok"
                            if let i = self.serversDraft.firstIndex(where: { $0.id == pid }) {
                                self.serversDraft[i].capabilities = caps
                                self.serversDraft[i].lastProbed = Date()
                            }
                            dot.stringValue = "●"
                            dot.textColor = .systemGreen
                            dot.toolTip = caps.modelName ?? "Reachable"
                        case .failure(let err):
                            self.probeStatusDraft[pid] = "fail"
                            dot.stringValue = "●"
                            dot.textColor = .systemRed
                            dot.toolTip = err.description
                        }
                    }
                }
            }
        }
    }

    @objc private func roleAssignmentChanged(_ sender: NSPopUpButton) {
        let pickedId = sender.selectedItem?.representedObject as? UUID
        switch sender.tag {
        case 0:
            // Default — re-point to the picked id; never clear.
            if let pickedId = pickedId { defaultServerIdDraft = pickedId }
        case 1: summarizerServerIdDraft = pickedId
        case 2: extractorServerIdDraft = pickedId
        case 3: embeddingsServerIdDraft = pickedId
        default: break
        }
        rebuildRolePopups()
        rebuildServersUI()  // refresh delete-button enabled state
    }

    /// Refill the four role-assignment popups from `serversDraft`. Default's
    /// list excludes "(use default)" since there's no nullable fallback for
    /// that role; the side-call popups offer it.
    private func rebuildRolePopups() {
        func fill(_ popup: NSPopUpButton, includeNone: Bool, currentId: UUID?) {
            popup.removeAllItems()
            if includeNone {
                popup.addItem(withTitle: "(use default)")
                popup.lastItem?.representedObject = nil as UUID?
            }
            for p in serversDraft {
                popup.addItem(withTitle: p.name.isEmpty ? "(unnamed)" : p.name)
                popup.lastItem?.representedObject = p.id
            }
            if let id = currentId,
               let i = popup.itemArray.firstIndex(where: { ($0.representedObject as? UUID) == id }) {
                popup.selectItem(at: i)
            } else {
                popup.selectItem(at: 0)
            }
        }
        fill(defaultServerPopup, includeNone: false, currentId: defaultServerIdDraft)
        fill(summarizerServerPopup, includeNone: true, currentId: summarizerServerIdDraft)
        fill(extractorServerPopup, includeNone: true, currentId: extractorServerIdDraft)
        fill(embeddingsServerPopup, includeNone: true, currentId: embeddingsServerIdDraft)
    }
}

/// Flipped coord system so the grid pins to the *top* of the scroll view's
/// content rather than the bottom (NSScrollView's default Cocoa orientation).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
