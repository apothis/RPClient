import AppKit

protocol TurnViewDelegate: AnyObject {
    func turnViewDidEditText(_ view: TurnView, newText: String)
    func turnViewDidRequestDelete(_ view: TurnView)
    func turnViewDidRequestCopy(_ view: TurnView)
    func turnViewDidRequestRegen(_ view: TurnView)
    func turnViewDidRequestContinue(_ view: TurnView)
    /// Page back through the swipe variants on this assistant turn.
    func turnViewDidRequestPreviousVariant(_ view: TurnView)
    /// Page forward through the swipe variants. The delegate decides whether
    /// to page or to extend past the last variant (which generates a new one
    /// on the trailing assistant turn).
    func turnViewDidRequestNextVariant(_ view: TurnView)
    /// Drop the currently-active variant on this turn (count > 1 only —
    /// the button only appears when there's something to fall back to).
    func turnViewDidRequestDiscardVariant(_ view: TurnView)
}

private final class FocusAwareTextView: NSTextView {
    var onBecomeFirstResponder: (() -> Void)?
    var onResignFirstResponder: (() -> Void)?
    var onCommitEdit: (() -> Void)?
    var onCancelEdit: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let r = super.becomeFirstResponder()
        if r { onBecomeFirstResponder?() }
        return r
    }

    override func resignFirstResponder() -> Bool {
        let r = super.resignFirstResponder()
        if r { onResignFirstResponder?() }
        return r
    }

    override func cancelOperation(_ sender: Any?) {
        onCancelEdit?()
    }

    override func keyDown(with event: NSEvent) {
        // Cmd+Return commits.
        if event.modifierFlags.contains(.command),
           event.keyCode == 36 || event.keyCode == 76 {
            onCommitEdit?()
            return
        }
        super.keyDown(with: event)
    }
}

final class TurnView: NSView, NSTextViewDelegate {
    weak var delegate: TurnViewDelegate?
    let turnId: UUID
    let role: TurnRole

    private let bubble = NSView()
    private let textView = FocusAwareTextView()
    private let scrollView = NSScrollView()
    private let glyph = NSTextField(labelWithString: "")

    private let toolbar = NSStackView()
    private let copyButton: NSButton
    private let editButton: NSButton
    private let regenButton: NSButton
    private let continueButton: NSButton
    private let deleteButton: NSButton
    private let saveButton: NSButton
    private let cancelButton: NSButton
    /// Variant pager: ◀ N/M ▶. Lives at the start of the toolbar so it
    /// hover-reveals alongside the other actions. All four pager controls
    /// (including the discard button) stay hidden until `setVariantState`
    /// reports a swipe-set worth showing.
    private let prevVariantButton: NSButton
    private let nextVariantButton: NSButton
    private let variantLabel = NSTextField(labelWithString: "")
    /// Discards the active variant. Only meaningful when count > 1 so it
    /// shares the same visibility gate as the rest of the pager.
    private let discardVariantButton: NSButton

    private var baseFont: NSFont { Theme.font(15) }

    private var rawText: String = ""
    private var isEditing: Bool = false {
        didSet {
            guard oldValue != isEditing else { return }
            updateToolbarForEditState()
        }
    }

    /// The last assistant turn shows Regen/Continue; others hide them.
    var isLastAssistant: Bool = false {
        didSet {
            guard oldValue != isLastAssistant else { return }
            updateToolbarForEditState()
            refreshVariantPagerEnabled()
        }
    }

    /// Number of swipe variants on this assistant turn. Drives the pager
    /// visibility (hidden at ≤ 1 to avoid clutter on the common single-reply
    /// case) and the disabled state of the ◀ / ▶ controls.
    private(set) var variantCount: Int = 0
    /// Active swipe index. Reflected in the "N / M" label.
    private(set) var activeVariantIndex: Int = 0
    /// True when the active variant's recorded context fingerprint no longer
    /// matches the live chat prefix — see `Chat.isVariantStale`. Drives the
    /// ⚠ badge appended to the pager label.
    private(set) var activeIsStale: Bool = false

