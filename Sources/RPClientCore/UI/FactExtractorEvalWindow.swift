import AppKit

/// Dev-only window for inspecting §9.3 entity-fact extractor output. Press
/// "Run" to side-call the model with a GBNF-constrained prompt; see the
/// parsed facts, the raw model output, and latency. Per-chat config (priority
/// topics, scan window) lives in the inspector's "Extraction" tab — this
/// window reads from there and doesn't edit it.
final class FactExtractorEvalWindow: NSWindowController, NSWindowDelegate {
    private let runButton = NSButton(title: "Run extraction", target: nil, action: nil)
    private let saveButton = NSButton(title: "Send to suggestions", target: nil, action: nil)
    private let configLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "Idle.")
    private let factsScroll = NSScrollView()
    private let factsView = NSTextView()
    private let rawScroll = NSScrollView()
    private let rawView = NSTextView()
    private var lastFacts: [ExtractedFact] = []

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        w.title = "Fact extraction (eval)"
        self.init(window: w)
        w.delegate = self
        buildUI()
        refreshConfigSummary()

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refreshConfigSummary),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refreshConfigSummary),
            name: AppNotification.currentChatChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        runButton.target = self
        runButton.action = #selector(run)
        runButton.bezelStyle = .rounded
        runButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(sendToSuggestions)
        saveButton.bezelStyle = .rounded
        saveButton.isEnabled = false
        saveButton.toolTip = "Queue the parsed facts in the Suggestions inspector pane."
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = Theme.mono(11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        configLabel.font = Theme.font(11)
        configLabel.textColor = .secondaryLabelColor
        configLabel.lineBreakMode = .byWordWrapping
        configLabel.maximumNumberOfLines = 0
        configLabel.translatesAutoresizingMaskIntoConstraints = false

        let factsHeader = NSTextField(labelWithString: "Parsed facts")
        factsHeader.font = Theme.bold(12)
        factsHeader.translatesAutoresizingMaskIntoConstraints = false

        let rawHeader = NSTextField(labelWithString: "Raw model output")
        rawHeader.font = Theme.bold(12)
        rawHeader.translatesAutoresizingMaskIntoConstraints = false

        configure(textView: factsView, scroll: factsScroll)
        configure(textView: rawView, scroll: rawScroll)

        cv.addSubview(runButton)
        cv.addSubview(saveButton)
        cv.addSubview(statusLabel)
        cv.addSubview(configLabel)
        cv.addSubview(factsHeader)
        cv.addSubview(factsScroll)
        cv.addSubview(rawHeader)
        cv.addSubview(rawScroll)

        NSLayoutConstraint.activate([
            runButton.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            runButton.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),

            saveButton.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            saveButton.leadingAnchor.constraint(equalTo: runButton.trailingAnchor, constant: 8),

            statusLabel.centerYAnchor.constraint(equalTo: runButton.centerYAnchor),
            statusLabel.leadingAnchor.constraint(equalTo: saveButton.trailingAnchor, constant: 16),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -12),

            configLabel.topAnchor.constraint(equalTo: runButton.bottomAnchor, constant: 12),
            configLabel.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            configLabel.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),

            factsHeader.topAnchor.constraint(equalTo: configLabel.bottomAnchor, constant: 14),
            factsHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),

            factsScroll.topAnchor.constraint(equalTo: factsHeader.bottomAnchor, constant: 4),
            factsScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            factsScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            factsScroll.heightAnchor.constraint(equalToConstant: 200),

            rawHeader.topAnchor.constraint(equalTo: factsScroll.bottomAnchor, constant: 12),
            rawHeader.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),

            rawScroll.topAnchor.constraint(equalTo: rawHeader.bottomAnchor, constant: 4),
            rawScroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            rawScroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            rawScroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12)
        ])
    }

    private func configure(textView: NSTextView, scroll: NSScrollView) {
        textView.isRichText = false
        textView.isEditable = false
        textView.font = Theme.mono(11)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )

        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
    }

    @objc private func refreshConfigSummary() {
        guard let chat = AppState.shared.currentChat else {
            configLabel.stringValue = "No active chat."
            return
        }
        let active = chat.factExtractionPriorities.filter {
            $0.enabled && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }
        let scan = chat.factExtractionScanTurns
        let scanDesc = scan > 0 ? "\(scan)" : "auto"
        configLabel.stringValue = "Active topics: \(active.count) · scan turns: \(scanDesc) · edit in inspector → Extraction tab"
    }

    @objc private func sendToSuggestions() {
        guard !lastFacts.isEmpty else { return }
        let total = lastFacts.count
        let added = AppState.shared.addSuggestions(lastFacts)
        saveButton.isEnabled = false
        let skipped = total - added
        if skipped > 0 {
            statusLabel.stringValue = "Queued \(added) suggestion\(added == 1 ? "" : "s"). \(skipped) duplicate\(skipped == 1 ? "" : "s") skipped."
        } else {
            statusLabel.stringValue = "Queued \(added) suggestion\(added == 1 ? "" : "s"). Review in the Suggestions pane."
        }
    }

    @objc private func run() {
        guard let chat = AppState.shared.currentChat else {
            statusLabel.stringValue = "No active chat."
            return
        }
        guard chat.turns.count >= 2 else {
            statusLabel.stringValue = "Need at least 2 turns to extract from."
            return
        }
        runButton.isEnabled = false
        saveButton.isEnabled = false
        lastFacts = []
        let activeCount = chat.factExtractionPriorities.filter {
            $0.enabled && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty
        }.count
        statusLabel.stringValue = "Running… (\(activeCount) topic\(activeCount == 1 ? "" : "s") active)"
        factsView.string = ""
        rawView.string = ""

        // Match the auto-extract scan window: explicit per-chat value if set,
        // otherwise the same dynamic default AppState uses. All counts are in
        // user turns (= cycles).
        let scanN: Int = {
            if chat.factExtractionScanTurns > 0 {
                return chat.factExtractionScanTurns
            }
            let userTurnsNow = chat.turns.filter { $0.role == .user }.count
            let unseen = max(0, userTurnsNow - chat.lastExtractedTurn)
            return max(4, unseen + 2)
        }()

        FactExtractor.run(
            chat: chat,
            kobold: AppState.shared.kobold,
            effectiveCtx: AppState.shared.effectiveContext,
            lastN: scanN
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.runButton.isEnabled = true
                switch result {
                case .failure(let err):
                    self.statusLabel.stringValue = "Error: \(err.localizedDescription)"
                case .success(let r):
                    let validity = r.validJSON ? "valid JSON" : "PARSE ERROR (\(r.parseError ?? "?"))"
                    let known = r.knownBlockChars > 0 ? "known=\(r.knownBlockChars)c" : "known=none"
                    self.statusLabel.stringValue = "\(r.facts.count) facts · \(validity) · \(r.latencyMs)ms · scanned \(r.turnsScanned) turns · \(known) · \(activeCount) topic\(activeCount == 1 ? "" : "s")"
                    self.factsView.string = r.facts.isEmpty
                        ? "(none)"
                        : r.facts.map { f in "[\(f.entityType)] \(f.entityName) — \(f.fact)" }.joined(separator: "\n")
                    self.rawView.string = r.rawText
                    self.lastFacts = r.facts
                    self.saveButton.isEnabled = !r.facts.isEmpty
                }
            }
        }
    }
}
