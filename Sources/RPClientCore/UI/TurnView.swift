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

    /// Wallclock the turn was recorded at. Read by the speaker-header
    /// timestamp label (V2_UI_OVERHAUL §4.3 — assistant turn header is
    /// `<name> · <time>`). Persisted from `turn.ts` at init time.
    private let turnTs: Date

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
    /// Width of the leading speaker column on assistant turns. Reserves
    /// space for the avatar gutter plus the avatar-to-body gap so the
    /// reply body starts at a consistent x-offset (V2_UI_OVERHAUL §4.3).
    /// Resolves to 40pt today (32 + 8); changes follow the design-language
    /// tokens, never a hardcoded literal.
    private let glyphCol: CGFloat = DesignTokens.Chat.avatarGutter
        + DesignTokens.Chat.avatarToBodyGap
    private let avatarSize: CGFloat = DesignTokens.Chat.avatarSize
    private let toolbarHeight: CGFloat = 22
    private let toolbarTopGap: CGFloat = 4

    /// V2_UI_OVERHAUL §4.3 — speaker name label above the bubble on
    /// every assistant turn (was multi-cast-only pre-§4.b). Multi-cast
    /// keeps the 3pt accent ring on the avatar and tints the name with
    /// the speaker accent for at-a-glance identification; solo chats
    /// use `labelColor`.
    private var speakerNameLabel: NSTextField?
    /// V2_UI_OVERHAUL §4.3 — timestamp companion to the speaker name
    /// label ("· 2:14 PM"). `caption1` size, `tertiaryLabelColor`.
    /// Created alongside `speakerNameLabel` when the row has one.
    private var timestampLabel: NSTextField?
    private let multiCast: Bool

    /// Vertical space reserved above the bubble for the speaker name
    /// header. Zero on user turns (handled separately in §4.c). Read
    /// by both the constraint installer AND `recomputeHeight()` so the
    /// row outer height includes the offset — the first version of
    /// this code computed the offset locally and forgot to plumb it
    /// into the height calc, which clipped the toolbar + made the
    /// textView scroll instead of expand.
    private var speakerLabelHeight: CGFloat { speakerNameLabel != nil ? 20 : 0 }

    /// V2_UI_OVERHAUL §4.0.a / §4.7 — `<think>` content extracted from
    /// the assistant body via `Markdown.extractThinking`. Surfaced as
    /// a "▸ Thinking" disclosure pill above the prose body; clicking
    /// the pill toggles inline expansion to show the trace in
    /// `secondaryLabelColor` body. Nil when the turn has no thinking
    /// block (or only an empty pre-fill, per Phase 10's finding).
    private var thinkingText: String?
    private var thinkingExpanded: Bool = false
    /// Phase 11 §D.11 — trace captured from the active variant at init
    /// time. Preferred over `Markdown.extractThinking(rawText)` when
    /// non-nil; the inline-extractor stays as a fallback for legacy
    /// chats whose text still has `<think>` tags embedded.
    private let persistedThinkingTrace: String?
    private let thinkPill = NSButton()
    private let thinkBodyView = NSTextField(wrappingLabelWithString: "")
    /// Bubble's top constraint, kept as an ivar so the disclosure
    /// state can update its constant: `labelGap + disclosureExtraHeight`.
    /// Owned by the assistant branch of `installConstraints`.
    private var bubbleTopConstraint: NSLayoutConstraint?
    /// V2_UI_OVERHAUL §4.7 — pill is `caption1` text + chevron icon,
    /// 20pt high (one-line). Constants pinned by the height-math
    /// tests; changes here require updating the test values too so
    /// the contract stays explicit.
    static let thinkPillHeight: CGFloat = 20

    /// Pure height math for the disclosure area above the bubble.
    /// Total extra row height contributed by the disclosure (and its
    /// expanded body, when applicable). Tested in
    /// Phase11ThinkDisclosureHeightTests; keep the maths here so the
    /// test pins the contract instead of black-box-measuring the row.
    static func disclosureExtraHeight(
        hasThinking: Bool,
        expanded: Bool,
        bodyHeight: CGFloat
    ) -> CGFloat {
        guard hasThinking else { return 0 }
        let pill = thinkPillHeight + DesignTokens.Spacing.xs
        guard expanded else { return pill }
        return pill + bodyHeight + DesignTokens.Spacing.xs
    }

    init(
        turn: Turn,
        character: Character? = nil,
        personaName: String? = nil,
        multiCast: Bool = false
    ) {
        self.turnId = turn.id
        self.role = turn.role
        self.rawText = turn.text
        self.turnTs = turn.ts
        self.multiCast = multiCast
        // Phase 11 §D.11 (option 2) — read the trace from the active
        // variant. Falls back through the `<think>` extractor below
        // for legacy chats that have the tags inline in `text`.
        self.persistedThinkingTrace = turn.variants.indices.contains(turn.activeVariant)
            ? turn.variants[turn.activeVariant].thinkingTrace
            : nil

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
            bubble.layer?.cornerRadius = DesignTokens.Chat.bubbleRadius
        }
        bubble.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bubble)

        if role == .user {
            // V2_UI_OVERHAUL §4.0.c — user-side avatar in the leading
            // gutter, secondaryLabelColor circle with the persona's
            // initial in windowBackgroundColor. Symmetric to the
            // assistant gutter but tuned to read as "you" rather than
            // competing with the character's accent-coloured avatar.
            let displayName = personaName ?? "You"
            avatar.image = TurnView.makeUserAvatar(
                size: avatarSize, name: displayName
            )
            avatar.toolTip = displayName
            avatar.imageScaling = .scaleProportionallyUpOrDown
            avatar.wantsLayer = true
            avatar.layer?.cornerRadius = avatarSize / 2
            avatar.layer?.masksToBounds = true
            avatar.translatesAutoresizingMaskIntoConstraints = false
            addSubview(avatar)

            // Persona caption above the bubble. caption1 / secondary
            // — quieter than the assistant's headline-weight name so
            // the eye reads "this was you" without it competing with
            // the character's voice. No timestamp on user turns by
            // design (the spec deliberately omits it; would read as
            // journaling rather than chat).
            let nameLabel = NSTextField(labelWithString: displayName)
            nameLabel.font = DesignTokens.Typography.caption1
            nameLabel.textColor = .secondaryLabelColor
            nameLabel.alignment = .left
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.maximumNumberOfLines = 1
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nameLabel)
            speakerNameLabel = nameLabel
        }

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
                // V2_DESIGN_LANGUAGE §10 anti-pattern: replaced the ✦
                // custom glyph with the SF Symbol `person.crop.circle`.
                // Free-form chats (no character bound) fall through here.
                avatar.image = TurnView.makeAssistantPlaceholderAvatar(
                    size: avatarSize
                )
            }
            // V2_UI_OVERHAUL §4.3 — every assistant turn carries a
            // speaker-name header. Multi-cast chats additionally get a
            // 3pt accent ring on the avatar and tint the name with the
            // speaker accent (Phase 8 §4.3 carry-over) for at-a-glance
            // identification across rotating speakers. Long names like
            // "Captain Marin" used to truncate inside the 40pt gutter
            // when the label was below the avatar — keeping the label
            // ABOVE the bubble preserves the full name, which is also
            // why the multi-cast Phase 8 fix lives here.
            let nameAccent: NSColor
            if multiCast, let character {
                nameAccent = SpeakerColor.accent(for: character.id)
                avatar.layer?.borderColor = nameAccent.cgColor
                avatar.layer?.borderWidth = 3
            } else {
                nameAccent = .labelColor
            }
            let nameStr = character?.name ?? "Assistant"
            let nameLabel = NSTextField(labelWithString: nameStr)
            nameLabel.font = DesignTokens.Typography.headline
            nameLabel.textColor = nameAccent
            nameLabel.alignment = .left
            nameLabel.lineBreakMode = .byTruncatingTail
            nameLabel.maximumNumberOfLines = 1
            nameLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(nameLabel)
            speakerNameLabel = nameLabel

            // Companion timestamp. tertiaryLabelColor reads as
            // "metadata, not content" — the eye finds the name first.
            let tsLabel = NSTextField(
                labelWithString: "· " + TurnView.formatTimestamp(turnTs)
            )
            tsLabel.font = DesignTokens.Typography.caption1
            tsLabel.textColor = .tertiaryLabelColor
            tsLabel.alignment = .left
            tsLabel.lineBreakMode = .byClipping
            tsLabel.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tsLabel)
            timestampLabel = tsLabel

            // V2_UI_OVERHAUL §4.7 — `<think>` collapsed disclosure pill.
            // Hidden until renderRendered detects a non-empty think
            // block. caption1 + secondaryLabelColor + a chevron icon
            // that flips between right (collapsed) and down (expanded).
            thinkPill.title = "Thinking"
            thinkPill.bezelStyle = .inline
            thinkPill.isBordered = false
            thinkPill.font = DesignTokens.Typography.caption1
            thinkPill.contentTintColor = .secondaryLabelColor
            thinkPill.image = NSImage(
                systemSymbolName: "chevron.right",
                accessibilityDescription: "Show thinking"
            )
            thinkPill.imagePosition = .imageLeading
            thinkPill.imageScaling = .scaleProportionallyDown
            thinkPill.target = self
            thinkPill.action = #selector(thinkPillTapped)
            thinkPill.isHidden = true
            thinkPill.translatesAutoresizingMaskIntoConstraints = false
            thinkPill.toolTip = "Show the model's reasoning trace"
            addSubview(thinkPill)

            // Expanded body — secondary-tinted prose, multi-line wrap.
            thinkBodyView.font = DesignTokens.Typography.body
            thinkBodyView.textColor = .secondaryLabelColor
            thinkBodyView.isHidden = true
            thinkBodyView.lineBreakMode = .byWordWrapping
            thinkBodyView.maximumNumberOfLines = 0
            thinkBodyView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(thinkBodyView)

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

    /// V2_UI_OVERHAUL §4.3 — timestamp companion to the speaker name.
    /// `caption1` size, short time format ("2:14 PM" / "14:14" depending
    /// on locale). Computed once at turn render and not re-formatted on
    /// the fly (turns don't change wallclock after they're recorded).
    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .short
        return f
    }()

    static func formatTimestamp(_ ts: Date) -> String {
        return timestampFormatter.string(from: ts)
    }

    /// V2_UI_OVERHAUL §4.c — display name for the user-turn caption.
    /// Falls back through (persona name → settings.userName → "You")
    /// with empty/whitespace strings treated as missing so a never-named
    /// persona doesn't render a blank caption above the bubble.
    /// Pinned by Phase11UserDisplayNameTests.
    static func userTurnDisplayName(personaName: String?, settingsUserName: String) -> String {
        let p = personaName?.trimmingCharacters(in: .whitespaces) ?? ""
        if !p.isEmpty { return p }
        let u = settingsUserName.trimmingCharacters(in: .whitespaces)
        if !u.isEmpty { return u }
        return "You"
    }

    /// V2_UI_OVERHAUL §4.0.c — user-side avatar. `secondaryLabelColor`
    /// circle with the persona's initial in `windowBackgroundColor`.
    /// Drawn at the avatar size so it composites cleanly without
    /// resampling artefacts.
    private static func makeUserAvatar(size: CGFloat, name: String) -> NSImage {
        let dim = NSSize(width: size, height: size)
        let img = NSImage(size: dim)
        img.lockFocus()
        defer { img.unlockFocus() }
        NSColor.secondaryLabelColor.setFill()
        let circle = NSBezierPath(ovalIn: NSRect(origin: .zero, size: dim))
        circle.fill()
        let initial: String = {
            let trimmed = name.trimmingCharacters(in: .whitespaces)
            guard let first = trimmed.first else { return "?" }
            return String(first).uppercased()
        }()
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size * 0.5, weight: .semibold),
            .foregroundColor: NSColor.windowBackgroundColor,
            .paragraphStyle: para
        ]
        let s = NSAttributedString(string: initial, attributes: attrs)
        let h = s.size().height
        s.draw(in: NSRect(x: 0, y: (size - h) / 2, width: size, height: h))
        return img
    }

    /// Free-form-chat assistant avatar fallback (no character bound).
    /// Renders `person.crop.circle` SF Symbol at the avatar size with
    /// a tertiary-label tint so it reads as "no character here" without
    /// shouting. V2_UI_OVERHAUL §4.0.h (replaces the legacy ✦ glyph).
    private static func makeAssistantPlaceholderAvatar(size: CGFloat) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(
            pointSize: size, weight: .regular
        )
        if let img = NSImage(
            systemSymbolName: "person.crop.circle",
            accessibilityDescription: "Assistant"
        )?.withSymbolConfiguration(cfg) {
            return img
        }
        // Belt-and-braces fallback for synthetic test environments where
        // SF Symbols may not resolve. Returns a small placeholder so we
        // never hand back nil and crash the avatar view.
        return placeholderAvatar(initials: "?")
    }

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
            // V2_UI_OVERHAUL §4.0.a / §4.0.c / §4.3 — user turn anatomy
            // is symmetric to the assistant: avatar in the leading
            // gutter, name caption above the bubble, bubble + content
            // left-aligned starting at glyphCol. User-side bubble
            // keeps a controlBackgroundColor fill at bubbleRadius
            // (visible distinction without a Messages-style tail).
            // Width keeps the historical 0.78 multiplier so short user
            // turns don't fill the entire transcript column; promoting
            // to true inline-block content-hugging is flagged in
            // V2_UI_OVERHAUL §D as a polish follow-up.
            let labelGap = speakerLabelHeight

            NSLayoutConstraint.activate([
                avatar.topAnchor.constraint(equalTo: topAnchor),
                avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
                avatar.widthAnchor.constraint(equalToConstant: avatarSize),
                avatar.heightAnchor.constraint(equalToConstant: avatarSize),

                bubble.topAnchor.constraint(equalTo: topAnchor, constant: labelGap),
                bubble.leadingAnchor.constraint(equalTo: leadingAnchor, constant: glyphCol),
                bubble.widthAnchor.constraint(
                    equalTo: widthAnchor, multiplier: 0.78,
                    constant: -glyphCol * 0.78
                ),

                scrollView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: bubblePadY),
                scrollView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -bubblePadY),
                scrollView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: bubblePadX),
                scrollView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -bubblePadX),

                toolbar.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                toolbar.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight),
                toolbar.bottomAnchor.constraint(equalTo: bottomAnchor),

                // Branch glyph below the avatar (mirrors the assistant
                // layout). The pre-§4.c "outside leading edge" placement
                // worked when user turns were right-aligned and had free
                // left-side real estate; that's gone now.
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
        } else {
            // V2_UI_OVERHAUL §4.3 — assistant turn anatomy:
            //   [avatar | name · ts             ]    <- speaker header (always)
            //   [       | ▸ Thinking            ]    <- think disclosure (when present)
            //   [       |  thinking content...  ]    <- expanded body (when toggled)
            //   [       |  prose body...        ]    <- main content
            //   [       |  ◀ 1/3 ▶  hover-bar   ]    <- variants + actions
            //
            // Avatar is top-aligned to the speaker header, NOT to the
            // bubble body, so the row reads as "this character said this".
            let labelGap = speakerLabelHeight

            let bubbleTop = bubble.topAnchor.constraint(
                equalTo: topAnchor, constant: labelGap
            )
            bubbleTopConstraint = bubbleTop

            NSLayoutConstraint.activate([
                avatar.topAnchor.constraint(equalTo: topAnchor),
                avatar.leadingAnchor.constraint(equalTo: leadingAnchor),
                avatar.widthAnchor.constraint(equalToConstant: avatarSize),
                avatar.heightAnchor.constraint(equalToConstant: avatarSize),

                bubbleTop,
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
                    nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bubble.topAnchor, constant: -2)
                ])
                if let tsLabel = timestampLabel {
                    NSLayoutConstraint.activate([
                        tsLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
                        tsLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: DesignTokens.Spacing.xs),
                        tsLabel.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor)
                    ])
                }
            }
            // V2_UI_OVERHAUL §4.7 — `<think>` disclosure pill + body.
            // Pill sits in the slot the bubble would occupy when no
            // thinking is present, so its top constraint matches the
            // bubble's `topAnchor + labelGap`. When thinking IS present,
            // applyDisclosureLayout() bumps the bubble's top constant
            // by `disclosureExtraHeight(...)` to make room. Pill +
            // body always anchor here; visibility (and the bubble
            // offset) is what changes.
            NSLayoutConstraint.activate([
                thinkPill.topAnchor.constraint(equalTo: topAnchor, constant: labelGap),
                thinkPill.leadingAnchor.constraint(equalTo: leadingAnchor, constant: glyphCol),
                thinkPill.heightAnchor.constraint(equalToConstant: TurnView.thinkPillHeight),

                thinkBodyView.topAnchor.constraint(
                    equalTo: thinkPill.bottomAnchor, constant: DesignTokens.Spacing.xs
                ),
                thinkBodyView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: glyphCol),
                thinkBodyView.trailingAnchor.constraint(equalTo: trailingAnchor)
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

    /// V2_UI_OVERHAUL §4.7 — toggle the `<think>` disclosure body. The
    /// disclosure pill's chevron flips right→down on expand; the body
    /// fades in below. `applyDisclosureLayout` does the visibility +
    /// constraint-constant work; `recomputeHeight` reflows the row.
    @objc private func thinkPillTapped() {
        guard thinkingText != nil else { return }
        thinkingExpanded.toggle()
        applyDisclosureLayout()
        recomputeHeight()
    }

    /// Applies the current `(thinkingText, thinkingExpanded)` state to
    /// the disclosure subviews + bubble top constant. Called from
    /// renderRendered (when rawText changes) AND from thinkPillTapped
    /// (when the user toggles). Idempotent.
    private func applyDisclosureLayout() {
        let hasThinking = (thinkingText != nil)
        thinkPill.isHidden = !hasThinking
        thinkBodyView.isHidden = !(hasThinking && thinkingExpanded)
        // Chevron orientation. SF Symbols owns the "right" / "down"
        // glyphs; on a pre-26 macOS the resolution falls back to a
        // disclosure-triangle-style fallback by name match.
        let chevronName = thinkingExpanded ? "chevron.down" : "chevron.right"
        thinkPill.image = NSImage(
            systemSymbolName: chevronName,
            accessibilityDescription: thinkingExpanded
                ? "Hide thinking" : "Show thinking"
        )
        // Body wraps to the prose width. preferredMaxLayoutWidth has
        // to be set BEFORE the body's intrinsic content size is
        // measured (otherwise the label asks for a single-line height
        // and the row clips on first render); recomputeHeight reads
        // the same width.
        let w = currentTextWidth()
        if w > 1 { thinkBodyView.preferredMaxLayoutWidth = w }
        if hasThinking, thinkingExpanded {
            thinkBodyView.stringValue = thinkingText ?? ""
        }
        // Update bubble's top constant — the disclosure consumes the
        // space between the speaker header and the bubble.
        let bodyH = thinkingExpanded ? measuredThinkBodyHeight() : 0
        let extra = TurnView.disclosureExtraHeight(
            hasThinking: hasThinking, expanded: thinkingExpanded, bodyHeight: bodyH
        )
        bubbleTopConstraint?.constant = speakerLabelHeight + extra
    }

    /// Measure the wrapped height of the think body at the current
    /// available width. Used both for the bubble offset and for the
    /// row's recomputeHeight total.
    private func measuredThinkBodyHeight() -> CGFloat {
        guard let s = thinkingText, !s.isEmpty else { return 0 }
        let w = currentTextWidth()
        guard w > 1 else { return 0 }
        let attr = NSAttributedString(
            string: s,
            attributes: [
                .font: DesignTokens.Typography.body,
                .foregroundColor: NSColor.secondaryLabelColor
            ]
        )
        let bbox = attr.boundingRect(
            with: NSSize(width: w, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading]
        )
        return ceil(bbox.height)
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
            // V2_UI_OVERHAUL §4.7 — split think trace from prose so
            // the trace can surface in the disclosure pill while the
            // textView renders only the prose. Phase 11 §D.11 — prefer
            // the side-channel `persistedThinkingTrace` (captured by
            // the streaming filter and stored on the active variant);
            // the inline extractor is the legacy fallback for chats
            // whose `text` still has tags embedded.
            let extracted = Markdown.extractThinking(rawText)
            thinkingText = persistedThinkingTrace ?? extracted.think
            display = extracted.body
        } else {
            thinkingText = nil
            display = rawText
        }
        let attr = Markdown.render(display, baseFont: baseFont)
        textView.textStorage?.setAttributedString(attr)
        if role == .assistant {
            applyDisclosureLayout()
        }
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
        // V2_UI_OVERHAUL §4.7 — the disclosure pill (and its expanded
        // body when toggled) sits between the speaker header and the
        // bubble. Its space comes from the static helper that's pinned
        // by Phase11ThinkDisclosureHeightTests so the math stays
        // explicit. Returns 0 on user turns (no thinking concept) and
        // on assistant turns with no `<think>` block.
        let disclosureH = TurnView.disclosureExtraHeight(
            hasThinking: thinkingText != nil,
            expanded: thinkingExpanded,
            bodyHeight: thinkingExpanded ? measuredThinkBodyHeight() : 0
        )
        let h = speakerLabelHeight
            + disclosureH
            + bubbleH
            + toolbarTopGap
            + toolbarHeight
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
            // User bubble width = 0.78 * parentW - 0.78 * glyphCol
            // (matches the constraint set in installConstraints — the
            // bubble is left-aligned at glyphCol and shrinks to the
            // historical 78% of the available column width).
            let bubbleW = parentW * 0.78 - glyphCol * 0.78
            return max(0, bubbleW - bubblePadX * 2)
        } else {
            return max(0, parentW - glyphCol)
        }
    }
}