    func setVariantState(active: Int, count: Int, activeIsStale: Bool = false) {
        guard activeVariantIndex != active
            || variantCount != count
            || self.activeIsStale != activeIsStale else { return }
        activeVariantIndex = active
        variantCount = count
        self.activeIsStale = activeIsStale
        if count > 1 {
            // Trailing ⚠ flags variants whose upstream context has changed
            // since they were generated — see Chat.isVariantStale.
            variantLabel.stringValue = activeIsStale
                ? "\(active + 1) / \(count) ⚠"
                : "\(active + 1) / \(count)"
            variantLabel.toolTip = activeIsStale
                ? "Generated against an earlier version of the chat — discard or pin."
                : nil
        } else {
            variantLabel.stringValue = ""
            variantLabel.toolTip = nil
        }
        let show = role == .assistant && count > 1
        prevVariantButton.isHidden = !show
        variantLabel.isHidden = !show
        nextVariantButton.isHidden = !show
        discardVariantButton.isHidden = !show
        refreshVariantPagerEnabled()
    }

    private func refreshVariantPagerEnabled() {
        let busy = isStreaming
        prevVariantButton.isEnabled = !busy && activeVariantIndex > 0
        // ▶ is enabled when there's a next variant, OR when this is the
        // trailing assistant (delegate extends past end by generating a new
        // variant). Disabled mid-stream regardless.
        let canPage = activeVariantIndex < variantCount - 1
        nextVariantButton.isEnabled = !busy && (canPage || isLastAssistant)
        // Discard requires at least 2 variants and a quiet stream.
        discardVariantButton.isEnabled = !busy && variantCount > 1
    }

    private var isHovering: Bool = false

    /// Pulses the assistant glyph; suppresses hover toolbar reveal while true.
    var isStreaming: Bool = false {
        didSet {
            guard isStreaming != oldValue else { return }
            updateStreamingIndicator()
            refreshVariantPagerEnabled()
        }
    }

    /// True while the model is mid-`<think>` block on the active stream.
    /// Replaces the bubble body with a "Thinking…" placeholder so the user
    /// has a visible signal that work is happening before the reply text
    /// starts to flow. Cleared when the close tag is seen or the stream
    /// finishes.
    var isThinking: Bool = false {
        didSet {
            guard isThinking != oldValue else { return }
            renderRendered()
            recomputeHeight()
        }
    }

    private let bubblePadX: CGFloat = 14
    private let bubblePadY: CGFloat = 10
    private let glyphCol: CGFloat = 28
    private let toolbarHeight: CGFloat = 22
    private let toolbarTopGap: CGFloat = 4

