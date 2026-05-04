import AppKit

final class SummaryPane: NSViewController, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let helpLabel = NSTextField(labelWithString:
        "Rolling summary. Auto-compresses older turns when context fills up.")
    private let statusLabel = NSTextField(labelWithString: "")
    private let summarizeButton = NSButton(title: "Summarize now", target: nil, action: nil)
    private let sceneBreakButton = NSButton(title: "Scene break", target: nil, action: nil)

    private var lastChatId: UUID?

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

        textView.isRichText = false
        textView.font = Theme.font(12)
        textView.allowsUndo = true
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 80)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        statusLabel.font = Theme.mono(11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(statusLabel)

        summarizeButton.target = self
        summarizeButton.action = #selector(summarizeTapped)
        summarizeButton.bezelStyle = .rounded
        summarizeButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(summarizeButton)

        sceneBreakButton.target = self
        sceneBreakButton.action = #selector(sceneBreakTapped)
        sceneBreakButton.bezelStyle = .rounded
        sceneBreakButton.toolTip = "Freeze the current summary as a scene snapshot, start a fresh one."
        sceneBreakButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(sceneBreakButton)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: statusLabel.topAnchor, constant: -8),

            statusLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: sceneBreakButton.leadingAnchor, constant: -8),
            statusLabel.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),

            sceneBreakButton.trailingAnchor.constraint(equalTo: summarizeButton.leadingAnchor, constant: -8),
            sceneBreakButton.centerYAnchor.constraint(equalTo: summarizeButton.centerYAnchor),

            summarizeButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            summarizeButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refreshStatus),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        helpLabel.font = Theme.font(11)
        textView.font = Theme.font(12)
        statusLabel.font = Theme.mono(11)
    }

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else {
            textView.string = ""
            statusLabel.stringValue = ""
            return
        }
        if chat.id != lastChatId {
            lastChatId = chat.id
            textView.string = chat.summary
        } else if textView.window?.firstResponder !== textView,
                  textView.string != chat.summary {
            // Scene break / summarizer ran — sync the view if the user
            // isn't mid-edit (don't clobber their typing).
            textView.string = chat.summary
        }
        refreshStatus()
    }

    @objc private func refreshStatus() {
        guard let chat = AppState.shared.currentChat else { return }
        let s = AppState.shared
        var bits: [String] = []
        bits.append("through turn \(chat.summarizedThrough)/\(chat.turns.count)")
        if !chat.sceneSummaries.isEmpty {
            bits.append("scenes: \(chat.sceneSummaries.count)")
        }
        if s.isSummarizing {
            bits.append("summarizing…")
            summarizeButton.isEnabled = false
            sceneBreakButton.isEnabled = false
        } else {
            summarizeButton.isEnabled = !s.isStreaming
            // Scene break only makes sense when there's a live summary to freeze.
            sceneBreakButton.isEnabled = !s.isStreaming
                && !chat.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        if let err = s.lastSummarizerError {
            bits.append("error: \(err)")
        }
        statusLabel.stringValue = bits.joined(separator: "  ·  ")
    }

    @objc private func sceneBreakTapped() {
        // Persist any pending edit to the live summary first so the snapshot
        // reflects what the user sees on screen, not stale chat state.
        let text = textView.string
        AppState.shared.updateCurrent { c in
            c.summary = text
        }
        AppState.shared.markSceneBreak()
    }

    @objc private func summarizeTapped() {
        // Persist any pending edits first.
        let text = textView.string
        AppState.shared.updateCurrent { c in
            c.summary = text
        }
        AppState.shared.runSummarizer()
    }

    func textDidEndEditing(_ notification: Notification) {
        let text = textView.string
        AppState.shared.updateCurrent { c in
            c.summary = text
        }
    }
}
