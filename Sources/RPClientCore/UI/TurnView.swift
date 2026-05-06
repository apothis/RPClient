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
    /// Phase 7 §3.3b — gutter glyph clicked. The delegate presents a
    /// popover anchored at `anchor` listing sibling branches, letting the
    /// user pick one to switch to (`AppState.switchBranch`).
    func turnViewDidRequestSiblingPopover(_ view: TurnView, anchor: NSView)
    /// Phase 7 §3.3+ — toolbar branch-fork button clicked. Equivalent to
    /// Cmd-B: creates a new sibling under this turn's parent and streams
    /// into it. Surfaced on every assistant turn that has a parent (i.e.
    /// not the root), so users don't have to think about which turn the
    /// keyboard shortcut targets.
    func turnViewDidRequestForkFrom(_ view: TurnView)
    /// Phase 8 deferred polish — replay this turn's audio fresh
    /// (re-runs attribution + dispatch; no cached audio). Bypasses
    /// per-chat voice mute. Surfaced on every assistant turn so debug
    /// iterations on attribution / voice assignment can be tested
    /// without regenerating the reply text.
    func turnViewDidRequestReplayAudio(_ view: TurnView)
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
    /// Assistant-side speaker indicator. V2_PLAN §6.2 — when the chat has a
    /// character attached, this carries the character avatar resolved via
    /// `AvatarSource`; otherwise it falls back to a tinted ✦ rendered through
    /// `placeholderAvatar` so character-less chats keep their current
    /// visual signature.
    private let avatar = NSImageView()

    private let toolbar = NSStackView()
    private let copyButton: NSButton
    private let replayButton: NSButton
    private let editButton: NSButton
    private let regenButton: NSButton
    /// Phase 7 §3.3+ — explicit "fork from this reply" toolbar button.
    /// Hover-revealed alongside regen on every assistant turn that has a
    /// parent (i.e., not the root greeting). Fires the same path as Cmd-B.
    private let forkButton: NSButton
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
    /// Phase 7 §3.3b — branch-sibling glyph in the gutter. Visible only
    /// when `hasSiblings` is true (i.e., this turn's parent has more than
    /// one child). Click → delegate presents a sibling-list popover.
    private let branchGlyph: NSButton

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

    /// Phase 7 §3.3b — true when this turn's parent has more than one
    /// child (i.e., switching branches is meaningful here). Drives the
    /// gutter glyph's visibility. Set by ChatViewController during rebuild.
    var hasSiblings: Bool = false {
        didSet {
            guard oldValue != hasSiblings else { return }
            branchGlyph.isHidden = !hasSiblings
            updateBranchGlyphLabel()
        }
    }

    /// Total siblings (parent's child count, including this one). Used to
    /// render the inline "N/M" label on the gutter glyph so the user
    /// knows there are alternatives without having to open the popover.
    /// Set by ChatViewController.
    var siblingCount: Int = 1 {
        didSet { updateBranchGlyphLabel() }
    }

    /// 1-based index of this turn within its parent's children (sorted by
    /// ts). Drives the "N" in "N/M".
    var siblingIndex: Int = 1 {
        didSet { updateBranchGlyphLabel() }
    }

    /// Phase 7 §3.3+ — toolbar fork button only makes sense on assistant
    /// turns that have a parent (the root greeting can't be forked from).
    /// Set by ChatViewController during rebuild.
    var canFork: Bool = false {
        didSet {
            guard oldValue != canFork else { return }
            updateToolbarForEditState()
        }
    }

    private func updateBranchGlyphLabel() {
        guard hasSiblings, siblingCount > 1 else {
            branchGlyph.title = ""
            branchGlyph.imagePosition = .imageOnly
            return
        }
        branchGlyph.title = " \(siblingIndex)/\(siblingCount)"
        branchGlyph.imagePosition = .imageLeading
        branchGlyph.font = Theme.font(11, weight: .medium)
    }

    /// Toggle the gutter glyph's "selected" appearance — set true while
    /// the sibling popover is open so the user has a clear visual anchor
    /// back to where they clicked. ChatViewController flips this on
    /// present and back off when the popover closes.
    func setBranchPopoverOpen(_ open: Bool) {
        // controlAccentColor when open (matches the active sibling row in
        // the popover); slightly faded accent when closed (the default
        // "this turn has alternatives" signal).
        if open {
            branchGlyph.contentTintColor = .controlAccentColor
            branchGlyph.layer?.backgroundColor = NSColor.controlAccentColor
                .withAlphaComponent(0.18).cgColor
            branchGlyph.layer?.cornerRadius = 4
        } else {
            branchGlyph.contentTintColor = .controlAccentColor
            branchGlyph.layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

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
    /// Width of the leading speaker column on assistant turns. Reserves space
    /// for a 32-px circular avatar (V2_PLAN §6.2) plus an 8-px gap before the
    /// reply bubble starts.
    private let glyphCol: CGFloat = 40
    private let avatarSize: CGFloat = 32
    private let toolbarHeight: CGFloat = 22
    private let toolbarTopGap: CGFloat = 4

    /// Phase 8 §4.3 — speaker name label below the avatar on multi-cast
    /// chats. Nil on solo / free-form chats and on user turns. When set,
    /// the avatar also gets a 2pt accent ring (deterministic per
    /// `character.id`) so the chip reads at a glance even before the
    /// label is parsed.
    private var speakerNameLabel: NSTextField?
    private let multiCast: Bool

    /// Phase 8 §4.3 — vertical space reserved above the bubble for the
    /// speaker name pill. Zero when no speaker label is shown
    /// (solo / free-form chats and user turns). Read by both the
    /// constraint installer (offsets bubble + avatar by this) AND
    /// `recomputeHeight()` (adds it to total height so the bubble's
    /// content area isn't squeezed and the toolbar doesn't clip).
    private var speakerLabelHeight: CGFloat { speakerNameLabel != nil ? 18 : 0 }

    init(turn: Turn, character: Character? = nil, multiCast: Bool = false) {
        self.turnId = turn.id
        self.role = turn.role
        self.rawText = turn.text
        self.multiCast = multiCast

        copyButton = TurnView.makeIconButton(symbol: "doc.on.doc", tooltip: "Copy")
        replayButton = TurnView.makeIconButton(symbol: "speaker.wave.2", tooltip: "Replay audio")
        editButton = TurnView.makeIconButton(symbol: "pencil", tooltip: "Edit")
        regenButton = TurnView.makeIconButton(symbol: "arrow.clockwise", tooltip: "Regenerate")
        forkButton = TurnView.makeIconButton(symbol: "arrow.triangle.branch", tooltip: "Fork branch (⌘B)")
        continueButton = TurnView.makeIconButton(symbol: "arrow.forward", tooltip: "Continue")
        deleteButton = TurnView.makeIconButton(symbol: "trash", tooltip: "Delete")
        saveButton = TurnView.makeIconButton(symbol: "checkmark", tooltip: "Save (⌘↵)")
        cancelButton = TurnView.makeIconButton(symbol: "xmark", tooltip: "Cancel (esc)")
        prevVariantButton = TurnView.makeIconButton(symbol: "chevron.left", tooltip: "Previous variant (⌘←)")
        nextVariantButton = TurnView.makeIconButton(symbol: "chevron.right", tooltip: "Next variant (⌘→)")
        discardVariantButton = TurnView.makeIconButton(symbol: "minus.circle", tooltip: "Discard this variant")
        branchGlyph = TurnView.makeIconButton(
            symbol: "arrow.triangle.branch",
            tooltip: "Switch branch — this turn has siblings"
        )
        // Phase 7 §3.3b — branch glyph stands out more than the hover-toolbar
        // icons because it's persistent (not hover-revealed). Accent tint + a
        // larger point size makes it skim-readable without crowding the
        // gutter. Tone down later if it feels loud.
        branchGlyph.contentTintColor = .controlAccentColor
        if let img = NSImage(systemSymbolName: "arrow.triangle.branch", accessibilityDescription: nil) {
            branchGlyph.image = img.withSymbolConfiguration(
                NSImage.SymbolConfiguration(pointSize: 14, weight: .semibold)
            ) ?? img
        }

        super.init(frame: .zero)
        wantsLayer = true

        bubble.wantsLayer = true
        if role == .user {
            bubble.layer?.cornerRadius = 14
        }
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        if role == .assistant {
            avatar.imageScaling = .scaleProportionallyUpOrDown
            avatar.wantsLayer = true
            avatar.layer?.cornerRadius = avatarSize / 2
            avatar.layer?.masksToBounds = true
            avatar.translatesAutoresizingMaskIntoConstraints = false
            if let character {
                avatar.image = AvatarSource.shared.image(
                    forCharacter: character.id, name: character.name)
                avatar.toolTip = character.name
            } else {
                avatar.image = placeholderAvatar(initials: "✦")
            }
            // Phase 8 §4.3 — speaker chip. Multi-cast chats get a 3pt
            // accent ring around the avatar (deterministic per character
            // id) and a full-width name pill ABOVE the bubble, in the
            // accent colour, so the speaker is identifiable at a glance
            // without truncating long names. Below-avatar labels (the
            // original design) topped out at the 40px gutter width and
            // truncated names like "Captain Marin" to "Capt…", which
            // didn't read as a speaker chip — it read as a layout bug.
            if multiCast, let character {
                let accent = SpeakerColor.accent(for: character.id)
                avatar.layer?.borderColor = accent.cgColor
                avatar.layer?.borderWidth = 3
                let label = NSTextField(labelWithString: character.name)
                label.font = Theme.font(11, weight: .semibold)
                label.textColor = accent
                label.alignment = .left
                label.lineBreakMode = .byTruncatingTail
                label.maximumNumberOfLines = 1
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
                speakerNameLabel = label
            }
            addSubview(avatar)
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
        replayButton.target = self;   replayButton.action   = #selector(replayTapped)
        editButton.target = self;     editButton.action     = #selector(editTapped)
        regenButton.target = self;    regenButton.action    = #selector(regenTapped)
        forkButton.target = self;     forkButton.action     = #selector(forkTapped)
        continueButton.target = self; continueButton.action = #selector(continueTapped)
        deleteButton.target = self;   deleteButton.action   = #selector(deleteTapped)
        saveButton.target = self;     saveButton.action     = #selector(saveTapped)
        cancelButton.target = self;   cancelButton.action   = #selector(cancelTapped)
        prevVariantButton.target = self; prevVariantButton.action = #selector(prevVariantTapped)
        nextVariantButton.target = self; nextVariantButton.action = #selector(nextVariantTapped)
        discardVariantButton.target = self; discardVariantButton.action = #selector(discardVariantTapped)
        branchGlyph.target = self; branchGlyph.action = #selector(branchGlyphTapped)
        branchGlyph.isHidden = true
        branchGlyph.wantsLayer = true
        branchGlyph.translatesAutoresizingMaskIntoConstraints = false
        addSubview(branchGlyph)

        saveButton.contentTintColor = .systemBlue
        cancelButton.contentTintColor = .secondaryLabelColor

        // Initially hidden — non-last-assistant doesn't show regen/continue.
        regenButton.isHidden = !(role == .assistant)
        // Fork button shows on every assistant turn (not just trailing) so
        // the user can fork from any reply via the UI. Final visibility is
        // gated in `updateToolbarForEditState` once parentId is known.
        forkButton.isHidden = !(role == .assistant)
        continueButton.isHidden = !(role == .assistant)
        // Phase 8 deferred polish — replay button shows on every
        // assistant turn so the user can re-trigger TTS for any
        // historic reply (not just the trailing one) without
        // regenerating the text. Hidden on user turns.
        replayButton.isHidden = !(role == .assistant)
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
                  copyButton, editButton, regenButton, forkButton, continueButton, replayButton, deleteButton,
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
                toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),

                // Branch glyph sits just outside the bubble's leading edge,
                // top-aligned with the bubble. User turns are right-aligned
                // so we have free real estate on the left.
                branchGlyph.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 2),
                branchGlyph.trailingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: -6)
            ])
        } else {
            // Phase 8 §4.3 — speaker name label above the bubble (when
            // multi-cast). The label sits in the same vertical track as
            // the bubble's top edge, leading-aligned with the bubble, so
            // it reads as a header for the message. Avatar slides down
            // by `speakerLabelHeight` to stay top-aligned with the
            // bubble's header. recomputeHeight reads the same ivar so
            // the TurnView's outer height includes this offset — the
            // first version of this code computed the offset locally
            // and forgot to plumb it into the height calc, which clipped
            // the toolbar + made the textView scroll instead of expand.
            let labelGap = speakerLabelHeight

            NSLayoutConstraint.activate([
                avatar.topAnchor.constraint(equalTo: topAnchor, constant: labelGap),
                avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
                avatar.widthAnchor.constraint(equalToConstant: avatarSize),
                avatar.heightAnchor.constraint(equalToConstant: avatarSize),

                bubble.topAnchor.constraint(equalTo: topAnchor, constant: labelGap),
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: glyphCol),
                bubble.trailingAnchor.constraint(equalTo: trailingAnchor),

                scrollView.topAnchor.constraint(equalTo: bubble.topAnchor),
                scrollView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor),

                toolbar.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                toolbar.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
                toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),

                branchGlyph.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: 6),
                branchGlyph.centerXAnchor.constraint(equalTo: avatar.centerXAnchor)
            ])
            if let nameLabel = speakerNameLabel {
                NSLayoutConstraint.activate([
                    nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                    nameLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                    nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor),
                    nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bubble.topAnchor, constant: -2)
                ])
            }
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

    @objc private func forkTapped() {
        delegate?.turnViewDidRequestForkFrom(self)
    }

    @objc private func continueTapped() {
        delegate?.turnViewDidRequestContinue(self)
    }

    @objc private func replayTapped() {
        delegate?.turnViewDidRequestReplayAudio(self)
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

    @objc private func branchGlyphTapped() {
        delegate?.turnViewDidRequestSiblingPopover(self, anchor: branchGlyph)
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
        forkButton.isHidden = editing || !(role == .assistant && canFork)
        continueButton.isHidden = editing || !(role == .assistant && isLastAssistant)
        // Phase 8 deferred polish — replay button visible on every
        // assistant turn (not just the trailing one), hidden during
        // edit. Lets the user re-trigger TTS for any historic reply
        // to debug attribution / voice assignment without regenerating.
        replayButton.isHidden = editing || role != .assistant
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
            avatar.layer?.add(pulse, forKey: "streamPulse")
        } else {
            avatar.layer?.removeAnimation(forKey: "streamPulse")
            avatar.layer?.opacity = 1.0
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
        // Phase 8 §4.3 — `speakerLabelHeight` is the gap reserved above
        // the bubble for the multi-cast speaker name pill (zero on solo
        // chats / user turns). Without adding it here, the bubble's
        // content area is squeezed and the textView scrolls instead of
        // expanding to fit the reply.
        let h = speakerLabelHeight + bubbleH + toolbarTopGap + toolbarHeight
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