    init(turn: Turn) {
        self.turnId = turn.id
        self.role = turn.role
        self.rawText = turn.text

        copyButton = TurnView.makeIconButton(symbol: "doc.on.doc", tooltip: "Copy")
        editButton = TurnView.makeIconButton(symbol: "pencil", tooltip: "Edit")
        regenButton = TurnView.makeIconButton(symbol: "arrow.clockwise", tooltip: "Regenerate")
        continueButton = TurnView.makeIconButton(symbol: "arrow.forward", tooltip: "Continue")
        deleteButton = TurnView.makeIconButton(symbol: "trash", tooltip: "Delete")
        saveButton = TurnView.makeIconButton(symbol: "checkmark", tooltip: "Save (⌘↵)")
        cancelButton = TurnView.makeIconButton(symbol: "xmark", tooltip: "Cancel (esc)")
        prevVariantButton = TurnView.makeIconButton(symbol: "chevron.left", tooltip: "Previous variant (⌘←)")
        nextVariantButton = TurnView.makeIconButton(symbol: "chevron.right", tooltip: "Next variant (⌘→)")
        discardVariantButton = TurnView.makeIconButton(symbol: "minus.circle", tooltip: "Discard this variant")

        super.init(frame: .zero)
        wantsLayer = true

        bubble.wantsLayer = true
        if role == .user {
            bubble.layer?.cornerRadius = 14
        }
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        if role == .assistant {
            glyph.stringValue = "✦"
            glyph.font = Theme.font(15, weight: .semibold)
            glyph.textColor = .secondaryLabelColor
            glyph.wantsLayer = true
            glyph.translatesAutoresizingMaskIntoConstraints = false
            addSubview(glyph)
        }

        textView.isRichText = true
        textView.font = baseFont
        textView.delegate = self
        textView.allowsUndo = true
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 24)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.drawsBackground = false
        textView.onBecomeFirstResponder = { [weak self] in self?.enterEditMode() }
        textView.onResignFirstResponder = { [weak self] in self?.exitEditMode() }
        textView.onCommitEdit = { [weak self] in self?.commitEdit() }
        textView.onCancelEdit = { [weak self] in self?.cancelEdit() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(scrollView)

        copyButton.target = self;     copyButton.action     = #selector(copyTapped)
        editButton.target = self;     editButton.action     = #selector(editTapped)
        regenButton.target = self;    regenButton.action    = #selector(regenTapped)
        continueButton.target = self; continueButton.action = #selector(continueTapped)
        deleteButton.target = self;   deleteButton.action   = #selector(deleteTapped)
        saveButton.target = self;     saveButton.action     = #selector(saveTapped)
        cancelButton.target = self;   cancelButton.action   = #selector(cancelTapped)
        prevVariantButton.target = self; prevVariantButton.action = #selector(prevVariantTapped)
        nextVariantButton.target = self; nextVariantButton.action = #selector(nextVariantTapped)
        discardVariantButton.target = self; discardVariantButton.action = #selector(discardVariantTapped)

        saveButton.contentTintColor = .systemBlue
        cancelButton.contentTintColor = .secondaryLabelColor

        // Initially hidden — non-last-assistant doesn't show regen/continue.
        regenButton.isHidden = !(role == .assistant)
        continueButton.isHidden = !(role == .assistant)
        saveButton.isHidden = true
        cancelButton.isHidden = true
        // Pager stays hidden until setVariantState reports >1 variant.
        prevVariantButton.isHidden = true
        nextVariantButton.isHidden = true
        variantLabel.isHidden = true
        discardVariantButton.isHidden = true

        variantLabel.font = Theme.font(11, weight: .medium)
        variantLabel.textColor = .secondaryLabelColor
        variantLabel.alignment = .center
        variantLabel.translatesAutoresizingMaskIntoConstraints = false
        // Reserve width for "NN / NN" so the label doesn't wiggle as the
        // active index changes.
        variantLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.alphaValue = 0
        for b in [prevVariantButton as NSView, variantLabel, nextVariantButton,
                  discardVariantButton,
                  copyButton, editButton, regenButton, continueButton, deleteButton,
                  saveButton, cancelButton] {
            toolbar.addArrangedSubview(b)
        }
        addSubview(toolbar)

        installConstraints()

        renderRendered()
        recomputeHeight()
    }

    required init?(coder: NSCoder) { nil }

