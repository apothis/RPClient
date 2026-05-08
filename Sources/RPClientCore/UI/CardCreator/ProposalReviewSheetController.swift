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
    private let tabStrip = NSSegmentedControl()
    private var rowViews: [CardField: ProposalReviewRowView] = [:]
    /// nil = "All" segment selected. Otherwise the chosen Card Creator
    /// tab — only rows whose field belongs to that section render, and
    /// bulk actions (accept-all / reject-all / re-roll-all-unlocked)
    /// scope to that section.
    private var currentFilter: ProposalReviewSection?
    /// Sections that have ≥1 row in the current proposal set, in
    /// canonical order. Empty sections are dropped from the tab strip.
    private var visibleSections: [ProposalReviewSection] = []

    init(
        model: ProposalReviewModel,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) {
        self.model = model
        self.registry = registry
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .resizable, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "Review proposals"
        // contentMinSize / contentMaxSize cap the CONTENT size (excludes
        // title bar). Unlike `minSize` / `maxSize`, AppKit honors these
        // when sizing the sheet from Auto Layout on display, not just
        // for user resize. Three prior fixes via constraint priorities
        // and `maxSize` did not cap initial sheet width.
        panel.contentMinSize = NSSize(width: 720, height: 560)
        panel.contentMaxSize = NSSize(width: 1100, height: 1200)
        super.init(window: panel)
        buildUI()
        rebuildRows()
        model.onChange = { [weak self] in self?.refresh() }
    }

    required init?(coder: NSCoder) { fatalError() }

    func beginSheet(over parent: NSWindow) {
        guard let w = window else { return }
        DebugLog.shared.write("cardgen: mode3 review sheet opened — \(model.rows.count) rows")
        // Force the desired content size BEFORE display so AppKit
        // doesn't grow the panel to fit Auto Layout's intrinsic
        // demands. The contentMaxSize cap will keep it bounded.
        w.setContentSize(NSSize(width: 920, height: 700))
        // Show as a CHILD WINDOW, not a sheet. Sheets are pinned to
        // the parent's title bar and can't be dragged; for a review
        // workflow with 26 rows the user wants to position the panel
        // freely on the screen. Child window stays above the parent
        // and follows it if the parent moves, but the panel itself
        // is fully draggable via its own title bar.
        parent.addChildWindow(w, ordered: .above)
        w.center()
        w.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let win = self?.window else { return }
            DebugLog.shared.write("cardgen: mode3 sheet frame after open = \(Int(win.frame.width))×\(Int(win.frame.height)) content=\(Int(win.contentView?.frame.width ?? 0))×\(Int(win.contentView?.frame.height ?? 0))")
        }
    }

    /// Detach from parent and close. Used by both commit and cancel
    /// paths — sheet vs child-window dismiss require different APIs.
    private func dismissPanel() {
        guard let w = window else { return }
        if let sheetParent = w.sheetParent {
            sheetParent.endSheet(w, returnCode: .OK)
        } else {
            w.parent?.removeChildWindow(w)
            w.orderOut(nil)
        }
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
        // Belt-and-braces — even if a child view's intrinsic content
        // size demands a screen-wide layout, the contentView won't
        // exceed this. Combined with `panel.contentMaxSize` this
        // guarantees the sheet fits on a 14" laptop.
        content.widthAnchor.constraint(lessThanOrEqualToConstant: 1100).isActive = true

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

        // Tab strip mirrors the Card Creator's tab order. Populated
        // dynamically in `rebuildTabStrip()` once we know which
        // sections have rows.
        tabStrip.segmentStyle = .texturedRounded
        tabStrip.target = self
        tabStrip.action = #selector(tabSelectionChanged)
        tabStrip.translatesAutoresizingMaskIntoConstraints = false

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
            stack.bottomAnchor.constraint(equalTo: flipped.bottomAnchor),
        ])

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        scroll.documentView = flipped
        // Bind the document view's width to the scroll view's own
        // width (NOT to the clipView). The clipView's width depends
        // on the document view's size, which creates a feedback
        // loop that lets row intrinsic-width demands push the whole
        // sheet wider than the screen. The scrollView's own width
        // is set by its leading/trailing constraints to the panel
        // content view, so it's a stable anchor.
        flipped.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -2).isActive = true

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
        content.addSubview(tabStrip)
        content.addSubview(bulkSeparator)
        content.addSubview(scroll)
        content.addSubview(footerSeparator)
        content.addSubview(footerRow)

        NSLayoutConstraint.activate([
            bulkRow.topAnchor.constraint(equalTo: content.topAnchor, constant: DesignTokens.Spacing.md),
            bulkRow.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            bulkRow.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            tabStrip.topAnchor.constraint(equalTo: bulkRow.bottomAnchor, constant: DesignTokens.Spacing.sm),
            tabStrip.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: DesignTokens.Spacing.lg),
            tabStrip.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            bulkSeparator.topAnchor.constraint(equalTo: tabStrip.bottomAnchor, constant: DesignTokens.Spacing.sm),
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
            // Don't push horizontally — let the row grow to whatever
            // the stack offers. Without this the NSTextView's used-
            // width can be reported upstream and force the panel wide.
            view.setContentHuggingPriority(.defaultLow, for: .horizontal)
            view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            stack.addArrangedSubview(view)
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DesignTokens.Spacing.lg * 2).isActive = true
            rowViews[row.field] = view
        }
        rebuildTabStrip()
        applyFilter()
        refresh()
    }

    private func rebuildTabStrip() {
        let present = Set(model.rows.map { ProposalReviewSection.section(for: $0.field) })
        visibleSections = ProposalReviewSection.allCases.filter { present.contains($0) }

        // "All" + every section that owns at least one row in this run.
        let segments = ["All"] + visibleSections.map { $0.displayName }
        tabStrip.segmentCount = segments.count
        for (i, label) in segments.enumerated() {
            tabStrip.setLabel(label, forSegment: i)
        }

        // Drop the filter if the formerly-selected section no longer
        // has any rows (e.g. caller swapped in a fresh proposal set).
        if let f = currentFilter, !visibleSections.contains(f) {
            currentFilter = nil
        }
        tabStrip.selectedSegment = selectedSegmentIndex()
    }

    private func selectedSegmentIndex() -> Int {
        guard let f = currentFilter, let idx = visibleSections.firstIndex(of: f) else { return 0 }
        return idx + 1   // +1 for the leading "All" segment
    }

    /// Show only rows whose field belongs to the current filter (or
    /// every row if the filter is "All").
    private func applyFilter() {
        for row in model.rows {
            guard let view = rowViews[row.field] else { continue }
            let visible = currentFilter.map { ProposalReviewSection.section(for: row.field) == $0 } ?? true
            view.isHidden = !visible
        }
    }

    /// Rows the bulk actions and summary label apply to — every row by
    /// default, or the rows owned by the active section when filtered.
    private var filteredRows: [ProposalReviewModel.Row] {
        guard let f = currentFilter else { return model.rows }
        return model.rows.filter { ProposalReviewSection.section(for: $0.field) == f }
    }

    private func refresh() {
        for row in model.rows {
            rowViews[row.field]?.update(with: row)
        }
        let scope = filteredRows
        let accepted = scope.filter { $0.status == .accepted }.count
        let rejected = scope.filter { $0.status == .rejected }.count
        let proposed = scope.filter { $0.status == .proposed }.count
        let total = scope.count
        let scopeLabel = currentFilter?.displayName ?? "fields"
        if currentFilter == nil {
            summaryLabel.stringValue = "\(total) fields — \(accepted) accepted · \(rejected) rejected · \(proposed) pending"
        } else {
            summaryLabel.stringValue = "\(scopeLabel): \(total) fields — \(accepted) accepted · \(rejected) rejected · \(proposed) pending"
        }

        // Rebuild the tab labels with the section pending counts so
        // the user can see at a glance which tabs still have work.
        if tabStrip.segmentCount > 0 {
            tabStrip.setLabel("All (\(model.rows.filter { $0.status == .proposed }.count))", forSegment: 0)
            for (i, sec) in visibleSections.enumerated() {
                let pendingInSection = model.rows
                    .filter { ProposalReviewSection.section(for: $0.field) == sec && $0.status == .proposed }
                    .count
                let label = pendingInSection > 0
                    ? "\(sec.displayName) (\(pendingInSection))"
                    : sec.displayName
                tabStrip.setLabel(label, forSegment: i + 1)
            }
        }

        // Commit always reflects the global accepted count — closing
        // the sheet writes every accepted proposal regardless of the
        // tab the user happened to be on.
        let totalAccepted = model.rows.filter { $0.status == .accepted }.count
        commitButton.title = totalAccepted == 0 ? "Commit" : "Commit (\(totalAccepted))"
        commitButton.isEnabled = totalAccepted > 0

        let unlockedInScope = scope.filter { !$0.locked }
        rerollAllButton.isEnabled = !unlockedInScope.isEmpty
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
        let scope = filteredRows
        DebugLog.shared.write("cardgen: mode3 acceptAll (\(currentFilter?.rawValue ?? "all"), \(scope.count) rows)")
        if currentFilter == nil {
            model.acceptAll()
        } else {
            for r in scope { model.accept(r.field) }
        }
    }

    @objc private func rejectAllClicked() {
        let scope = filteredRows
        DebugLog.shared.write("cardgen: mode3 rejectAll (\(currentFilter?.rawValue ?? "all"), \(scope.count) rows)")
        if currentFilter == nil {
            model.rejectAll()
        } else {
            for r in scope { model.reject(r.field) }
        }
    }

    @objc private func rerollAllClicked() {
        let targets = filteredRows.filter { !$0.locked }.map { $0.field }
        guard !targets.isEmpty else { return }
        DebugLog.shared.write("cardgen: mode3 rerollAllUnlocked (\(currentFilter?.rawValue ?? "all"), \(targets.count) fields)")
        for f in targets { rowViews[f]?.setRerolling(true) }
        onRerollAllUnlocked?(targets)
    }

    @objc private func tabSelectionChanged() {
        let idx = tabStrip.selectedSegment
        if idx <= 0 {
            currentFilter = nil
        } else {
            let sectionIndex = idx - 1
            currentFilter = sectionIndex < visibleSections.count ? visibleSections[sectionIndex] : nil
        }
        DebugLog.shared.write("cardgen: mode3 tab → \(currentFilter?.rawValue ?? "all")")
        applyFilter()
        refresh()
    }

    @objc private func commitClicked() {
        let proposals = model.acceptedProposals
        DebugLog.shared.write("cardgen: mode3 commit \(proposals.count) proposals")
        dismissPanel()
        onCommit?(proposals)
    }

    @objc private func cancelClicked() {
        DebugLog.shared.write("cardgen: mode3 review cancelled")
        dismissPanel()
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
    /// Wrapping label, NOT NSTextView. The previous NSTextView-in-
    /// NSScrollView setup never engaged word wrap on initial layout —
    /// the text container reported a screen-wide used-width and forced
    /// the whole sheet off-screen (caught in §5.4.c smoke screenshot).
    /// `wrappingLabelWithString` uses Auto Layout's preferredMaxLayoutWidth
    /// machinery, which actually wraps when leading/trailing constraints
    /// pin the field's width.
    private let textView = NSTextField(wrappingLabelWithString: "")
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

        // wrappingLabelWithString already sets isEditable=false,
        // isSelectable=true, isBezeled=false, drawsBackground=false,
        // lineBreakMode=byWordWrapping, usesSingleLineMode=false. We
        // just style it and let Auto Layout drive width-based wrapping.
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.drawsBackground = true
        textView.backgroundColor = DesignTokens.Background.textInput
        textView.translatesAutoresizingMaskIntoConstraints = false
        // Don't push the row wider than the container. With low hugging
        // and compression resistance, the field shrinks to whatever the
        // row offers and wraps.
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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
        addSubview(textView)
        addSubview(actionRow)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Spacing.sm),
            header.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            header.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
            textView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            textView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),

            actionRow.topAnchor.constraint(equalTo: textView.bottomAnchor, constant: DesignTokens.Spacing.xs),
            actionRow.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DesignTokens.Spacing.sm),
            actionRow.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DesignTokens.Spacing.sm),
            actionRow.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Spacing.sm),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func update(with row: ProposalReviewModel.Row) {
        textView.stringValue = row.current
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
        lockButton.title = row.locked ? "🔒 Locked" : "🔓 Unlocked"
        // Tinted bezel makes the lock state immediately legible at
        // a glance — emoji alone wasn't enough contrast.
        lockButton.bezelColor = row.locked ? NSColor.systemRed : NSColor.systemGreen
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
