import AppKit

final class CtxFillBar: NSView {
    var usage: BudgetUsage = .zero {
        didSet {
            needsDisplay = true
            rebuildTooltips()
        }
    }

    /// Tooltip text keyed by the tag `addToolTip(_:owner:userData:)` returns.
    /// We're the owner (so AppKit holds a non-owning reference to `self`,
    /// which is fine — the view outlives any tooltip hover); the actual
    /// strings live here, looked up in `view(_:stringForToolTip:…)`.
    private var tooltipText: [NSView.ToolTipTag: String] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }
    required init?(coder: NSCoder) { nil }

    override var intrinsicContentSize: NSSize { NSSize(width: 160, height: 10) }

    /// Order, color, and tooltip metadata for each segment. Single source of
    /// truth — `draw(_:)` walks this for the fill rects, and `rebuildTooltips`
    /// walks the same list to register hover regions.
    private struct Segment {
        let tokens: Int
        let color: NSColor
        let label: String
    }

    private func segments() -> [Segment] {
        [
            Segment(tokens: usage.memory, color: .systemBlue,
                    label: "Memory & entities — pinned facts and on-stage entity facts"),
            Segment(tokens: usage.summary, color: .systemPurple,
                    label: "Summary — rolling auto-summary plus frozen scene summaries"),
            Segment(tokens: usage.worldInfo, color: .systemTeal,
                    label: "World info — keyword-triggered lore entries"),
            Segment(tokens: usage.authorsNote, color: .systemOrange,
                    label: "Author's note — style/scene cues injected near the end"),
            Segment(tokens: usage.templateOverhead, color: .systemGray,
                    label: "Template overhead — role markers and prompt scaffolding"),
            Segment(tokens: usage.turnsTotal, color: .systemGreen,
                    label: "Verbatim turns — recent user/assistant messages sent in full"),
            Segment(tokens: usage.retrieval, color: .systemPink,
                    label: "Retrieval — vector-search hits attached to the latest turn")
        ]
    }

    override func draw(_ dirtyRect: NSRect) {
        let bg = NSColor.controlColor
        bg.setFill()
        let path = NSBezierPath(roundedRect: bounds, xRadius: 2, yRadius: 2)
        path.fill()

        guard usage.ctx > 0 else {
            NSColor.separatorColor.setStroke()
            path.stroke()
            return
        }

        let totalW = bounds.width
        var x: CGFloat = 0

        for segment in segments() {
            guard segment.tokens > 0 else { continue }
            let w = CGFloat(segment.tokens) / CGFloat(usage.ctx) * totalW
            segment.color.setFill()
            NSRect(x: x, y: 0, width: w, height: bounds.height).fill()
            x += w
        }
        // Reply reserve — dimmed so it's visually distinct from "already used"
        if usage.replyReserve > 0 {
            let w = CGFloat(usage.replyReserve) / CGFloat(usage.ctx) * totalW
            NSColor.systemRed.withAlphaComponent(0.35).setFill()
            NSRect(x: x, y: 0, width: max(0, min(w, totalW - x)), height: bounds.height).fill()
        }

        NSColor.separatorColor.setStroke()
        path.stroke()
    }

    // MARK: - Tooltips

    /// Per-rect tooltips so each coloured segment has its own hover label.
    /// We register `self` as the owner — AppKit doesn't retain the owner, so
    /// passing temporary NSStrings is a use-after-free (crashes when the
    /// hover timer fires). Self is guaranteed to outlive the rects.
    private func rebuildTooltips() {
        removeAllToolTips()
        tooltipText.removeAll()
        guard usage.ctx > 0, bounds.width > 0 else { return }
        let totalW = bounds.width
        var x: CGFloat = 0

        for segment in segments() {
            guard segment.tokens > 0 else { continue }
            let w = CGFloat(segment.tokens) / CGFloat(usage.ctx) * totalW
            let rect = NSRect(x: x, y: 0, width: w, height: bounds.height)
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltipText[tag] = "\(segment.label) · \(segment.tokens) tok"
            x += w
        }
        if usage.replyReserve > 0 {
            let w = CGFloat(usage.replyReserve) / CGFloat(usage.ctx) * totalW
            let rect = NSRect(x: x, y: 0,
                              width: max(0, min(w, totalW - x)),
                              height: bounds.height)
            let tag = addToolTip(rect, owner: self, userData: nil)
            tooltipText[tag] = "Reply reserve — tokens held back for the model's next reply · \(usage.replyReserve) tok"
        }
    }

    /// Implements the informal `NSViewToolTipOwner` protocol so AppKit can
    /// pull the per-rect label from `tooltipText` on hover.
    @objc func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag,
                    point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        tooltipText[tag] ?? ""
    }

    override func resizeSubviews(withOldSize oldSize: NSSize) {
        super.resizeSubviews(withOldSize: oldSize)
        rebuildTooltips()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildTooltips()
    }
}