    private static func makeIconButton(symbol: String, tooltip: String) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tooltip)
        let btn = NSButton(image: img ?? NSImage(), target: nil, action: nil)
        btn.bezelStyle = .inline
        btn.isBordered = false
        btn.imagePosition = .imageOnly
        btn.imageScaling = .scaleProportionallyDown
        btn.contentTintColor = .secondaryLabelColor
        btn.toolTip = tooltip
        btn.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            btn.widthAnchor.constraint(equalToConstant: 22),
            btn.heightAnchor.constraint(equalToConstant: 22)
        ])
        return btn
    }

    private func installConstraints() {
        if role == .user {
            NSLayoutConstraint.activate([
                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),
                bubble.widthAnchor.constraint(
                    equalTo: widthAnchor, multiplier: 0.78
                ),

                scrollView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: bubblePadY),
                scrollView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -bubblePadY),
                scrollView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: bubblePadX),
                scrollView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -bubblePadX),

                toolbar.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                toolbar.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
                toolbar.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        } else {
            NSLayoutConstraint.activate([
                glyph.topAnchor.constraint(equalTo: topAnchor, constant: 1),
                glyph.leadingAnchor.constraint(equalTo: leadingAnchor),
                glyph.widthAnchor.constraint(equalToConstant: glyphCol - 8),

                bubble.topAnchor.constraint(equalTo: topAnchor),
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: glyphCol),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),

                scrollView.topAnchor.constraint(equalTo: bubble.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),

                toolbar.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                toolbar.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
                toolbar.bottomAnchor.constraint(equalTo: bottomAnchor)
            ])
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        if role == .user {
            bubble.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        } else {
            bubble.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    func setText(_ s: String) {
        // Don't clobber a user's in-progress edit with chat-side updates
        // (e.g. stream tokens arriving on the very turn being edited).
        guard !isEditing else { return }
        rawText = s
        renderRendered()
        recomputeHeight()
    }

    var currentText: String { rawText }

    // MARK: - Toolbar actions

    @objc private func copyTapped() {
        delegate?.turnViewDidRequestCopy(self)
    }

    @objc private func editTapped() {
        window?.makeFirstResponder(textView)
    }

    @objc private func regenTapped() {
        delegate?.turnViewDidRequestRegen(self)
    }

    @objc private func continueTapped() {
        delegate?.turnViewDidRequestContinue(self)
    }

    @objc private func deleteTapped() {
        delegate?.turnViewDidRequestDelete(self)
    }

    @objc private func saveTapped() { commitEdit() }
    @objc private func cancelTapped() { cancelEdit() }

    @objc private func prevVariantTapped() {
        delegate?.turnViewDidRequestPreviousVariant(self)
    }

    @objc private func nextVariantTapped() {
        delegate?.turnViewDidRequestNextVariant(self)
    }

    @objc private func discardVariantTapped() {
        delegate?.turnViewDidRequestDiscardVariant(self)
    }

    /// Commit the user's pending edits and exit edit mode.
    private func commitEdit() {
        // Resigning fires onResignFirstResponder → exitEditMode, which saves.
        window?.makeFirstResponder(nil)
    }

    /// Discard pending edits, restore the rendered view, and exit edit mode.
    private func cancelEdit() {
        guard isEditing else { return }
        // Mark not-editing so the resign path skips the save branch.
        isEditing = false
        textView.string = rawText
        window?.makeFirstResponder(nil)
        renderRendered()
        recomputeHeight()
    }

    private func updateToolbarForEditState() {
        let editing = isEditing
        copyButton.isHidden = editing
        editButton.isHidden = editing
        regenButton.isHidden = editing || !(role == .assistant && isLastAssistant)
        continueButton.isHidden = editing || !(role == .assistant && isLastAssistant)
        deleteButton.isHidden = editing
        saveButton.isHidden = !editing
        cancelButton.isHidden = !editing
        // Pager visibility tracks both edit state and the variant count —
        // hide everywhere while editing (Save/Cancel are the only valid
        // actions), and otherwise only show when there's actually more than
        // one variant to page through.
        let showPager = !editing && role == .assistant && variantCount > 1
        prevVariantButton.isHidden = !showPager
        variantLabel.isHidden = !showPager
        nextVariantButton.isHidden = !showPager
        discardVariantButton.isHidden = !showPager
        if editing {
            // Force-visible while editing so the user sees Save/Cancel without hovering.
            toolbar.alphaValue = 1
        } else {
            toolbar.alphaValue = isHovering ? 1 : 0
        }
    }

    private func enterEditMode() {
        isEditing = true
        textView.string = rawText
        textView.font = baseFont
        recomputeHeight()
    }

    private func exitEditMode() {
        guard isEditing else { return }
        isEditing = false
        rawText = textView.string
        delegate?.turnViewDidEditText(self, newText: rawText)
        renderRendered()
        recomputeHeight()
    }

    private func renderRendered() {
        // While the model is mid-<think>, the bubble shows a placeholder
        // instead of rawText (which is empty anyway — the streaming filter
        // swallows everything inside the block). Italic + secondary colour
        // so it's visibly distinct from a real reply.
        if isThinking {
            let attr = NSMutableAttributedString(string: "Thinking…")
            let italic = NSFontManager.shared.convert(baseFont, toHaveTrait: .italicFontMask)
            attr.addAttributes(
                [.font: italic, .foregroundColor: NSColor.secondaryLabelColor],
                range: NSRange(location: 0, length: attr.length)
            )
            textView.textStorage?.setAttributedString(attr)
            return
        }
        let display: String
        if role == .assistant {
            display = Markdown.stripThinking(rawText)
        } else {
            display = rawText
        }
        let attr = Markdown.render(display, baseFont: baseFont)
        textView.textStorage?.setAttributedString(attr)
    }

    func textDidChange(_ notification: Notification) {
        recomputeHeight()
    }

    // MARK: - Hover reveal for toolbar

    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        guard !isStreaming, !isEditing else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            toolbar.animator().alphaValue = 1
        }
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        guard !isEditing else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.15
            toolbar.animator().alphaValue = 0
        }
    }

    private func updateStreamingIndicator() {
        guard role == .assistant else { return }
        if isStreaming {
            // Suppress toolbar even if hovered.
            toolbar.alphaValue = 0
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 1.0
            pulse.toValue = 0.25
            pulse.duration = 0.7
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            glyph.layer?.add(pulse, forKey: "streamPulse")
        } else {
            glyph.layer?.removeAnimation(forKey: "streamPulse")
            glyph.layer?.opacity = 1.0
        }
    }

    // MARK: - Sizing

    private var heightConstraint: NSLayoutConstraint?
    private var lastLaidOutWidth: CGFloat = -1

    override func layout() {
        super.layout()
        if abs(bounds.width - lastLaidOutWidth) > 0.5 {
            lastLaidOutWidth = bounds.width
            recomputeHeight()
        }
    }

    func recomputeHeight() {
        // Measure the attributed string at the width the bubble will actually
        // have. Doing this directly (rather than through textView.layoutManager)
        // decouples height from NSScrollView's documentView tile timing —
        // otherwise the first recompute can land before the textView has been
        // sized to the bubble, leaving the bubble pinned to a single line and
        // the rest of the message hidden behind a trackpad-only scroll.
        let availableW = currentTextWidth()
        let textH: CGFloat
        if availableW > 1, let storage = textView.textStorage, storage.length > 0 {
            let bbox = storage.boundingRect(
                with: NSSize(width: availableW, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            textH = max(24, ceil(bbox.height))
        } else {
            textH = 24
        }
        let bubbleH: CGFloat = role == .user ? textH + bubblePadY * 2 : textH
        let h = bubbleH + toolbarTopGap + toolbarHeight
        if heightConstraint == nil {
            heightConstraint = heightAnchor.constraint(equalToConstant: h)
            heightConstraint?.isActive = true
        } else if abs(heightConstraint!.constant - h) > 0.5 {
            heightConstraint?.constant = h
        }
    }

    /// Width the text inside the bubble will lay out into. Mirrors the bubble
    /// constraints in `installConstraints`. Returns 0 before first layout so
    /// `recomputeHeight` can fall back to a placeholder height.
    private func currentTextWidth() -> CGFloat {
        let parentW = bounds.width
        guard parentW > 1 else { return 0 }
        if role == .user {
            let bubbleW = parentW * 0.78
            return max(0, bubbleW - bubblePadX * 2)
        } else {
            return max(0, parentW - glyphCol)
        }
    }
}
