import AppKit

/// Phase 9 §5.3b — labeled multi-line text input. Reused across Persona /
/// Greetings (firstMessage) / Examples / System tabs. Layout follows the
/// design-language application contract: label is `headline` (semibold,
/// label color); input is `body` (label color); hint below is `subheadline`
/// secondary; spacing uses tokens (xs between label and input, xs between
/// input and hint).
///
/// The text view auto-grows from `minHeight` (default 96pt) up to
/// `maxHeight` (default 320pt) before scrolling — for prose, this gives
/// authors a comfortable reading window without occupying the whole tab
/// when the field is short. Width target is 480pt: roughly 80 chars at
/// 13pt body, the readable-prose sweet spot.
/// NSTextView subclass that renders a placeholder string when empty.
/// AppKit doesn't ship a native multiline placeholder so we draw it
/// directly. Refreshes on string changes; styled per V2_DESIGN_LANGUAGE
/// §4 (`tertiaryLabelColor` for placeholder-inside-empty-field).
final class PlaceholderTextView: NSTextView {
    var placeholderString: String = "" {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty, !placeholderString.isEmpty else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font ?? NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.placeholderTextColor,
        ]
        let inset = textContainerInset
        let origin = NSPoint(x: inset.width + 5, y: inset.height)
        let bounds = self.bounds
        let drawRect = NSRect(
            x: origin.x,
            y: origin.y,
            width: bounds.width - origin.x * 2,
            height: bounds.height - origin.y * 2
        )
        (placeholderString as NSString).draw(in: drawRect, withAttributes: attrs)
    }

    override func didChangeText() {
        super.didChangeText()
        // The placeholder shows when string is empty; redraw when content
        // changes so toggling on / off is immediate.
        needsDisplay = true
    }
}

final class MultilineFieldView: NSView {

    var onChange: ((String) -> Void)?

    /// Phase 9 §5.4.b — invoked when the author hits Accept on a
    /// proposed value. The proposed text is already in the field via
    /// `stringValue` at the time this fires. Parent commits to draft.
    var onAcceptProposal: (() -> Void)?

    /// Invoked when the author rejects. The previous value is already
    /// restored at the time this fires. Parent recomputes draft state.
    var onRejectProposal: (() -> Void)?

    private let labelView = NSTextField(labelWithString: "")
    private let v3PillContainer = NSView()
    private let scrollView = NSScrollView()
    private let textView = PlaceholderTextView()
    private let hintView = NSTextField(labelWithString: "")

    /// Phase 9 §5.4.a — optional AI-assist suggestions strip below the
    /// input, above the hint. Constructed only when the caller passes
    /// `cardField:` to init; the wiring layer (per-tab view controller)
    /// attaches a `CardSuggestionsController` after construction.
    let suggestionsStrip: CardSuggestionsStripView?

    /// Phase 9 §5.4.b — proposed-state UI: yellow "Proposed" pill in
    /// the header row + Accept / Reject button row replacing the strip
    /// while a Mode-2 / Mode-3 fill is awaiting decision. Hidden in
    /// the default normal state.
    private let proposedBadge = NSTextField(labelWithString: "Proposed")
    private let proposalActionRow = NSStackView()
    private let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    private let proposalRefusalChip = NSTextField(labelWithString: "⚠ refusal")

    /// State machine for the field's editor. `.normal` is the default
    /// (strip visible if present, no proposed-mode UI). `.proposing`
    /// captures the previous value so reject can restore it; the
    /// strip is hidden and the action row is shown.
    private enum FieldMode {
        case normal
        case proposing(previousValue: String)
    }
    private var mode: FieldMode = .normal

    private let label: String
    private let hint: String?
    private let v3Only: Bool
    private let minHeight: CGFloat
    private let maxHeight: CGFloat

    private var heightConstraint: NSLayoutConstraint!

    var isShowingProposal: Bool {
        if case .proposing = mode { return true }
        return false
    }