final class StatusBar: NSView {
    private let leftLabel = NSTextField(labelWithString: "")
    private let embedLabel = NSTextField(labelWithString: "")
    private let activityIndicator = NSProgressIndicator()
    private let activityLabel = NSTextField(labelWithString: "")
    private let bar = CtxFillBar()
    private let ctxLabel = NSTextField(labelWithString: "")
    private let tpsLabel = NSTextField(labelWithString: "")
    /// Per-chat cumulative `prompt-tokens / reply-tokens` counter, anchored
    /// to the trailing edge. Increments are driven from `AppState` —
    /// prompt side at send time, reply side from kobold's perf endpoint.
    private let totalsLabel = NSTextField(labelWithString: "")
    private var activityTimer: Timer?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        applyFonts()
        for l in [leftLabel, embedLabel, ctxLabel, tpsLabel, totalsLabel] {
            l.textColor = .secondaryLabelColor
        }

        leftLabel.lineBreakMode = .byTruncatingTail
        embedLabel.lineBreakMode = .byTruncatingTail
        activityLabel.lineBreakMode = .byTruncatingTail
        leftLabel.translatesAutoresizingMaskIntoConstraints = false
        embedLabel.translatesAutoresizingMaskIntoConstraints = false
        activityIndicator.translatesAutoresizingMaskIntoConstraints = false
        activityLabel.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        ctxLabel.translatesAutoresizingMaskIntoConstraints = false
        tpsLabel.translatesAutoresizingMaskIntoConstraints = false
        totalsLabel.translatesAutoresizingMaskIntoConstraints = false
        totalsLabel.toolTip = "Cumulative prompt/reply tokens for this chat"

        activityIndicator.style = .spinning
        activityIndicator.controlSize = .small
        activityIndicator.isDisplayedWhenStopped = false
        activityIndicator.isIndeterminate = true

