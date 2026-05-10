import AppKit

final class RetrievalPane: NSViewController {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let helpButton = HelpButton(pageId: "memory-retrieval")
    private let reindexButton = NSButton(title: "Re-index now", target: nil, action: nil)

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        statusLabel.font = Theme.mono(11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(statusLabel)
        v.addSubview(helpButton)

        textView.isRichText = false
        textView.isEditable = false
        textView.font = Theme.font(11)
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

        reindexButton.target = self
        reindexButton.action = #selector(reindexTapped)
        reindexButton.bezelStyle = .rounded
        reindexButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(reindexButton)

        NSLayoutConstraint.activate([
            statusLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            statusLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            statusLabel.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),

            helpButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: statusLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: reindexButton.topAnchor, constant: -8),

            reindexButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            reindexButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        refresh()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        statusLabel.font = Theme.mono(11)
        textView.font = Theme.font(11)
    }

    @objc private func reindexTapped() {
        AppState.shared.kickIndexing()
    }

    /// Explain *why* retrieval is or isn't returning hits, and predict when
    /// it'll start firing. Mirrors `RetrievalEngine.excludePredicate`: a
    /// chunk is eligible iff its `lastTurnIdx` is below BOTH the recency
    /// cutoff (head − exclude-last-N) and the verbatim cutoff
    /// (`summarizedThrough`). Until the rolling summary advances past a
    /// chunk, that chunk is still verbatim in the prompt and ineligible —
    /// which is the usual reason the pane reads "0 chunks indexed" feels
    /// wrong on a fresh chat: chunks are there, they just don't pass the
    /// gate yet.
    private func eligibilityLine(chat: Chat, store: VectorStore, recencyExclusion: Int) -> String {
        let turns = chat.turns.count
        let summarized = chat.summarizedThrough
        let recencyCutoff = max(0, turns - recencyExclusion)
        let verbatimCutoff = summarized
        let effectiveCutoff = min(recencyCutoff, verbatimCutoff)

        let total = store.chunks.count
        let eligible = store.chunks.values.filter { $0.lastTurnIdx < effectiveCutoff }.count

        if total == 0 {
            return "(no chunks yet — the chunker emits the first chunk after 2+ turns)"
        }

        let s = AppState.shared
        let usagePct: Int = {
            guard s.lastUsage.ctx > 0 else { return 0 }
            return Int((Double(s.lastUsage.prompt) / Double(s.lastUsage.ctx)) * 100)
        }()
        let triggerPct = Int(chat.summaryTriggerRatio * 100)
        let unsummarized = max(0, turns - summarized)

        if eligible > 0 {
            return "\(eligible)/\(total) chunks eligible · cutoff at turn \(effectiveCutoff) (recency=\(recencyCutoff), verbatim=\(verbatimCutoff))"
        }

        // No chunk passes — explain which gate is blocking and what unblocks it.
        var reasons: [String] = []
        if verbatimCutoff <= 0 {
            // Nothing has been summarised yet. Predict when it will be.
            let pctNote = "currently \(usagePct)% of ctx, summariser fires at \(triggerPct)%"
            let countNote = unsummarized < 6
                ? "needs \(6 - unsummarized) more turn\(6 - unsummarized == 1 ? "" : "s") past the threshold"
                : "and at least 6 unsummarised turns (\(unsummarized) currently)"
            reasons.append("verbatim cutoff = 0 (no summary yet — \(pctNote); \(countNote))")
        } else if recencyCutoff <= 0 {
            reasons.append("recency cutoff at turn 0 (chat shorter than the \(recencyExclusion)-turn exclusion)")
        } else {
            reasons.append("no chunk older than turn \(effectiveCutoff)")
        }
        return "0/\(total) chunks eligible · " + reasons.joined(separator: " · ")
    }

    @objc private func refresh() {
        let s = AppState.shared
        let r = s.settings.retrieval

        var statusBits: [String] = []
        if !r.enabled {
            statusBits.append("Retrieval disabled. Enable in Settings (Cmd+,) and ensure koboldcpp is launched with --embeddingsmodel.")
        } else {
            if let chat = s.currentChat {
                let store = RetrievalEngine.shared.store(for: chat.id)
                statusBits.append("\(store.chunks.count) chunks indexed · \(s.lastRetrievalHits.count) hits last query")
                statusBits.append(eligibilityLine(chat: chat, store: store, recencyExclusion: r.recencyExclusion))
            }
            statusBits.append("topK=\(r.topK) · threshold=\(String(format: "%.2f", r.threshold)) · exclude last \(r.recencyExclusion) turns · contextual=\(r.contextual ? "on" : "off")")
            if s.isIndexing { statusBits.append("indexing…") }
            if let err = s.lastIndexError { statusBits.append("error: \(err)") }
        }
        statusLabel.stringValue = statusBits.joined(separator: "\n")

        if s.lastRetrievalHits.isEmpty {
            textView.string = r.enabled ? "(no hits in the last query)" : ""
        } else {
            textView.string = s.lastRetrievalHits.enumerated().map { i, hit in
                let header = String(
                    format: "#%d · score %.3f · turns %d–%d",
                    i + 1, hit.score, hit.chunk.firstTurnIdx, hit.chunk.lastTurnIdx
                )
                if let blurb = hit.chunk.contextBlurb?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !blurb.isEmpty {
                    return "\(header)\nContext: \(blurb)\n\n\(hit.chunk.text)"
                }
                return "\(header)\n\(hit.chunk.text)"
            }.joined(separator: "\n\n────────\n\n")
        }
    }
}