    init(label: String,
         initialValue: String,
         hint: String? = nil,
         v3Only: Bool = false,
         placeholder: String? = nil,
         minHeight: CGFloat = 96,
         maxHeight: CGFloat = 320,
         hasSuggestionsStrip: Bool = false) {
        self.label = label
        self.hint = hint
        self.v3Only = v3Only
        self.minHeight = minHeight
        self.maxHeight = maxHeight
        self.suggestionsStrip = hasSuggestionsStrip ? CardSuggestionsStripView() : nil
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValue: initialValue, placeholder: placeholder)
        suggestionsStrip?.onUseCandidate = { [weak self] candidate in
            self?.applyCandidate(candidate)
        }
        suggestionsStrip?.onEditCandidate = { [weak self] candidate in
            // Edit-sheet deferred to §5.4.d polish — in the meantime,
            // Edit just behaves like Use. Keeps the button visible
            // and useful while the proper sheet UX gets designed.
            self?.applyCandidate(candidate)
        }
    }

    /// Set the field's text from a generated candidate. Marks dirty
    /// via the same onChange path the user's typing triggers.
    private func applyCandidate(_ candidate: CardCandidate) {
        textView.string = candidate.text
        // The textView delegate's textDidChange only fires on user
        // input, not on programmatic mutations — fire onChange here
        // so the surrounding tab marks the draft dirty.
        onChange?(candidate.text)
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    var stringValue: String {
        get { textView.string }
        set {
            textView.string = newValue
            recalculateHeight()
        }
    }

    private func buildUI(initialValue: String, placeholder: String?) {
        // Header row — label + v3 pill (if applicable).
        labelView.stringValue = label
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [labelView])
        header.orientation = .horizontal
        header.spacing = DesignTokens.Spacing.xs
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        if v3Only {
            header.addArrangedSubview(makeV3Pill())
        }
        // Yellow "Proposed" pill — hidden by default, made visible by
        // showProposal(...). Visual: same shape as the v3 pill but
        // tinted warning-yellow.
        configureProposedBadge()
        proposedBadge.isHidden = true
        header.addArrangedSubview(proposedBadge)
        addSubview(header)

        // Text view + scroll view — canonical NSScrollView-with-NSTextView
        // setup. Without minSize/maxSize/autoresizingMask, the textView's
        // frame can extend beyond the scrollView's visible bounds and
        // intercept clicks intended for sibling views below it (the
        // "click on Personality, type lands in Description" bug from the
        // smoke pass). See AppKit/NSTextView Programming Guide.
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.drawsBackground = true

        // textView uses springs/struts (the AppKit canonical pattern for
        // documentViews); width tracks the scrollView, vertical grows with
        // content, height is clipped to the scrollView's frame.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.isEditable = true
        textView.isRichText = false
        textView.usesFontPanel = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.string = initialValue
        textView.delegate = self
        if let placeholder = placeholder {
            textView.placeholderString = placeholder
        }

        scrollView.documentView = textView

        // Bezel-style background — `textBackgroundColor` adapts.
        addSubview(scrollView)

        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: minHeight)
        heightConstraint.priority = .defaultHigh

        // Build the proposal action row (Accept / Reject + warning chip).
        configureProposalActionRow()

        // Stack the post-textView elements vertically. NSStackView's
        // `detachesHiddenViews` (default true on macOS) collapses
        // any hidden arranged subview, so toggling visibility on
        // proposalActionRow / suggestionsStrip Just Works for layout.
        let belowField = NSStackView()
        belowField.orientation = .vertical
        belowField.alignment = .leading
        belowField.distribution = .fill
        belowField.spacing = DesignTokens.Spacing.xs
        belowField.translatesAutoresizingMaskIntoConstraints = false
        belowField.addArrangedSubview(proposalActionRow)
        proposalActionRow.isHidden = true
        if let strip = suggestionsStrip {
            belowField.addArrangedSubview(strip)
        }
        if let hintText = hint {
            hintView.stringValue = hintText
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.secondary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 3
            hintView.translatesAutoresizingMaskIntoConstraints = false
            belowField.addArrangedSubview(hintView)
        }
        addSubview(belowField)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            scrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightConstraint,

            belowField.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: DesignTokens.Spacing.xs),
            belowField.leadingAnchor.constraint(equalTo: leadingAnchor),
            belowField.trailingAnchor.constraint(equalTo: trailingAnchor),
            belowField.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        // Initial height calc once layout pass settles.
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    // MARK: - Proposed-state UI

    private func configureProposedBadge() {
        proposedBadge.font = DesignTokens.Typography.caption2
        proposedBadge.textColor = DesignTokens.Foreground.warning
        proposedBadge.translatesAutoresizingMaskIntoConstraints = false
        proposedBadge.drawsBackground = false
        proposedBadge.toolTip = "Proposed by AI-assist. Hit Accept to commit, Reject to discard, or just edit to override."
    }

    private func configureProposalActionRow() {
        acceptButton.bezelStyle = .rounded
        acceptButton.controlSize = .small
        acceptButton.target = self
        acceptButton.action = #selector(acceptProposalClicked)
        acceptButton.keyEquivalent = "\r"  // ⏎ accepts when the field is focused
        acceptButton.translatesAutoresizingMaskIntoConstraints = false

        rejectButton.bezelStyle = .rounded
        rejectButton.controlSize = .small
        rejectButton.target = self
        rejectButton.action = #selector(rejectProposalClicked)
        rejectButton.translatesAutoresizingMaskIntoConstraints = false

        proposalRefusalChip.font = DesignTokens.Typography.caption1
        proposalRefusalChip.textColor = DesignTokens.Foreground.warning
        proposalRefusalChip.toolTip = "This proposal looks like a refusal. Use anyway, switch the server, or reject."
        proposalRefusalChip.isHidden = true

        proposalActionRow.orientation = .horizontal
        proposalActionRow.alignment = .centerY
        proposalActionRow.spacing = DesignTokens.Spacing.sm
        proposalActionRow.translatesAutoresizingMaskIntoConstraints = false
        proposalActionRow.addArrangedSubview(acceptButton)
        proposalActionRow.addArrangedSubview(rejectButton)
        proposalActionRow.addArrangedSubview(NSView())  // spacer
        proposalActionRow.addArrangedSubview(proposalRefusalChip)
    }

    /// Phase 9 §5.4.b — switch the field into proposed mode. The
    /// current value is captured for `rejectProposal()` to restore;
    /// the proposed text is shown in the textView; the strip is
    /// hidden in favour of the Accept / Reject row.
    func showProposal(text: String, refusal: RefusalDetection) {
        let previous = textView.string
        mode = .proposing(previousValue: previous)
        textView.string = text
        proposedBadge.isHidden = false
        proposalActionRow.isHidden = false
        suggestionsStrip?.isHidden = true
        proposalRefusalChip.isHidden = !refusal.isRefusal
        DebugLog.shared.write("multilineField[\(label)]: showing proposal (\(text.count)c, refusal=\(refusal.isRefusal))")
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    /// Dismiss the proposal without applying. The captured previous
    /// value is restored. Caller's onRejectProposal fires; the parent
    /// re-syncs draft state if needed.
    func rejectProposal() {
        guard case .proposing(let previous) = mode else { return }
        textView.string = previous
        exitProposalMode()
        DebugLog.shared.write("multilineField[\(label)]: proposal rejected (restored \(previous.count)c)")
        onRejectProposal?()
        // Re-fire onChange so the parent knows the field's value is
        // back to the previous state (since we silently overwrote).
        onChange?(previous)
    }

    /// Commit the proposed value. The textView already shows it; we
    /// just exit proposal mode and fire the callbacks so the parent
    /// commits to the draft + triggers stale-propagation.
    func acceptProposal() {
        guard case .proposing = mode else { return }
        let accepted = textView.string
        exitProposalMode()
        DebugLog.shared.write("multilineField[\(label)]: proposal accepted (\(accepted.count)c)")
        onAcceptProposal?()
        onChange?(accepted)
    }

    /// Internal — flip back to normal-mode UI (badge + action row
    /// hidden, strip restored). Doesn't touch the text or fire
    /// callbacks; accept/reject paths handle that.
    private func exitProposalMode() {
        mode = .normal
        proposedBadge.isHidden = true
        proposalActionRow.isHidden = true
        proposalRefusalChip.isHidden = true
        suggestionsStrip?.isHidden = false
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    @objc private func acceptProposalClicked() { acceptProposal() }
    @objc private func rejectProposalClicked() { rejectProposal() }

    private func makeV3Pill() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.drawsBackground = false

        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.group
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }

    /// Re-derive the scroll view's height from the text view's intrinsic
    /// content. Clamps between min and max so the field auto-grows on
    /// short prose and starts scrolling on long.
    private func recalculateHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset.height * 2
        let target = max(minHeight, min(maxHeight, used.height + inset + 8))
        let prev = heightConstraint.constant
        if abs(prev - target) > 0.5 {
            heightConstraint.constant = target
            DebugLog.shared.write("multilineField[\(label)]: recalc \(Int(prev))→\(Int(target)) (used=\(Int(used.height)))")
        }
    }
}

extension MultilineFieldView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        // Phase 9 §5.4.b: editing while in proposing mode is an
        // implicit accept (per V2_PHASE9_CARD_CREATOR §4.7 step 4
        // — "or just edits inline (which auto-accepts)"). Flip out
        // of proposal mode silently; the textView already has the
        // new value and onChange fires below.
        if case .proposing = mode {
            DebugLog.shared.write("multilineField[\(label)]: edit-during-proposal → implicit accept")
            exitProposalMode()
            onAcceptProposal?()
        }
        let len = textView.string.count
        DebugLog.shared.write("multilineField[\(label)]: textDidChange len=\(len)")
        onChange?(textView.string)
        // Defer to next runloop so the resize doesn't fight the layout pass
        // that's still in flight from the paste/insert. Synchronous resize
        // during text-change can prevent first-responder transitions
        // (clicking another field becomes a no-op) and interleave layout
        // cycles.
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }
}
