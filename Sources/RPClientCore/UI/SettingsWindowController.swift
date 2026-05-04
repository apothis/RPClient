import AppKit

final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let urlField = NSTextField()
    private let userNameField = NSTextField()
    private let templatePopup = NSPopUpButton()
    private let presetPopup = NSPopUpButton()
    private let voiceCheck = NSButton(checkboxWithTitle: "Speak replies", target: nil, action: nil)
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

        let urlLabel = NSTextField(labelWithString: "Server URL:")
        let userNameLabel = NSTextField(labelWithString: "Your name:")
        let templateLabel = NSTextField(labelWithString: "Default template:")
        let presetLabel = NSTextField(labelWithString: "Default sampler preset:")
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

        urlField.placeholderString = "http://localhost:5001"
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

        let grid = NSGridView(views: [
            [urlLabel, urlField],
            [userNameLabel, userNameField],
            [templateLabel, templatePopup],
            [presetLabel, presetPopup],
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

            urlField.widthAnchor.constraint(greaterThanOrEqualToConstant: 280),
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
        urlField.stringValue = s.serverURL
        userNameField.stringValue = s.userName
        if let i = Templates.all.firstIndex(where: { $0.id == s.defaultTemplateId }) {
            templatePopup.selectItem(at: i)
        }
        if let i = SamplerPreset.presets.firstIndex(where: { $0.id == s.defaultSamplerPresetId }) {
            presetPopup.selectItem(at: i)
        }
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

    @objc private func save() {
        let templateId = (templatePopup.selectedItem?.representedObject as? String) ?? "gemma"
        let presetId = (presetPopup.selectedItem?.representedObject as? String) ?? "balanced"
        var s = AppState.shared.settings
        s.serverURL = urlField.stringValue.isEmpty ? "http://localhost:5001" : urlField.stringValue
        s.userName = userNameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        s.defaultTemplateId = templateId
        s.defaultSamplerPresetId = presetId
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
}

/// Flipped coord system so the grid pins to the *top* of the scroll view's
/// content rather than the bottom (NSScrollView's default Cocoa orientation).
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}
