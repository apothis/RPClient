import AppKit

/// Phase 9 §5.4.a — UI surface for the §4.1 Suggestions strip.
/// Renders a `CardSuggestionsController`'s state and surfaces the
/// authoring actions (Generate / Refresh / Cancel / Use / Edit /
/// Re-roll a single slot).
///
/// Layout follows V2_DESIGN_LANGUAGE: subheadline-secondary header
/// row, group-background card chrome, accent on the primary action
/// only. Closed by default; once expanded, stays open for the
/// session per §4.1.
///
/// Intentionally narrow — owns no draft state, no server-resolution
/// logic, no template assembly. The wiring layer (the per-tab view
/// controller in CardCreatorTabs) builds the controller and hands it
/// in; this view just reflects state.
final class CardSuggestionsStripView: NSView {

    // MARK: - Public callbacks

    /// Called when the author clicks "Use" on a candidate. The
    /// container (typically a `MultilineFieldView`) writes the
    /// candidate's text into the underlying field.
    var onUseCandidate: ((CardCandidate) -> Void)?

    /// Called when the author clicks "Edit". The current minimum-viable
    /// implementation falls back to onUseCandidate (the §4.1 sheet-
    /// based editor lands in §5.4.d polish).
    var onEditCandidate: ((CardCandidate) -> Void)?

    /// Called when the author wants to fire / refresh the triad. The
    /// container hands a fresh `CardDraftSnapshot` to the controller.
    var onRequestGenerate: (() -> Void)?

    var controller: CardSuggestionsController? {
        didSet {
            controller?.onStateChange = { [weak self] state in
                self?.render(state: state)
            }
            render(state: controller?.state ?? .idle)
        }
    }

    // MARK: - Subviews

    private let titleLabel = NSTextField(labelWithString: "Suggestions")
    private let statusLabel = NSTextField(labelWithString: "")
    private let primaryButton = NSButton(title: "Generate", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let bodyContainer = NSStackView()

    // Three card slots — re-bound to current candidates on each render.
    private var cardSlots: [CandidateCardView] = []

    // MARK: - Init

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI()
        render(state: .idle)
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Layout

    private func buildUI() {
        titleLabel.font = DesignTokens.Typography.subheadline
        titleLabel.textColor = DesignTokens.Foreground.secondary

        statusLabel.font = DesignTokens.Typography.subheadline
        statusLabel.textColor = DesignTokens.Foreground.tertiary
        statusLabel.lineBreakMode = .byTruncatingTail

        primaryButton.bezelStyle = .rounded
        primaryButton.controlSize = .small
        primaryButton.target = self
        primaryButton.action = #selector(primaryClicked)
        primaryButton.translatesAutoresizingMaskIntoConstraints = false

        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .small
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.isHidden = true

        let header = NSStackView(views: [
            titleLabel, primaryButton, cancelButton, NSView(), statusLabel,
        ])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DesignTokens.Spacing.sm
        header.translatesAutoresizingMaskIntoConstraints = false
        addSubview(header)

        bodyContainer.orientation = .horizontal
        bodyContainer.alignment = .top
        bodyContainer.distribution = .fillEqually
        bodyContainer.spacing = DesignTokens.Spacing.sm
        bodyContainer.translatesAutoresizingMaskIntoConstraints = false
        bodyContainer.isHidden = true
        addSubview(bodyContainer)

        // Pre-build three slot views; show/hide + re-bind contents on
        // state changes. Avoids reconstructing AppKit views per render
        // (which kills focus + flickers).
        for idx in 0..<3 {
            let slot = CandidateCardView()
            slot.onUse = { [weak self] in self?.handleUse(slotIdx: idx) }
            slot.onEdit = { [weak self] in self?.handleEdit(slotIdx: idx) }
            cardSlots.append(slot)
            bodyContainer.addArrangedSubview(slot)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(equalTo: trailingAnchor),

            bodyContainer.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.sm),
            bodyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            bodyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),
            bodyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    // MARK: - Render

    private func render(state: CardSuggestionsController.State) {
        // Body shows whenever there's content (cards or progress text);
        // hidden in .idle / .failed because there's nothing useful to
        // render below the header.
        bodyContainer.isHidden = !hasBodyContent(state: state)

        switch state {
        case .idle:
            primaryButton.title = "Generate"
            primaryButton.isEnabled = true
            cancelButton.isHidden = true
            statusLabel.stringValue = ""
        case .generating(let n, let total):
            primaryButton.title = "Generate"
            primaryButton.isEnabled = false
            cancelButton.isHidden = false
            statusLabel.stringValue = "Generating \(n) of \(total)…"
        case .ready(let candidates):
            primaryButton.title = "Refresh"
            primaryButton.isEnabled = true
            cancelButton.isHidden = true
            statusLabel.stringValue = ""
            bindCandidates(candidates, stale: false)
        case .stale(let candidates):
            primaryButton.title = "Refresh"
            primaryButton.isEnabled = true
            cancelButton.isHidden = true
            statusLabel.stringValue = "stale"
            statusLabel.textColor = DesignTokens.Foreground.warning
            bindCandidates(candidates, stale: true)
        case .failed(let message):
            primaryButton.title = "Try again"
            primaryButton.isEnabled = true
            cancelButton.isHidden = true
            statusLabel.stringValue = message
            statusLabel.textColor = DesignTokens.Foreground.destructive
        }
    }

    private func hasBodyContent(state: CardSuggestionsController.State) -> Bool {
        switch state {
        case .idle: return false
        case .generating: return true
        case .ready, .stale: return true
        case .failed: return false
        }
    }

    private func bindCandidates(_ candidates: [CardCandidate], stale: Bool) {
        for (i, slot) in cardSlots.enumerated() {
            if i < candidates.count {
                slot.bind(candidate: candidates[i], stale: stale)
                slot.isHidden = false
            } else {
                slot.isHidden = true
            }
        }
    }

    // MARK: - Actions

    @objc private func primaryClicked() {
        // Generate / Refresh / Try again all route through the same
        // request — the container hands a fresh draft snapshot to the
        // controller via onRequestGenerate.
        DebugLog.shared.write("cardgen: strip request generate")
        onRequestGenerate?()
    }

    @objc private func cancelClicked() {
        DebugLog.shared.write("cardgen: strip cancel")
        controller?.cancel()
    }

    private func handleUse(slotIdx: Int) {
        guard let candidate = candidate(at: slotIdx) else { return }
        DebugLog.shared.write("cardgen: strip use [\(candidate.style.rawValue)]")
        onUseCandidate?(candidate)
    }

    private func handleEdit(slotIdx: Int) {
        guard let candidate = candidate(at: slotIdx) else { return }
        DebugLog.shared.write("cardgen: strip edit [\(candidate.style.rawValue)] (sheet deferred)")
        onEditCandidate?(candidate)
    }

    private func candidate(at idx: Int) -> CardCandidate? {
        guard let state = controller?.state else { return nil }
        let candidates: [CardCandidate]
        switch state {
        case .ready(let c), .stale(let c): candidates = c
        default: return nil
        }
        guard idx < candidates.count else { return nil }
        return candidates[idx]
    }
}

// MARK: - CandidateCardView

/// One of the three slots in the strip. Style label + candidate text +
/// refusal warning + Use / Edit buttons. Bezel + group background per
/// V2_DESIGN_LANGUAGE §6.
private final class CandidateCardView: NSView {
    var onUse: (() -> Void)?
    var onEdit: (() -> Void)?

