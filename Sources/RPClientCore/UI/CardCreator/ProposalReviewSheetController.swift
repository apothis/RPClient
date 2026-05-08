import AppKit

/// Phase 9 §5.4.c slice 4 — modal sheet that hosts the Mode 3 diff
/// review. One row per `ProposalReviewModel.Row`: status pill, current
/// candidate text, per-field Accept / Reject / Re-roll / Lock buttons,
/// and a History menu that lists prior candidates with one-click revert.
/// Bulk header carries Accept-all / Reject-all / Re-roll-all-unlocked;
/// footer commits accepted proposals or cancels the run.
///
/// The sheet observes the model and re-renders rows on change. Re-rolls
/// fire upward via `onRerollField` / `onRerollAllUnlocked`; slice 5
/// wires those to the autopilot orchestrator's single-field path so a
/// new candidate lands via `didReceiveRerolledCandidate(...)`.

@MainActor
final class ProposalReviewSheetController: NSWindowController {

    let model: ProposalReviewModel
    var onCommit: (([CardFieldProposal]) -> Void)?
    var onCancel: (() -> Void)?
    var onRerollField: ((CardField) -> Void)?
    var onRerollAllUnlocked: (([CardField]) -> Void)?

    private let registry: CardGenPromptsRegistry
    private let stack = NSStackView()
    private let scroll = NSScrollView()
    private let summaryLabel = NSTextField(labelWithString: "")
    private let acceptAllButton = NSButton(title: "Accept all", target: nil, action: nil)
    private let rejectAllButton = NSButton(title: "Reject all", target: nil, action: nil)
    private let rerollAllButton = NSButton(title: "Re-roll all unlocked", target: nil, action: nil)
    private let commitButton = NSButton(title: "Commit", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private var rowViews: [CardField: ProposalReviewRowView] = [:]

    init(
        model: ProposalReviewModel,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) {
        self.model = model
        self.registry = registry
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 560),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review proposals"
        super.init(window: panel)
        buildUI()
        rebuildRows()
        model.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func beginSheet(over parent: NSWindow) {
        guard let w = window else { return }
        DebugLog.shared.write("cardgen: mode3 review sheet opened — \(model.rows.count) rows")
        parent.beginSheet(w) { _ in }
    }

    /// Slice 5 callback — the orchestrator delivered a fresh candidate
    /// for a re-rolled field. Push it onto the model's history; the
    /// row re-renders via `onChange`.
    func didReceiveRerolledCandidate(field: CardField, text: String) {
        DebugLog.shared.write("cardgen: mode3 reroll ✓ \(field.rawValue) (\(text.count)c)")
        model.pushCandidate(field, text: text)
    }

    // MARK: - UI

    private func buildUI() {
        guard let content = window?.contentView else { return }
        content.wantsLayer = true

        // Header: summary + bulk actions.
        summaryLabel.font = DesignTokens.Typography.headline
        summaryLabel.textColor = DesignTokens.Foreground.primary
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        for b in [acceptAllButton, rejectAllButton, rerollAllButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        acceptAllButton.target = self
        acceptAllButton.action = #selector(acceptAllClicked)
        rejectAllButton.target = self
        rejectAllButton.action = #selector(rejectAllClicked)
        rerollAllButton.target = self
        rerollAllButton.action = #selector(rerollAllClicked)

        let bulkRow = NSStackView(views: [
            summaryLabel, NSView(),
            rerollAllButton, rejectAllButton, acceptAllButton,
        ])
        bulkRow.orientation = .horizontal
        bulkRow.alignment = .centerY
        bulkRow.spacing = DesignTokens.Spacing.sm
        bulkRow.translatesAutoresizingMaskIntoConstraints = false

        let bulkSeparator = NSBox()
        bulkSeparator.boxType = .separator
        bulkSeparator.translatesAutoresizingMaskIntoConstraints = false

        // Body: scrollable stack of rows.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.md
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(
            top: DesignTokens.Spacing.md,
            left: DesignTokens.Spacing.lg,
            bottom: DesignTokens.Spacing.md,
            right: DesignTokens.Spacing.lg
        )

        let flipped = FlippedView()
        flipped.translatesAutoresizingMaskIntoConstraints = false
        flipped.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: flipped.topAnchor),
            stack.leadingAnchor.constraint(equalTo: flipped.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: flipped.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: flipped.bottomAnchor),
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = flipped

        // Footer: commit / cancel.
        for b in [commitButton, cancelButton] {
            b.bezelStyle = .rounded
            b.controlSize = .regular
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        commitButton.target = self
        commitButton.action = #selector(commitClicked)
        commitButton.keyEquivalent = "\r"
        commitButton.keyEquivalentModifierMask = [.command]
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1B}"

        let footerSeparator = NSBox()
        footerSeparator.boxType = .separator
        footerSeparator.translatesAutoresizingMaskIntoConstraints = false

        let footerRow = NSStackView(views: [cancelButton, NSView(), commitButton])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = DesignTokens.Spacing.sm
        footerRow.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(bulkRow)
        content.addSubview(bulkSeparator)
        content.addSubview(scroll)
        content.addSubview(footerSeparator)
        content.addSubview(footerRow)

        NSLayoutConstraint.activate([
            bulkRow.topAnchor.constraint(equalTo: content.topAnchor, constant: DesignTokens.Spacing.md),
            bulkRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            bulkRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            bulkSeparator.topAnchor.constraint(equalTo: bulkRow.bottomAnchor, constant: DesignTokens.Spacing.sm),
            bulkSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            bulkSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bulkSeparator.heightAnchor.constraint(equalToConstant: 1),

            scroll.topAnchor.constraint(equalTo: bulkSeparator.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: content.trailingAnchor),

            footerSeparator.bottomAnchor.constraint(equalTo: footerRow.topAnchor, constant: -DesignTokens.Spacing.sm),
            footerSeparator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            footerSeparator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            footerSeparator.heightAnchor.constraint(equalToConstant: 1),

            scroll.bottomAnchor.constraint(equalTo: footerSeparator.topAnchor),

            footerRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            footerRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),
            footerRow.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -DesignTokens.Spacing.md),
        ])
    }

    private func rebuildRows() {
        for v in stack.arrangedSubviews { stack.removeArrangedSubview(v); v.removeFromSuperview() }
        rowViews.removeAll()
        for row in model.rows {
            let humanName = registry.fields[row.field.rawValue]?.humanName ?? row.field.rawValue
            let view = ProposalReviewRowView(field: row.field, humanName: humanName)
            view.onAccept = { [weak self] in self?.handleAccept(row.field) }
            view.onReject = { [weak self] in self?.handleReject(row.field) }
            view.onReroll = { [weak self] in self?.handleReroll(row.field) }
            view.onLockToggle = { [weak self] in self?.handleLockToggle(row.field) }
            view.onRevertHistory = { [weak self] index in self?.handleRevert(row.field, index: index) }
            view.translatesAutoresizingMaskIntoConstraints = false
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DesignTokens.Spacing.lg * 2).isActive = true
            rowViews[row.field] = view
        }
        refresh()
    }

    private func refresh() {
        for row in model.rows {
            rowViews[row.field]?.update(with: row)
        }
        let accepted = model.rows.filter { $0.status == .accepted }.count
        let rejected = model.rows.filter { $0.status == .rejected }.count
        let proposed = model.rows.filter { $0.status == .proposed }.count
        let total = model.rows.count
        summaryLabel.stringValue = "\(total) fields — \(accepted) accepted · \(rejected) rejected · \(proposed) pending"
        commitButton.title = accepted == 0 ? "Commit" : "Commit (\(accepted))"
        commitButton.isEnabled = accepted > 0
        rerollAllButton.isEnabled = !model.unlockedFields.isEmpty
    }

    // MARK: - Actions

    private func handleAccept(_ field: CardField) {
        DebugLog.shared.write("cardgen: mode3 accept \(field.rawValue)")
        model.accept(field)
    }

    private func handleReject(_ field: CardField) {
        DebugLog.shared.write("cardgen: mode3 reject \(field.rawValue)")
        model.reject(field)
    }

    private func handleLockToggle(_ field: CardField) {
        model.toggleLock(field)
        DebugLog.shared.write("cardgen: mode3 lock toggled \(field.rawValue) → \(rowViews[field]?.isLocked == true ? "locked" : "unlocked")")
    }

    private func handleReroll(_ field: CardField) {
        DebugLog.shared.write("cardgen: mode3 reroll → \(field.rawValue)")
        rowViews[field]?.setRerolling(true)
        onRerollField?(field)
    }

    private func handleRevert(_ field: CardField, index: Int) {
        DebugLog.shared.write("cardgen: mode3 revert \(field.rawValue) → history[\(index)]")
        model.revertTo(field, historyIndex: index)
    }

    @objc private func acceptAllClicked() {
        DebugLog.shared.write("cardgen: mode3 acceptAll")
        model.acceptAll()
    }

    @objc private func rejectAllClicked() {
        DebugLog.shared.write("cardgen: mode3 rejectAll")
        model.rejectAll()
    }

    @objc private func rerollAllClicked() {
        let targets = model.unlockedFields
        guard !targets.isEmpty else { return }
        DebugLog.shared.write("cardgen: mode3 rerollAllUnlocked (\(targets.count) fields)")
        for f in targets { rowViews[f]?.setRerolling(true) }
        onRerollAllUnlocked?(targets)
    }

    @objc private func commitClicked() {
        let proposals = model.acceptedProposals
        DebugLog.shared.write("cardgen: mode3 commit \(proposals.count) proposals")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .OK) }
        onCommit?(proposals)
    }

    @objc private func cancelClicked() {
        DebugLog.shared.write("cardgen: mode3 review cancelled")
        if let parent = window?.sheetParent { parent.endSheet(window!, returnCode: .cancel) }
        onCancel?()
    }
}

