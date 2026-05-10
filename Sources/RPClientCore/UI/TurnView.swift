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
    /// V2_UI_OVERHAUL §4.k / §D.13 — per-character TTS mute toggle.
    func turnViewDidToggleCharacterMute(_ view: TurnView, characterId: UUID)
}

/// V2_UI_OVERHAUL §4.0.d / §4.d.2 — capsule-styled pill background that
/// auto-adapts to light/dark + popover-active states. Used by the
/// variants pill and branches pill. `accentBackground = true` flips
/// the fill to a translucent accent for "popover is anchored to me"
/// (only the branches pill uses this today; variants leaves it false).
final class CapsulePill: NSStackView {
    var accentBackground: Bool = false {
        didSet {
            guard oldValue != accentBackground else { return }
            needsDisplay = true
        }
    }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // Resolved at draw time so light/dark switches the fill
        // correctly. The pre-§4.e.1.fixup code assigned
        // controlBackgroundColor.cgColor once at init, which froze the
        // colour to whichever appearance the view was created in.
        let bg: NSColor = accentBackground
            ? NSColor.controlAccentColor.withAlphaComponent(0.18)
            : NSColor.controlBackgroundColor
        layer?.backgroundColor = bg.cgColor
    }
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
    /// V2_UI_OVERHAUL §4.5 — typing-dots indicator shown during the
    /// pre-token gap and any `<think>` block. Replaces the pre-§4.e.1
    /// "Thinking…" italic-text body + avatar opacity pulse.
    private let typingDots = TypingDotsView()
    /// Assistant-side speaker indicator. V2_PLAN §6.2 — when the chat has a
    /// character attached, this carries the character avatar resolved via
    /// `AvatarSource`; otherwise it falls back to a tinted ✦ rendered through
    /// `placeholderAvatar` so character-less chats keep their current
    /// visual signature.
    private let avatar = NSImageView()
    /// V2_UI_OVERHAUL §4.k — using NSImageView (not NSButton) so the
    /// SF Symbol renders flush with the surrounding caption text. A
    /// click gesture recognizer carries the toggle action; NSButton's
    /// inset cell metrics floated the icon visibly above the
    /// timestamp's baseline.
    private var muteToggleButton: NSImageView?
    private var isMutedCharacterCache: Bool
    private var mutableCharacterIdForMute: UUID?

    private let toolbar = NSStackView()
    /// V2_UI_OVERHAUL §4.d.1 — vertical stack housing
    /// `[variantsPill, toolbar]` below the bubble. NSStackView handles
    /// hidden-subview collapsing so we don't have to dynamically swap
    /// constraints when the variant pager appears/disappears.
    private let belowBubbleStack = NSStackView()
    /// V2_UI_OVERHAUL §4.0.d — `◀ N/M ▶` capsule pill, broken out of
    /// the toolbar so it can be always-visible (not hover-revealed)
    /// per the spec. Wraps `prevVariantButton` + `variantLabel` +
    /// `nextVariantButton`.
    private let variantsPill = CapsulePill()
    /// V2_UI_OVERHAUL §4.d.1 — `⋯` button at the trailing edge of the
    /// hover bar; opens a popup menu of secondary actions per role.
    /// Right-click on the row produces the same menu plus the primary
    /// actions, mirroring native macOS context-menu convention.
    private let overflowButton: NSButton
    private let copyButton: NSButton
    private let editButton: NSButton
    private let regenButton: NSButton
    /// Phase 7 §3.3+ — explicit "fork from this reply" toolbar button.
    /// Hover-revealed alongside regen on every assistant turn that has a
    /// parent (i.e., not the root greeting). Fires the same path as Cmd-B.
    private let forkButton: NSButton
    private let deleteButton: NSButton
    private let saveButton: NSButton
    private let cancelButton: NSButton
    /// Variant pager: ◀ N/M ▶ inside the always-visible variants pill.
    private let prevVariantButton: NSButton
    private let nextVariantButton: NSButton
    private let variantLabel = NSTextField(labelWithString: "")
    /// V2_UI_OVERHAUL §4.0.f / §4.d.2 — "branches: N ▸" labelled pill
    /// shown next to the variants pill on diverging messages. Replaces
    /// the Phase 7 §3.3b gutter glyph. Implemented as an NSStackView
    /// (capsule-styled, containing an NSTextField label) rather than
    /// an NSButton, structurally identical to `variantsPill` so the
    /// horizontal pills row sizes both children consistently — an
    /// NSButton with bezelStyle=.inline + a custom layer background
    /// fights AppKit's built-in inline-button rendering and produces
    /// inconsistent intrinsic widths.
    private let branchesPill = CapsulePill()
    /// Backing label for `branchesPill`; updated by updateBranchesPill.
    private let branchesLabel = NSTextField(labelWithString: "")
    /// V2_UI_OVERHAUL §4.d.2 — horizontal NSStackView that wraps the
    /// metadata pills (variants + branches) so they sit side-by-side
    /// above the hover toolbar in `belowBubbleStack`. NSStackView's
    /// hidden-collapse handles per-pill visibility automatically.
    private let pillsRow = NSStackView()

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
            updateBranchesPill()
        }
    }

    /// Total siblings (parent's child count, including this one). Drives
    /// the "N" in the "branches: N ▸" pill — the user reads it
    /// at-a-glance without having to open the popover.
    var siblingCount: Int = 1 {
        didSet { updateBranchesPill() }
    }

    /// 1-based index of this turn within its parent's children (sorted by
    /// ts). Drives the "N" in "N/M".
    var siblingIndex: Int = 1 {
        didSet { updateBranchesPill() }
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

    /// V2_UI_OVERHAUL §4.0.f / §4.d.2 — derive the pill's title from
    /// the current `(hasSiblings, siblingCount)` state. Hides the pill
    /// when there's nothing to disclose (single child, root turn off
    /// the tree). pillsRow's overall visibility is recomputed at the
    /// same time so the row collapses cleanly when both pills hide.
    private func updateBranchesPill() {
        let title = hasSiblings
            ? TurnView.branchesPillTitle(siblingCount: siblingCount)
            : nil
        if let t = title {
            branchesLabel.stringValue = "\(t) ▸"
            branchesPill.isHidden = false
        } else {
            branchesLabel.stringValue = ""
            branchesPill.isHidden = true
        }
        updatePillsRowVisibility()
    }

    /// V2_UI_OVERHAUL §4.d.2 — flip the branches pill's "active"
    /// appearance while ChatViewController's sibling popover is open,
    /// so the user has a clear visual anchor back to where they
    /// clicked. Mirrors the pre-§4.d.2 setBranchPopoverOpen behaviour
    /// from when this lived on the gutter glyph.
    func setBranchPopoverOpen(_ open: Bool) {
        // CapsulePill's updateLayer reads `accentBackground` and picks
        // the matching fill (light/dark-adaptive). Label colour stays
        // explicit since NSTextField doesn't share the same layer-redraw
        // story — the labelColor token already adapts to appearance.
        branchesLabel.textColor = open ? .controlAccentColor : .secondaryLabelColor
        branchesPill.accentBackground = open
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
        // V2_UI_OVERHAUL §4.0.d / §4.d.1 — variants pill is the
        // capsule-styled `◀ N/M ▶` block; visible whenever count > 1
        // on an assistant turn (always-visible, not hover-revealed).
        // Discard moves to the overflow popup, so it's no longer
        // toggled here. The underlying buttons inside the pill stay
        // shown; the pill itself is what hides/shows.
        let show = role == .assistant && count > 1
        variantsPill.isHidden = !show
        updatePillsRowVisibility()
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
    /// Phase 11 §D.11 — trace from the active variant. Mutable because
    /// the placeholder TurnView is created BEFORE any tokens stream
    /// (init reads nil from the empty variant); the chat controller
    /// pushes the captured trace via `setThinkingTrace(_:)` after the
    /// stream-finish handler writes it to the variant. Preferred over
    /// `Markdown.extractThinking(rawText)` when non-nil; the inline
    /// extractor stays as a fallback for legacy chats whose text still
    /// has `<think>` tags embedded.
    private var persistedThinkingTrace: String?
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
    /// V2_UI_OVERHAUL §4.d.1 — variants pill capsule height (matches
    /// the per-button toolbar height so they read as siblings on the
    /// same row when both are visible).
    static let variantsPillHeight: CGFloat = 22

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
        multiCast: Bool = false,
        isMutedCharacter: Bool = false
    ) {
        self.isMutedCharacterCache = isMutedCharacter
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
        editButton = TurnView.makeIconButton(symbol: "pencil", tooltip: "Edit")
        regenButton = TurnView.makeIconButton(symbol: "arrow.clockwise", tooltip: "Regenerate")
        forkButton = TurnView.makeIconButton(symbol: "arrow.triangle.branch", tooltip: "Fork branch (⌘B)")
        deleteButton = TurnView.makeIconButton(symbol: "trash", tooltip: "Delete")
        saveButton = TurnView.makeIconButton(symbol: "checkmark", tooltip: "Save (⌘↵)")
        cancelButton = TurnView.makeIconButton(symbol: "xmark", tooltip: "Cancel (esc)")
        overflowButton = TurnView.makeIconButton(symbol: "ellipsis", tooltip: "More actions")
        prevVariantButton = TurnView.makeIconButton(symbol: "chevron.left", tooltip: "Previous variant (⌘←)")
        nextVariantButton = TurnView.makeIconButton(symbol: "chevron.right", tooltip: "Next variant (⌘→)")
        // V2_UI_OVERHAUL §4.d.1 / §4.j — Replay / Continue / Discard
        // moved to the overflow popup menu (selectors stay; their
        // NSButton ivars were never added to the view tree post-§4.d.1
        // and are now removed). branchesPill replaces the pre-§4.d.2
        // gutter glyph; configured in the post-super setup block.

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
                mutableCharacterIdForMute = character.id
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
            // V2_UI_OVERHAUL §4.k — mute toggle lives in the speaker
            // header next to the timestamp (not over the avatar) so
            // its on/off state is legible without the user having to
            // squint at a small overlay. Constraints are installed
            // alongside the timestamp's in the bubble-layout block
            // below; the install method only creates + addSubviews.
            if mutableCharacterIdForMute != nil {
                installMuteToggle()
            }
        }

        textView.isRichText = true
        textView.font = baseFont
        textView.delegate = self
        textView.allowsUndo = true
        // V2_UI_OVERHAUL §4.d.1 fixup — read-only by default; the edit
        // button is the *only* path into edit mode. Pre-fixup, any
        // click on the text body (including right-click) called
        // becomeFirstResponder which triggered enterEditMode and stole
        // the per-turn context menu, replacing it with AppKit's
        // cut/copy/paste menu. Selection + copy still works because
        // `isSelectable` stays true.
        textView.isEditable = false
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
        // V2_UI_OVERHAUL §4.d.1 fixup — edit mode is entered EXPLICITLY
        // via editTapped(), not on becomeFirstResponder. Right-clicks
        // and selection drags also focus the text view, so the previous
        // wiring (callback → enterEditMode) entered edit mode on every
        // click, including right-clicks — which then short-circuited
        // the context-menu hook. enterEditMode is now called directly
        // from editTapped. The resign path stays so click-away commits
        // a pending edit.
        textView.onResignFirstResponder = { [weak self] in self?.exitEditMode() }
        textView.onCommitEdit = { [weak self] in self?.commitEdit() }
        textView.onCancelEdit = { [weak self] in self?.cancelEdit() }

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(scrollView)

        // V2_UI_OVERHAUL §4.5 — typing-dots indicator. Lives on the
        // assistant side only (user turns never stream); pinned at
        // the top-leading of the bubble so it sits where text would
        // start. Hidden by default; renderRendered toggles visibility
        // based on (isStreaming && rawText.isEmpty) || isThinking.
        if role == .assistant {
            typingDots.translatesAutoresizingMaskIntoConstraints = false
            typingDots.isHidden = true
            bubble.addSubview(typingDots)
            NSLayoutConstraint.activate([
                typingDots.topAnchor.constraint(equalTo: bubble.topAnchor, constant: 4),
                typingDots.leadingAnchor.constraint(equalTo: bubble.leadingAnchor)
            ])
        }

        copyButton.target = self;     copyButton.action     = #selector(copyTapped)
        editButton.target = self;     editButton.action     = #selector(editTapped)
        regenButton.target = self;    regenButton.action    = #selector(regenTapped)
        forkButton.target = self;     forkButton.action     = #selector(forkTapped)
        deleteButton.target = self;   deleteButton.action   = #selector(deleteTapped)
        saveButton.target = self;     saveButton.action     = #selector(saveTapped)
        cancelButton.target = self;   cancelButton.action   = #selector(cancelTapped)
        overflowButton.target = self; overflowButton.action = #selector(overflowTapped)
        prevVariantButton.target = self; prevVariantButton.action = #selector(prevVariantTapped)
        nextVariantButton.target = self; nextVariantButton.action = #selector(nextVariantTapped)
        // V2_UI_OVERHAUL §4.d.2 — branches pill: capsule-styled
        // NSStackView wrapping a single text label. Hidden until
        // hasSiblings flips true via ChatViewController. Click opens
        // the same sibling popover the pre-§4.d.2 gutter glyph did
        // (via an NSClickGestureRecognizer). Structurally mirrors
        // `variantsPill` so the horizontal pills row sizes both
        // consistently.
        branchesLabel.font = DesignTokens.Typography.caption1
        branchesLabel.textColor = .secondaryLabelColor
        branchesLabel.alignment = .center
        branchesLabel.lineBreakMode = .byClipping
        branchesPill.orientation = .horizontal
        branchesPill.alignment = .centerY
        branchesPill.spacing = 0
        branchesPill.translatesAutoresizingMaskIntoConstraints = false
        branchesPill.wantsLayer = true
        branchesPill.layer?.cornerRadius = 11
        // Background fill is owned by CapsulePill.updateLayer so it
        // adapts to light/dark and the popover-active accent flip
        // automatically (setBranchPopoverOpen toggles accentBackground).
        branchesPill.edgeInsets = NSEdgeInsets(
            top: 0,
            left: DesignTokens.Spacing.sm,
            bottom: 0,
            right: DesignTokens.Spacing.sm
        )
        branchesPill.addArrangedSubview(branchesLabel)
        branchesPill.isHidden = true
        let branchesClick = NSClickGestureRecognizer(
            target: self, action: #selector(branchGlyphTapped)
        )
        branchesPill.addGestureRecognizer(branchesClick)

        saveButton.contentTintColor = .systemBlue
        cancelButton.contentTintColor = .secondaryLabelColor

        // Initially hidden — non-last-assistant doesn't show regen/continue.
        regenButton.isHidden = !(role == .assistant)
        // Fork button shows on every assistant turn (not just trailing) so
        // the user can fork from any reply via the UI. Final visibility is
        // gated in `updateToolbarForEditState` once parentId is known.
        forkButton.isHidden = !(role == .assistant)
        saveButton.isHidden = true
        cancelButton.isHidden = true
        // V2_UI_OVERHAUL §4.d.1 — the variantsPill itself hides as a
        // unit when count <= 1; its children stay visible inside it.
        // The pre-§4.d.1 init also set isHidden on each pager button
        // individually because they used to live in the main toolbar
        // strip alongside other actions; that's no longer the shape,
        // and leaving those flags as `true` left the pill rendering
        // empty when shown. discardVariant moved to the overflow menu
        // entirely so its visibility flag no longer affects rendering.

        variantLabel.font = Theme.font(11, weight: .medium)
        variantLabel.textColor = .secondaryLabelColor
        variantLabel.alignment = .center
        variantLabel.translatesAutoresizingMaskIntoConstraints = false
        // Reserve width for "NN / NN" so the label doesn't wiggle as the
        // active index changes.
        variantLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 30).isActive = true

        // V2_UI_OVERHAUL §4.d.1 — variants pill is broken out of the
        // toolbar and is ALWAYS visible (not hover-revealed) when
        // variantCount > 1. Capsule background, `controlBackgroundColor`,
        // tucks under the bubble's leading edge.
        variantsPill.orientation = .horizontal
        variantsPill.spacing = DesignTokens.Spacing.xs
        variantsPill.alignment = .centerY
        variantsPill.translatesAutoresizingMaskIntoConstraints = false
        variantsPill.wantsLayer = true
        variantsPill.layer?.cornerRadius = 11
        // Background fill is owned by CapsulePill.updateLayer so it
        // adapts to light/dark and any popover-active flip automatically.
        variantsPill.edgeInsets = NSEdgeInsets(
            top: 0,
            left: DesignTokens.Spacing.sm,
            bottom: 0,
            right: DesignTokens.Spacing.sm
        )
        variantsPill.addArrangedSubview(prevVariantButton)
        variantsPill.addArrangedSubview(variantLabel)
        variantsPill.addArrangedSubview(nextVariantButton)
        variantsPill.isHidden = true   // setVariantState reveals it

        // V2_UI_OVERHAUL §4.d.1 — toolbar primary set is role-dependent:
        //   assistant: copy, regen, edit, fork, ⋯
        //   user:      edit, delete, ⋯
        // Save / Cancel are always present so edit-mode can swap them
        // in via updateToolbarForEditState. Secondaries (replay /
        // continue / discard / delete-on-assistant / copy-on-user) live
        // in the overflow popup menu, built dynamically per click so
        // visibility tracks state (e.g., Continue only on the trailing
        // turn, Discard only with multiple variants).
        toolbar.orientation = .horizontal
        toolbar.spacing = 2
        toolbar.alignment = .centerY
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.alphaValue = 0
        if role == .assistant {
            toolbar.addArrangedSubview(copyButton)
            toolbar.addArrangedSubview(regenButton)
            toolbar.addArrangedSubview(editButton)
            toolbar.addArrangedSubview(forkButton)
        } else {
            toolbar.addArrangedSubview(editButton)
            toolbar.addArrangedSubview(deleteButton)
        }
        toolbar.addArrangedSubview(overflowButton)
        toolbar.addArrangedSubview(saveButton)
        toolbar.addArrangedSubview(cancelButton)

        // Wrap the variants pill + toolbar in a vertical stack below the
        // bubble. NSStackView collapses hidden subviews automatically,
        // so the pill's visibility transition doesn't need any
        // constraint-juggling — toolbar slides up cleanly when the
        // pager hides.
        // V2_UI_OVERHAUL §4.d.2 — pills row sits between the bubble
        // and the toolbar, holding [variantsPill, branchesPill] side
        // by side. NSStackView collapses hidden arrangedSubviews so
        // each pill's visibility is independent. updatePillsRowVisibility()
        // hides the row entirely when both are hidden so the toolbar
        // doesn't get a phantom 4pt gap above it.
        pillsRow.orientation = .horizontal
        pillsRow.spacing = DesignTokens.Spacing.xs
        pillsRow.alignment = .centerY
        pillsRow.translatesAutoresizingMaskIntoConstraints = false
        pillsRow.addArrangedSubview(variantsPill)
        pillsRow.addArrangedSubview(branchesPill)
        pillsRow.isHidden = true   // updateBranchesPill / setVariantState reveal

        belowBubbleStack.orientation = .vertical
        belowBubbleStack.alignment = .leading
        belowBubbleStack.spacing = DesignTokens.Spacing.xs
        belowBubbleStack.translatesAutoresizingMaskIntoConstraints = false
        belowBubbleStack.addArrangedSubview(pillsRow)
        belowBubbleStack.addArrangedSubview(toolbar)
        addSubview(belowBubbleStack)

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

    /// V2_UI_OVERHAUL §4.0.f / §4.d.2 — title for the "branches: N"
    /// pill on diverging messages. Returns nil when the count means
    /// there's nothing to disclose (single-variant or defensive 0).
    /// Pinned by Phase11BranchesPillTests so the format stays explicit.
    static func branchesPillTitle(siblingCount: Int) -> String? {
        guard siblingCount > 1 else { return nil }
        return "branches: \(siblingCount)"
    }

    /// V2_UI_OVERHAUL §4.d.1 — items that appear in the per-turn `⋯`
    /// overflow menu. Pure data; no AppKit dependency, so the contract
    /// stays testable without standing up a window. ≤4 items per
    /// V2_UI_OVERHAUL §C.2 — items beyond four belong somewhere else.
    /// Pinned by Phase11OverflowMenuTests.
    static func overflowItems(
        role: TurnRole,
        isLastAssistant: Bool,
        variantCount: Int
    ) -> [String] {
        switch role {
        case .assistant:
            var items = ["Replay audio"]
            if isLastAssistant { items.append("Continue") }
            if variantCount > 1 { items.append("Discard this variant") }
            items.append("Delete")
            return items
        case .user:
            return ["Copy"]
        }
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

    // MARK: - §4.k mute toggle (next to timestamp)

    /// Build the always-visible mute toggle button. Caller adds the
    /// horizontal/baseline constraints alongside the timestamp label.
    /// Splitting create-vs-position here keeps this method orderless
    /// — the layout block owns sibling-anchored constraints and runs
    /// after every relevant subview has been added.
    private func installMuteToggle() {
        let v = NSImageView()
        v.imageScaling = .scaleProportionallyUpOrDown
        v.translatesAutoresizingMaskIntoConstraints = false
        addSubview(v)
        muteToggleButton = v

        let click = NSClickGestureRecognizer(
            target: self, action: #selector(muteToggleTapped)
        )
        v.addGestureRecognizer(click)

        refreshMuteToggleAppearance()
    }

    private func refreshMuteToggleAppearance() {
        guard let v = muteToggleButton else { return }
        let symbol = isMutedCharacterCache ? "speaker.slash.fill" : "speaker.wave.2.fill"
        let tip = isMutedCharacterCache ? "Unmute this character" : "Mute this character"
        // Match the caption1 text body's optical size — pointSize 10
        // with a regular weight reads as caption-furniture, not a
        // chrome control. tertiaryLabelColor on the un-muted face
        // matches the timestamp's tint so the icon disappears into
        // the metadata strip until you mute, where systemOrange
        // pops it loud.
        let cfg = NSImage.SymbolConfiguration(pointSize: 10, weight: .regular)
        v.image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)?
            .withSymbolConfiguration(cfg)
        v.toolTip = tip
        v.contentTintColor = isMutedCharacterCache
            ? .systemOrange
            : .tertiaryLabelColor
    }

    @objc private func muteToggleTapped() {
        guard let cid = mutableCharacterIdForMute else { return }
        delegate?.turnViewDidToggleCharacterMute(self, characterId: cid)
    }

    /// V2_UI_OVERHAUL §4.k — pushed by ChatViewController on
    /// `chatUpdated`. Mute toggling doesn't move the active path or
    /// rebuild turn ids, so `handleChatUpdated`'s in-place branch
    /// runs; without this setter the icon would never refresh.
    func setMuted(_ muted: Bool) {
        guard isMutedCharacterCache != muted else { return }
        isMutedCharacterCache = muted
        refreshMuteToggleAppearance()
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

                belowBubbleStack.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                belowBubbleStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                belowBubbleStack.bottomAnchor.constraint(equalTo: bottomAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight)
                // V2_UI_OVERHAUL §4.d.2 — branchesPill replaces the
                // pre-§4.d.2 gutter glyph; it now lives in pillsRow
                // (inside belowBubbleStack), not constrained here.
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

                belowBubbleStack.topAnchor.constraint(equalTo: bubble.bottomAnchor, constant: toolbarTopGap),
                belowBubbleStack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                belowBubbleStack.bottomAnchor.constraint(equalTo: bottomAnchor),
                toolbar.heightAnchor.constraint(equalToConstant: toolbarHeight)
                // V2_UI_OVERHAUL §4.d.2 — branchesPill replaces the
                // pre-§4.d.2 gutter glyph; it now lives in pillsRow
                // (inside belowBubbleStack), not constrained here.
            ])
            if let nameLabel = speakerNameLabel {
                NSLayoutConstraint.activate([
                    nameLabel.topAnchor.constraint(equalTo: topAnchor, constant: 2),
                    nameLabel.leadingAnchor.constraint(equalTo: bubble.leadingAnchor),
                    nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: bubble.topAnchor, constant: -2)
                ])
                if let tsLabel = timestampLabel {
                    var headerConstraints: [NSLayoutConstraint] = [
                        tsLabel.lastBaselineAnchor.constraint(equalTo: nameLabel.lastBaselineAnchor),
                        tsLabel.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: DesignTokens.Spacing.xs)
                    ]
                    if let muteBtn = muteToggleButton {
                        // V2_UI_OVERHAUL §4.k — mute toggle sits inline
                        // after the timestamp. centerY against tsLabel
                        // (not baseline) because NSImageView's image
                        // is centred in the view rect, so visual
                        // alignment matches the text x-height best
                        // when the icon is centred against the text.
                        headerConstraints.append(contentsOf: [
                            muteBtn.centerYAnchor.constraint(equalTo: tsLabel.centerYAnchor),
                            muteBtn.leadingAnchor.constraint(equalTo: tsLabel.trailingAnchor, constant: DesignTokens.Spacing.xs),
                            muteBtn.widthAnchor.constraint(equalToConstant: 12),
                            muteBtn.heightAnchor.constraint(equalToConstant: 12),
                            muteBtn.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor)
                        ])
                    } else {
                        headerConstraints.append(
                            tsLabel.trailingAnchor.constraint(lessThanOrEqualTo: bubble.trailingAnchor)
                        )
                    }
                    NSLayoutConstraint.activate(headerConstraints)
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

    /// Phase 11 §D.11 — push the active variant's `thinkingTrace` in
    /// after the stream-finish handler has written it. The placeholder
    /// TurnView is created at stream-start (before any token lands)
    /// when the variant's trace is still nil, so the init-time read
    /// always sees nil; this setter is what ChatViewController fires
    /// from `handleStreamFinished` to surface the disclosure pill.
    /// No-op when the value is unchanged.
    func setThinkingTrace(_ trace: String?) {
        guard role == .assistant else { return }
        guard persistedThinkingTrace != trace else { return }
        persistedThinkingTrace = trace
        renderRendered()
        recomputeHeight()
    }

    var currentText: String { rawText }

    // MARK: - Toolbar actions

    @objc private func copyTapped() {
        delegate?.turnViewDidRequestCopy(self)
    }

    @objc private func editTapped() {
        // V2_UI_OVERHAUL §4.d.1 fixup — the textView is read-only by
        // default; flip it editable BEFORE focusing so the user can
        // type. enterEditMode is called explicitly here (not via the
        // becomeFirstResponder callback, which would also fire on
        // right-clicks and selection drags). exitEditMode / cancelEdit
        // revert isEditable.
        textView.isEditable = true
        enterEditMode()
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
        // Selector name kept for backwards-compat with the pre-§4.d.2
        // wiring; the anchor is now branchesPill (in the pills row),
        // not the gutter glyph.
        delegate?.turnViewDidRequestSiblingPopover(self, anchor: branchesPill)
    }

    /// V2_UI_OVERHAUL §4.d.2 — collapse the pills row when both
    /// children are hidden so the toolbar doesn't get a phantom
    /// 4pt gap above it. Called from setVariantState and
    /// updateBranchesPill — the two state setters that flip
    /// per-pill visibility.
    private func updatePillsRowVisibility() {
        pillsRow.isHidden = variantsPill.isHidden && branchesPill.isHidden
    }

    @objc private func overflowTapped() {
        let menu = buildOverflowMenu()
        guard !menu.items.isEmpty else { return }
        let p = NSPoint(x: 0, y: overflowButton.bounds.maxY)
        menu.popUp(positioning: nil, at: p, in: overflowButton)
    }

    /// V2_UI_OVERHAUL §4.d.1 — secondary actions tucked behind the
    /// `⋯` button in the toolbar. Items are filtered against the
    /// turn's current state (last/non-last, variant count) per the
    /// pure-data rule pinned by Phase11OverflowMenuTests.
    private func buildOverflowMenu() -> NSMenu {
        let menu = NSMenu()
        let titles = TurnView.overflowItems(
            role: role,
            isLastAssistant: isLastAssistant,
            variantCount: variantCount
        )
        for title in titles {
            menu.addItem(menuItem(for: title))
        }
        return menu
    }

    /// V2_UI_OVERHAUL §4.d.1 — right-click context menu mirrors the
    /// hover bar + overflow exactly (Apple Messages convention).
    /// Returned from `menu(for:)`. Primary actions appear first, then
    /// a separator, then the overflow set.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let primary: [String] = primaryActionTitles()
        for title in primary {
            menu.addItem(menuItem(for: title))
        }
        let overflowTitles = TurnView.overflowItems(
            role: role,
            isLastAssistant: isLastAssistant,
            variantCount: variantCount
        )
        if !overflowTitles.isEmpty {
            menu.addItem(NSMenuItem.separator())
            for title in overflowTitles {
                menu.addItem(menuItem(for: title))
            }
        }
        return menu.items.isEmpty ? super.menu(for: event) : menu
    }

    private func primaryActionTitles() -> [String] {
        switch role {
        case .assistant:
            var items = ["Copy"]
            if isLastAssistant { items.append("Regenerate") }
            items.append("Edit")
            if canFork { items.append("Fork branch") }
            return items
        case .user:
            return ["Edit", "Delete"]
        }
    }

    /// Map an action title to a target/action menu item routed to
    /// the same delegate methods the hover-bar buttons fire.
    private func menuItem(for title: String) -> NSMenuItem {
        let action: Selector
        switch title {
        case "Copy":                 action = #selector(copyTapped)
        case "Regenerate":           action = #selector(regenTapped)
        case "Edit":                 action = #selector(editTapped)
        case "Fork branch":          action = #selector(forkTapped)
        case "Continue":             action = #selector(continueTapped)
        case "Replay audio":         action = #selector(replayTapped)
        case "Delete":               action = #selector(deleteTapped)
        case "Discard this variant": action = #selector(discardVariantTapped)
        default:                     action = #selector(noopTapped)
        }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func noopTapped() { /* placeholder */ }

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
        // Lock the textView read-only again (paired with editTapped).
        textView.isEditable = false
        renderRendered()
        recomputeHeight()
    }

    private func updateToolbarForEditState() {
        let editing = isEditing
        // V2_UI_OVERHAUL §4.d.1 — primary toolbar contents are
        // role-dependent (assistant: copy/regen/edit/fork/⋯; user:
        // edit/delete/⋯). The non-arranged buttons (replay, continue,
        // discard, delete-on-assistant, copy-on-user) live in the
        // overflow popup; their isHidden flags don't affect rendering
        // since they're not in the toolbar's stack — but we still
        // honour them as the "is action available right now?" gate
        // that buildOverflowMenu reads.
        copyButton.isHidden = editing
        editButton.isHidden = editing
        regenButton.isHidden = editing || !(role == .assistant && isLastAssistant)
        forkButton.isHidden = editing || !(role == .assistant && canFork)
        deleteButton.isHidden = editing
        // Overflow button hidden during edit — Save/Cancel are the
        // only valid actions then, and the menu would mostly contain
        // disabled items.
        overflowButton.isHidden = editing
        saveButton.isHidden = !editing
        cancelButton.isHidden = !editing
        // V2_UI_OVERHAUL §4.0.d — variants pill stays always-visible
        // on assistant turns with multiple variants, but hides during
        // edit so Save/Cancel get the visual focus. Branches pill
        // hides during edit too (the Save/Cancel context shouldn't
        // also be inviting branch navigation).
        let showPager = !editing && role == .assistant && variantCount > 1
        variantsPill.isHidden = !showPager
        if editing { branchesPill.isHidden = true }
        else if hasSiblings { branchesPill.isHidden = false }
        updatePillsRowVisibility()
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
        // Lock the textView read-only again (paired with editTapped).
        textView.isEditable = false
        renderRendered()
        recomputeHeight()
    }

    private func renderRendered() {
        // V2_UI_OVERHAUL §4.5 — typing-dots replace the pre-§4.e.1
        // "Thinking…" italic-text body. Shown while the assistant is
        // mid-stream and either no displayable tokens have arrived
        // yet (pre-token gap) OR the stream is inside a `<think>`
        // block. Toggled here so renderRendered is the single source
        // of truth for "what's in the bubble right now".
        let showTypingDots = role == .assistant &&
            (isThinking || (isStreaming && rawText.isEmpty))
        if showTypingDots {
            typingDots.isHidden = false
            typingDots.startAnimating()
            textView.textStorage?.setAttributedString(NSAttributedString(string: ""))
            return
        }
        typingDots.stopAnimating()
        typingDots.isHidden = true
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
        // V2_UI_OVERHAUL §4.5 stage-2 — streaming caret. Appends a
        // thin `▍` glyph in controlAccentColor at the end of the
        // streamed body so the user sees "more is coming" without a
        // separate animated subview. Removed automatically on the
        // next render after isStreaming flips false (Claude pattern).
        // Only on assistant turns mid-stream with non-empty display
        // text — the dots indicator handles the empty-body cases.
        let final: NSAttributedString
        if role == .assistant && isStreaming && !display.isEmpty {
            let mutable = NSMutableAttributedString(attributedString: attr)
            let caret = NSAttributedString(string: "▍", attributes: [
                .font: baseFont,
                .foregroundColor: NSColor.controlAccentColor
            ])
            mutable.append(caret)
            final = mutable
        } else {
            final = attr
        }
        textView.textStorage?.setAttributedString(final)
        if role == .assistant {
            applyDisclosureLayout()
        }
    }

    func textDidChange(_ notification: Notification) {
        recomputeHeight()
    }

    /// V2_UI_OVERHAUL §4.d.1 — right-click over the text body must
    /// produce the per-turn context menu (primary actions + overflow),
    /// not NSTextView's default edit menu (cut/copy/paste/look up/…).
    /// The default menu is the right surface inside an *editable* text
    /// view (during edit mode); when we're displaying read-only prose,
    /// the per-turn actions are what the user actually wants.
    func textView(
        _ view: NSTextView,
        menu: NSMenu,
        for event: NSEvent,
        at charIndex: Int
    ) -> NSMenu? {
        if isEditing {
            // Editing — keep AppKit's edit menu (cut/copy/paste/etc.).
            return menu
        }
        return self.menu(for: event)
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
        // V2_UI_OVERHAUL §4.5 — pre-§4.e.1 this pulsed the avatar's
        // opacity 1.0↔0.25 as the streaming signal. The dots view
        // (handled in renderRendered) is now the visible indicator;
        // the avatar stays at full opacity throughout. The only
        // remaining job here is suppressing the hover toolbar mid-
        // stream so a user mouse-over doesn't reveal regen/edit on a
        // turn that's actively being written into.
        if isStreaming {
            toolbar.alphaValue = 0
        }
        // Re-render so renderRendered's dots-vs-text decision picks up
        // the new isStreaming state immediately (rawText.isEmpty +
        // isStreaming → dots show even before tokens arrive).
        renderRendered()
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
        // V2_UI_OVERHAUL §4.d.1 / §4.d.2 — below the bubble: pillsRow
        // (variants pill + branches pill) above the toolbar, both
        // inside `belowBubbleStack`. Pills collapse via NSStackView's
        // hidden-collapse so the toolbar slides up cleanly when both
        // pills are hidden. The row contributes `variantsPillHeight`
        // (= 22pt) when *either* pill is shown.
        let variantsVisible = role == .assistant && variantCount > 1 && !isEditing
        let branchesVisible = hasSiblings && !isEditing
        let pillVisible = variantsVisible || branchesVisible
        let pillH: CGFloat = pillVisible
            ? TurnView.variantsPillHeight + DesignTokens.Spacing.xs
            : 0
        let h = speakerLabelHeight
            + disclosureH
            + bubbleH
            + toolbarTopGap
            + pillH
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