        addSubview(leftLabel)
        addSubview(embedLabel)
        addSubview(activityIndicator)
        addSubview(activityLabel)
        addSubview(bar)
        addSubview(ctxLabel)
        addSubview(tpsLabel)
        addSubview(totalsLabel)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),

            leftLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            leftLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            embedLabel.leadingAnchor.constraint(equalTo: leftLabel.trailingAnchor, constant: 10),
            embedLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            activityIndicator.leadingAnchor.constraint(equalTo: embedLabel.trailingAnchor, constant: 10),
            activityIndicator.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityIndicator.widthAnchor.constraint(equalToConstant: 14),
            activityIndicator.heightAnchor.constraint(equalToConstant: 14),

            activityLabel.leadingAnchor.constraint(equalTo: activityIndicator.trailingAnchor, constant: 6),
            activityLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            activityLabel.trailingAnchor.constraint(lessThanOrEqualTo: bar.leadingAnchor, constant: -10),

            bar.centerYAnchor.constraint(equalTo: centerYAnchor),
            bar.widthAnchor.constraint(equalToConstant: 160),
            bar.heightAnchor.constraint(equalToConstant: 10),
            bar.trailingAnchor.constraint(equalTo: ctxLabel.leadingAnchor, constant: -8),

            ctxLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            ctxLabel.trailingAnchor.constraint(equalTo: tpsLabel.leadingAnchor, constant: -12),

            tpsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            tpsLabel.trailingAnchor.constraint(equalTo: totalsLabel.leadingAnchor, constant: -12),

            totalsLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            totalsLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -12)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.statusChanged, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleServerReachableChanged),
            name: AppNotification.serverReachableChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleFontChanged),
            name: AppNotification.fontChanged, object: nil)
        refresh()
    }

    /// Pop a non-modal NSAlert as a window-attached sheet on the
    /// reachable→unreachable edge. The status-bar marker stays up
    /// continuously; the sheet is the one-shot "you should know" nudge.
    @objc private func handleServerReachableChanged() {
        refresh()
        let s = AppState.shared
        guard !s.serverReachable, let window = self.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Lost connection to the koboldcpp server"
        alert.informativeText = s.lastServerError.map {
            "RPClient stopped getting responses from the configured server.\n\nLast error: \($0)\n\nGenerations and side-calls will fail until the server is reachable again. The status bar will clear automatically once it comes back."
        } ?? "RPClient stopped getting responses from the configured server.\n\nGenerations and side-calls will fail until the server is reachable again. The status bar will clear automatically once it comes back."
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func applyFonts() {
        for l in [leftLabel, embedLabel, ctxLabel, tpsLabel, totalsLabel] {
            l.font = Theme.mono(11)
        }
        activityLabel.font = Theme.mono(11, weight: .semibold)
    }

    @objc private func handleFontChanged() {
        applyFonts()
        invalidateIntrinsicContentSize()
    }

    required init?(coder: NSCoder) { nil }

    deinit {
        NotificationCenter.default.removeObserver(self)
        activityTimer?.invalidate()
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @objc func refresh() {
        let s = AppState.shared
        let template = s.currentChat.map { Templates.byId($0.templateId).name } ?? "—"
        let ctx = s.effectiveContext
        let usage = s.lastUsage
        let used = usage.prompt

        if s.serverReachable {
            leftLabel.attributedStringValue = NSAttributedString(
                string: "\(s.modelName)  ·  \(template)",
                attributes: [.foregroundColor: NSColor.labelColor,
                             .font: Theme.mono(11)]
            )
            leftLabel.toolTip = nil
        } else {
            // Hard-to-miss red marker — this is the moment the user wants to
            // notice. Tooltip carries the underlying NSURLError for debugging.
            let attr = NSMutableAttributedString(
                string: "⚠ server offline",
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: Theme.mono(11, weight: .semibold)]
            )
            attr.append(NSAttributedString(
                string: "  ·  \(template)",
                attributes: [.foregroundColor: NSColor.secondaryLabelColor,
                             .font: Theme.mono(11)]
            ))
            leftLabel.attributedStringValue = attr
            leftLabel.toolTip = s.lastServerError.map { "Last error: \($0)" }
                ?? "No response from the koboldcpp server."
        }
        embedLabel.stringValue = formatEmbed(s)
        bar.usage = usage
        ctxLabel.stringValue = "\(used) / \(ctx) tok"
        ctxLabel.textColor = used > ctx - usage.replyReserve ? .systemRed : .secondaryLabelColor
        tpsLabel.stringValue = formatPerf(s)
        totalsLabel.attributedStringValue = formatTotals(s.currentChat)

        refreshActivity(s)
    }

    /// Format the per-chat cumulative-token counter. Compact "↑P ↓R" with
    /// k-suffix once a count crosses 10k so the label stays under ~12 chars.
    /// Numbers render in primary label colour so they pop against the rest
    /// of the secondary-coloured status bar; the arrows stay dim. Empty
    /// when there's no chat selected.
    private func formatTotals(_ chat: Chat?) -> NSAttributedString {
        guard let c = chat else { return NSAttributedString() }
        let dim: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.secondaryLabelColor,
            .font: Theme.mono(11)
        ]
        let bright: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor.labelColor,
            .font: Theme.mono(11, weight: .semibold)
        ]
        let s = NSMutableAttributedString()
        s.append(NSAttributedString(string: "↑ ", attributes: dim))
        s.append(NSAttributedString(string: formatTokenCount(c.tokensSent), attributes: bright))
        s.append(NSAttributedString(string: "  ↓ ", attributes: dim))
        s.append(NSAttributedString(string: formatTokenCount(c.tokensReceived), attributes: bright))
        return s
    }

    private func formatTokenCount(_ n: Int) -> String {
        if n < 10_000 { return "\(n)" }
        if n < 1_000_000 {
            let k = Double(n) / 1000.0
            return String(format: k >= 100 ? "%.0fk" : "%.1fk", k)
        }
        let m = Double(n) / 1_000_000.0
        return String(format: m >= 10 ? "%.0fM" : "%.1fM", m)
    }

    /// Renders the activity badge (spinner + coloured "summarising 1.2s" text)
    /// for whatever is currently running. Drives a 4Hz timer so the elapsed
    /// time ticks while work is in flight.
    private func refreshActivity(_ s: AppState) {
        var bits: [(label: String, color: NSColor)] = []
        if s.isRetrieving, let start = s.retrievingStart {
            bits.append(("retrieving \(elapsed(start))", .systemPink))
        }
        if s.isSummarizing, let start = s.summarizingStart {
            bits.append(("summarising \(elapsed(start))", .systemPurple))
        }
        if s.isIndexing, let start = s.indexingStart {
            bits.append(("indexing \(elapsed(start))", .systemTeal))
        }
        if s.isExtracting, let start = s.extractingStart {
            bits.append(("extracting \(elapsed(start))", .systemYellow))
        }

        if bits.isEmpty {
            activityIndicator.stopAnimation(nil)
            activityLabel.stringValue = ""
            stopActivityTimer()
        } else {
            activityIndicator.startAnimation(nil)
            let attr = NSMutableAttributedString()
            for (i, b) in bits.enumerated() {
                if i > 0 {
                    attr.append(NSAttributedString(
                        string: "  ·  ",
                        attributes: [.foregroundColor: NSColor.tertiaryLabelColor,
                                     .font: Theme.mono(11)]
                    ))
                }
                attr.append(NSAttributedString(
                    string: b.label,
                    attributes: [.foregroundColor: b.color,
                                 .font: Theme.mono(11, weight: .semibold)]
                ))
            }
            activityLabel.attributedStringValue = attr
            startActivityTimer()
        }
    }

    private func elapsed(_ start: Date) -> String {
        String(format: "%.1fs", Date().timeIntervalSince(start))
    }

    private func startActivityTimer() {
        guard activityTimer == nil else { return }
        activityTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.refreshActivity(AppState.shared)
        }
    }

    private func stopActivityTimer() {
        activityTimer?.invalidate()
        activityTimer = nil
    }

    private func formatEmbed(_ s: AppState) -> String {
        guard let dim = s.embeddingDim else {
            return "embed: not loaded"
        }
        if let name = s.embeddingModel {
            return "embed: \(shortName(name)) \(dim)d"
        }
        return "embed: loaded · \(dim)d"
    }

    private func shortName(_ s: String) -> String {
        // Strip path-like prefixes and common .gguf suffix so the bar stays compact.
        let last = (s as NSString).lastPathComponent
        let stem = last.hasSuffix(".gguf") ? String(last.dropLast(5)) : last
        return stem.count > 32 ? String(stem.prefix(29)) + "…" : stem
    }

    private func formatPerf(_ s: AppState) -> String {
        var bits: [String] = []
        if let ttft = s.lastTTFT {
            bits.append(String(format: "TTFT %.1fs", ttft))
        }
        if let pp = s.lastPromptProcessTime {
            bits.append(String(format: "prefill %.1fs", pp))
        }
        if s.lastTokensPerSec > 0 {
            bits.append(String(format: "%.1f t/s", s.lastTokensPerSec))
        }
        if let r = s.lastCacheRatio {
            bits.append(String(format: "cache %.0f%%", r * 100))
        }
        return bits.isEmpty ? "—" : bits.joined(separator: "  ·  ")
    }
}