/// NSStackView's documentView for an NSScrollView needs flipped
/// coordinates so it grows top-down inside the scroller.
private final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

// MARK: - Row view

@MainActor
final class ProposalReviewRowView: NSView {

    let field: CardField
    var onAccept: (() -> Void)?
    var onReject: (() -> Void)?
    var onReroll: (() -> Void)?
    var onLockToggle: (() -> Void)?
    var onRevertHistory: ((Int) -> Void)?

    private let labelView = NSTextField(labelWithString: "")
    private let statusPill = NSTextField(labelWithString: "")
    private let exemplarView = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private let lockButton = NSButton(title: "Lock", target: nil, action: nil)
    private let rerollButton = NSButton(title: "Re-roll", target: nil, action: nil)
    private let acceptButton = NSButton(title: "Accept", target: nil, action: nil)
    private let rejectButton = NSButton(title: "Reject", target: nil, action: nil)
    private let historyButton = NSButton(title: "History ⌄", target: nil, action: nil)
    private let refusalChip = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private(set) var isLocked = false
    private var historyEntries: [String] = []

    init(field: CardField, humanName: String) {
        self.field = field
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = DesignTokens.Radius.section
        layer?.borderWidth = 1
        layer?.borderColor = NSColor.separatorColor.cgColor

        labelView.stringValue = humanName
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        statusPill.font = DesignTokens.Typography.caption1
        statusPill.translatesAutoresizingMaskIntoConstraints = false
        statusPill.wantsLayer = true
        statusPill.layer?.cornerRadius = DesignTokens.Radius.chip
        statusPill.drawsBackground = true
        statusPill.isBordered = false

        exemplarView.font = DesignTokens.Typography.caption2
        exemplarView.textColor = DesignTokens.Foreground.tertiary
        exemplarView.translatesAutoresizingMaskIntoConstraints = false

        refusalChip.font = DesignTokens.Typography.caption2
        refusalChip.textColor = DesignTokens.Foreground.warning
        refusalChip.translatesAutoresizingMaskIntoConstraints = false
        refusalChip.isHidden = true

        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = true
        textView.backgroundColor = DesignTokens.Background.textInput
        textView.textContainerInset = NSSize(width: DesignTokens.Spacing.sm, height: DesignTokens.Spacing.sm)
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false

        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.borderType = .lineBorder
        textScroll.hasVerticalScroller = true
        textScroll.translatesAutoresizingMaskIntoConstraints = false

        for b in [lockButton, rerollButton, acceptButton, rejectButton, historyButton] {
            b.bezelStyle = .rounded
            b.controlSize = .small
            b.translatesAutoresizingMaskIntoConstraints = false
        }
        lockButton.target = self
        lockButton.action = #selector(lockClicked)
        rerollButton.target = self
        rerollButton.action = #selector(rerollClicked)
        acceptButton.target = self
        acceptButton.action = #selector(acceptClicked)
        rejectButton.target = self
        rejectButton.action = #selector(rejectClicked)
        historyButton.target = self
        historyButton.action = #selector(historyClicked)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [labelView, statusPill, NSView(), exemplarView, refusalChip])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = DesignTokens.Spacing.sm
        header.translatesAutoresizingMaskIntoConstraints = false

        let actionRow = NSStackView(views: [
            historyButton, NSView(),
            spinner, lockButton, rerollButton, rejectButton, acceptButton,
        ])
        actionRow.orientation = .horizontal
        actionRow.alignment = .centerY
        actionRow.spacing = DesignTokens.Spacing.xs
        actionRow.translatesAutoresizingMaskIntoConstraints = false

        addSubview(header)
        addSubview(textScroll)
        addSubview(actionRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Spacing.sm),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),