    private let styleLabel = NSTextField(labelWithString: "")
    private let warningChip = NSTextField(labelWithString: "⚠")
    private let textView = NSTextField(wrappingLabelWithString: "")
    private let useButton = NSButton(title: "Use", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.backgroundColor = DesignTokens.Background.group.cgColor
        layer?.cornerRadius = DesignTokens.Radius.control
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        buildUI()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI() {
        styleLabel.font = DesignTokens.Typography.caption1
        styleLabel.textColor = DesignTokens.Foreground.secondary

        warningChip.font = DesignTokens.Typography.caption1
        warningChip.textColor = DesignTokens.Foreground.warning
        warningChip.toolTip = "Looks like a refusal — try a different server"
        warningChip.isHidden = true

        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.maximumNumberOfLines = 8
        textView.lineBreakMode = .byTruncatingTail
        textView.cell?.wraps = true
        textView.cell?.isScrollable = false
        textView.translatesAutoresizingMaskIntoConstraints = false

        useButton.bezelStyle = .rounded
        useButton.controlSize = .small
        useButton.target = self
        useButton.action = #selector(useClicked)

        editButton.bezelStyle = .rounded
        editButton.controlSize = .small
        editButton.target = self
        editButton.action = #selector(editClicked)

        let header = NSStackView(views: [styleLabel, warningChip])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = DesignTokens.Spacing.xs

        let buttons = NSStackView(views: [useButton, editButton, NSView()])
        buttons.orientation = .horizontal
        buttons.alignment = .centerY
        buttons.spacing = DesignTokens.Spacing.xs

        let stack = NSStackView(views: [header, textView, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Spacing.sm),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Spacing.sm),
        ])
    }

    func bind(candidate: CardCandidate, stale: Bool) {
        styleLabel.stringValue = candidate.style.rawValue
        textView.stringValue = candidate.text
        warningChip.isHidden = !candidate.refusal.isRefusal
        let alpha: CGFloat = stale ? 0.5 : 1.0
        styleLabel.alphaValue = alpha
        textView.alphaValue = alpha
        useButton.isEnabled = !stale
    }

    @objc private func useClicked() { onUse?() }
    @objc private func editClicked() { onEdit?() }
}