            textScroll.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
            textScroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            textScroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),
            textScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 80),

            actionRow.topAnchor.constraint(equalTo: textScroll.bottomAnchor, constant: DesignTokens.Spacing.xs),
            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Spacing.sm),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(with row: ProposalReviewModel.Row) {
        textView.string = row.current
        historyEntries = row.history

        switch row.status {
        case .proposed:
            statusPill.stringValue = " Proposed "
            statusPill.textColor = DesignTokens.Foreground.primary
            statusPill.layer?.backgroundColor = NSColor.systemYellow.withAlphaComponent(0.2).cgColor
        case .accepted:
            statusPill.stringValue = " Accepted "
            statusPill.textColor = DesignTokens.Foreground.primary
            statusPill.layer?.backgroundColor = NSColor.systemGreen.withAlphaComponent(0.2).cgColor
        case .rejected:
            statusPill.stringValue = " Rejected "
            statusPill.textColor = DesignTokens.Foreground.secondary
            statusPill.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15).cgColor
        }

        isLocked = row.locked
        lockButton.title = row.locked ? "🔒" : "🔓"
        lockButton.toolTip = row.locked
            ? "Locked — Re-roll all unlocked will skip this field. Click to unlock."
            : "Unlocked — Re-roll all unlocked will regenerate this field. Click to lock."

        exemplarView.stringValue = "exemplar: \(row.exemplarId)"

        refusalChip.isHidden = !row.refusal.isRefusal
        if row.refusal.isRefusal {
            refusalChip.stringValue = "⚠︎ refusal-shaped"
            refusalChip.toolTip = "The model may have refused. Re-roll or switch the server."
        }

        historyButton.isEnabled = row.history.count > 1
        historyButton.title = row.history.count > 1 ? "History (\(row.history.count)) ⌄" : "History"

        // Stop spinner if we landed back in a real state (a re-roll completed).
        spinner.stopAnimation(nil)
    }

    func setRerolling(_ on: Bool) {
        if on { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
    }

    @objc private func lockClicked() { onLockToggle?() }
    @objc private func rerollClicked() { onReroll?() }
    @objc private func acceptClicked() { onAccept?() }
    @objc private func rejectClicked() { onReject?() }

    @objc private func historyClicked() {
        guard historyEntries.count > 1 else { return }
        let menu = NSMenu()
        for (idx, candidate) in historyEntries.enumerated() {
            let preview = candidate.replacingOccurrences(of: "\n", with: " ").prefix(80)
            let title = idx == 0 ? "current — \(preview)" : "revert to — \(preview)"
            let item = NSMenuItem(
                title: title,
                action: #selector(historyItemSelected(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.tag = idx
            item.isEnabled = idx != 0
            menu.addItem(item)
        }
        let location = NSPoint(x: 0, y: historyButton.bounds.height + 2)
        menu.popUp(positioning: nil, at: location, in: historyButton)
    }

    @objc private func historyItemSelected(_ sender: NSMenuItem) {
        onRevertHistory?(sender.tag)
    }
}
