import AppKit

/// Phase 9 §5.3a — root view controller for the Card Creator window.
/// Lays out the three structural rows: header (server picker + AI model
/// label), tabbed body (Identity / Persona / Greetings / Examples / System /
/// Lorebook / Advanced), footer (Cancel / Save). Tab content for §5.3b/c is
/// stubbed with placeholder views; only the Identity tab is live in §5.3a.
///
/// Owns the `CharacterDraft` and propagates dirty events from the tab
/// children. Save / Cancel are routed through the window controller for the
/// dirty-on-close prompt.
final class CardCreatorViewController: NSViewController {

    let draft: CharacterDraft
    var onSave: ((UUID) -> Void)?
    var onCancel: (() -> Void)?
    var onDirtyChanged: (() -> Void)?

    /// Phase 9 §5.4.a — per-window AI controller registry. Constructed
    /// once per draft; passed to tabs so they share the same
    /// CardSuggestionsController instances and stale-propagation hits
    /// across tabs.
    private lazy var aiRegistry = CardCreatorAIRegistry(draft: draft)

    /// Strong reference to the Identity tab so saveClicked() can fire
    /// `commitPendingTagPromotions()` before flushing the draft. The
    /// tab is also reachable via NSTabView's tabViewItems array but
    /// keeping a typed reference avoids per-save downcasting.
    private var identityTab: IdentityTabViewController!

    /// Phase 9 §5.4.b — collected (CardField, MultilineFieldView) pairs
    /// across every AIAssistableTab. Used by the multi-field fill
    /// dispatch + bulk Accept-all / Reject-all paths. Built once after
    /// tabs are added.
    private var aiAssistableFields: [(CardField, MultilineFieldView)] = []

    /// Phase 9 §5.4.b — single per-window orchestrator for Mode 2
    /// fills. Constructed lazily from the per-window cardCreatorClient.
    private var multiOrchestrator: CardMultiFieldOrchestrator?

    /// Banner above the tab strip showing "N fields proposed" + Accept
    /// all / Reject all. Hidden when no field is in proposed state.
    private let proposalBanner = NSStackView()
    private let proposalBannerLabel = NSTextField(labelWithString: "")
    private let acceptAllButton = NSButton(title: "Accept all", target: nil, action: nil)
    private let rejectAllButton = NSButton(title: "Reject all", target: nil, action: nil)
    private let cancelFillButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let fillButton = NSButton(title: "Fill missing fields", target: nil, action: nil)
    private let fillSpinner = NSProgressIndicator()

    private let tabView = NSTabView()
    private let serverPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let modelLabel = NSTextField(labelWithString: "")
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)
    private let dirtyDot = NSTextField(labelWithString: "•")

    init(draft: CharacterDraft) {
        self.draft = draft
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        // No explicit layer.backgroundColor — NSWindow paints its
        // contentView with windowBackgroundColor automatically and tracks
        // appearance changes. Setting the layer here would freeze a
        // light-mode CGColor and not flip on the system mode switch.
        let root = CardDropView()
        root.onCardFileDropped = { [weak self] url in self?.handleDroppedCardFile(url) }
        root.translatesAutoresizingMaskIntoConstraints = false
        self.view = root

        buildHeader(in: root)
        buildTabView(in: root)
        buildFooter(in: root)
        refreshDirtyDot()
    }

    // MARK: - Header

    private func buildHeader(in root: NSView) {
        let serverLabel = NSTextField(labelWithString: "Generation server")
        serverLabel.font = DesignTokens.Typography.subheadline
        serverLabel.textColor = DesignTokens.Foreground.secondary
        serverLabel.translatesAutoresizingMaskIntoConstraints = false

        serverPopup.translatesAutoresizingMaskIntoConstraints = false
        serverPopup.bezelStyle = .rounded
        serverPopup.controlSize = .regular
        populateServerPopup()

        modelLabel.font = DesignTokens.Typography.mono(.subheadline)
        modelLabel.textColor = DesignTokens.Foreground.tertiary
        modelLabel.translatesAutoresizingMaskIntoConstraints = false
        modelLabel.lineBreakMode = .byTruncatingTail
        modelLabel.stringValue = "—"

        // Phase 9 §5.4.b — global "Fill missing fields" button at the
        // trailing edge of the header, with a small spinner that
        // shows while the orchestrator is fetching.
        fillButton.bezelStyle = .rounded
        fillButton.controlSize = .regular
        fillButton.target = self
        fillButton.action = #selector(fillMissingFieldsClicked)
        fillButton.toolTip = "Generate proposed values for every empty multi-line field. Review with Accept / Reject before saving."
        fillButton.translatesAutoresizingMaskIntoConstraints = false

        fillSpinner.style = .spinning
        fillSpinner.controlSize = .small
        fillSpinner.isDisplayedWhenStopped = false
        fillSpinner.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [serverLabel, serverPopup, modelLabel])
        header.orientation = .horizontal
        header.alignment = .firstBaseline
        header.spacing = DesignTokens.Spacing.sm
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)
        root.addSubview(fillSpinner)
        root.addSubview(fillButton)

        // Hairline separator below the header.
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor, constant: DesignTokens.Spacing.md),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Spacing.lg),
            header.trailingAnchor.constraint(lessThanOrEqualTo: fillButton.leadingAnchor, constant: -DesignTokens.Spacing.sm),

            fillButton.firstBaselineAnchor.constraint(equalTo: serverLabel.firstBaselineAnchor),
            fillButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            fillSpinner.centerYAnchor.constraint(equalTo: fillButton.centerYAnchor),
            fillSpinner.trailingAnchor.constraint(equalTo: fillButton.leadingAnchor, constant: -DesignTokens.Spacing.sm),

            separator.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.md),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),
        ])

        // Tag the separator for layout below.
        separator.identifier = NSUserInterfaceItemIdentifier("CardCreator.headerSeparator")
    }

    private func populateServerPopup() {
        serverPopup.removeAllItems()
        let servers = AppState.shared.settings.servers
        for s in servers {
            serverPopup.addItem(withTitle: s.name)
            serverPopup.lastItem?.representedObject = s.id
        }
        serverPopup.target = self
        serverPopup.action = #selector(serverChanged)

        // Default selection: cardCreatorServerId → active chat's server →
        // defaultServerId.
        let defaultId = AppState.shared.settings.cardCreatorServerId
            ?? AppState.shared.currentChat?.serverId
            ?? AppState.shared.settings.defaultServerId
        if let idx = servers.firstIndex(where: { $0.id == defaultId }) {
            serverPopup.selectItem(at: idx)
        }
        refreshModelLabel()
    }

    @objc private func serverChanged() {
        guard let id = serverPopup.selectedItem?.representedObject as? UUID else { return }
        var s = AppState.shared.settings
        s.cardCreatorServerId = id
        AppState.shared.saveSettings(s)
        refreshModelLabel()
    }

    private func refreshModelLabel() {
        guard let id = serverPopup.selectedItem?.representedObject as? UUID,
              let server = AppState.shared.settings.servers.first(where: { $0.id == id }) else {
            modelLabel.stringValue = "—"
            return
        }
        modelLabel.stringValue = server.baseURL.absoluteString
    }

    // MARK: - Tab view

    private func buildTabView(in root: NSView) {
        tabView.tabViewType = .topTabsBezelBorder
        tabView.translatesAutoresizingMaskIntoConstraints = false
        tabView.delegate = self

        let onDirty: () -> Void = { [weak self] in self?.handleDirtyChanged() }

        identityTab = IdentityTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry)
        addTab(identityTab, label: "Identity")
        addTab(DetailsTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "Details")
        addTab(PersonaTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "Persona")
        addTab(IntimacyTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "Intimacy")
        addTab(GreetingsTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "Greetings")
        addTab(ExamplesTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "Examples")
        addTab(SystemTabViewController(draft: draft, onDirty: onDirty, aiRegistry: aiRegistry), label: "System")

        addTab(LorebookTabViewController(draft: draft), label: "Lorebook")
        addTab(AdvancedTabViewController(draft: draft, onDirty: onDirty), label: "Advanced")

        // Phase 9 §5.4.b — proposal banner above the tab strip.
        // Hidden by default; surfaces when ANY field is in proposed
        // state (after a Mode-2 fill returns).
        buildProposalBanner(in: root)

        root.addSubview(tabView)

        guard let separator = root.subviews.first(where: { $0.identifier?.rawValue == "CardCreator.headerSeparator" }) else { return }

        NSLayoutConstraint.activate([
            proposalBanner.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: DesignTokens.Spacing.sm),
            proposalBanner.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Spacing.lg),
            proposalBanner.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            tabView.topAnchor.constraint(equalTo: proposalBanner.bottomAnchor, constant: DesignTokens.Spacing.sm),
            tabView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Spacing.md),
            tabView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Spacing.md),
        ])

        // Collect AI-assistable fields + wire per-field accept/reject
        // hooks to refresh the bulk banner.
        collectAIAssistableFields()
    }

    private func buildProposalBanner(in root: NSView) {
        proposalBannerLabel.font = DesignTokens.Typography.subheadline
        proposalBannerLabel.textColor = DesignTokens.Foreground.warning

        acceptAllButton.bezelStyle = .rounded
        acceptAllButton.controlSize = .small
        acceptAllButton.target = self
        acceptAllButton.action = #selector(acceptAllProposalsClicked)

        rejectAllButton.bezelStyle = .rounded
        rejectAllButton.controlSize = .small
        rejectAllButton.target = self
        rejectAllButton.action = #selector(rejectAllProposalsClicked)

        cancelFillButton.bezelStyle = .rounded
        cancelFillButton.controlSize = .small
        cancelFillButton.target = self
        cancelFillButton.action = #selector(cancelFillClicked)

        proposalBanner.orientation = .horizontal
        proposalBanner.alignment = .centerY
        proposalBanner.spacing = DesignTokens.Spacing.sm
        proposalBanner.translatesAutoresizingMaskIntoConstraints = false
        proposalBanner.addArrangedSubview(proposalBannerLabel)
        proposalBanner.addArrangedSubview(NSView())  // spacer
        proposalBanner.addArrangedSubview(acceptAllButton)
        proposalBanner.addArrangedSubview(rejectAllButton)
        proposalBanner.addArrangedSubview(cancelFillButton)
        proposalBanner.isHidden = true
        root.addSubview(proposalBanner)
    }

    private func collectAIAssistableFields() {
        var collected: [(CardField, MultilineFieldView)] = []
        for item in tabView.tabViewItems {
            guard let vc = item.viewController as? AIAssistableTab else { continue }
            collected.append(contentsOf: vc.aiAssistableFields)
        }
        aiAssistableFields = collected
        // Per-field hooks: accept/reject just refresh the bulk banner.
        // The field's own onChange already commits to draft + marks
        // downstream stale.
        for (_, view) in aiAssistableFields {
            let existingAccept = view.onAcceptProposal
            let existingReject = view.onRejectProposal
            view.onAcceptProposal = { [weak self] in
                existingAccept?()
                self?.refreshProposalBanner()
            }
            view.onRejectProposal = { [weak self] in
                existingReject?()
                self?.refreshProposalBanner()
            }
        }
        DebugLog.shared.write("cardcreator: collected \(aiAssistableFields.count) AI-assistable fields")
    }

    // MARK: - Multi-field fill (§5.4.b)

    @objc private func fillMissingFieldsClicked() {
        let empties = aiAssistableFields.filter { $0.1.stringValue.isEmpty && !$0.1.isShowingProposal }
        guard !empties.isEmpty else {
            DebugLog.shared.write("cardgen: mode2 fillMissing — no empty fields to fill")
            return
        }
        let fields = empties.map(\.0)
        let snapshot = CardDraftSnapshotBuilder.snapshot(of: draft)

        if multiOrchestrator == nil {
            let kobold = AppState.shared.registry.cardCreatorClient(chatOverride: AppState.shared.currentChat?.serverId)
            multiOrchestrator = CardMultiFieldOrchestrator(generator: kobold)
            multiOrchestrator?.onStateChange = { [weak self] state in
                self?.handleMultiOrchestratorState(state)
            }
        }

        fillButton.isEnabled = false
        fillButton.title = "Filling…"
        multiOrchestrator?.fill(fields: fields, draft: snapshot)
    }

    @objc private func cancelFillClicked() {
        multiOrchestrator?.cancel()
        // For any field already in proposed state, treat cancel as
        // reject-all (cleanest; the user clicked Cancel after seeing
        // results they didn't want).
        rejectAllProposalsClicked()
    }

    @objc private func acceptAllProposalsClicked() {
        for (_, view) in aiAssistableFields where view.isShowingProposal {
            view.acceptProposal()
        }
        refreshProposalBanner()
    }

    @objc private func rejectAllProposalsClicked() {
        for (_, view) in aiAssistableFields where view.isShowingProposal {
            view.rejectProposal()
        }
        refreshProposalBanner()
    }

    private func handleMultiOrchestratorState(_ state: CardMultiFieldOrchestrator.State) {
        switch state {
        case .idle:
            fillButton.isEnabled = true
            fillButton.title = "Fill missing fields"
            fillSpinner.stopAnimation(nil)
        case .fetching(let n):
            fillButton.isEnabled = false
            fillButton.title = "Filling \(n) fields…"
            fillSpinner.startAnimation(nil)
        case .ready(let proposals):
            dispatchProposals(proposals)
            fillButton.isEnabled = true
            fillButton.title = "Fill missing fields"
            fillSpinner.stopAnimation(nil)
        case .failed(let m):
            fillButton.isEnabled = true
            fillButton.title = "Fill missing fields"
            fillSpinner.stopAnimation(nil)
            DebugLog.shared.write("cardgen: mode2 fill failed: \(m)")
            // TODO §5.4.d: surface error in a toast / alert.
        }
    }

    private func dispatchProposals(_ proposals: [CardFieldProposal]) {
        let lookup: [CardField: MultilineFieldView] = Dictionary(
            uniqueKeysWithValues: aiAssistableFields
        )
        for p in proposals {
            guard let view = lookup[p.field] else {
                DebugLog.shared.write("cardgen: mode2 dispatch — no field view for \(p.field.rawValue)")
                continue
            }
            view.showProposal(text: p.text, refusal: p.refusal)
        }
        refreshProposalBanner()
    }

    private func refreshProposalBanner() {
        let proposing = aiAssistableFields.filter { $0.1.isShowingProposal }
        let count = proposing.count
        proposalBanner.isHidden = count == 0
        let label = count == 1 ? "1 field proposed" : "\(count) fields proposed"
        proposalBannerLabel.stringValue = label
    }

    private func addTab(_ vc: NSViewController, label: String) {
        let item = NSTabViewItem(viewController: vc)
        item.label = label
        tabView.addTabViewItem(item)
    }

    private func addPlaceholderTab(label: String, body: String) {
        let vc = PlaceholderTabViewController(message: body)
        addTab(vc, label: label)
    }

    // MARK: - Footer

    private func buildFooter(in root: NSView) {
        cancelButton.bezelStyle = .rounded
        cancelButton.controlSize = .regular
        cancelButton.target = self
        cancelButton.action = #selector(cancelClicked)
        cancelButton.keyEquivalent = "\u{1B}" // Esc
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .regular
        saveButton.target = self
        saveButton.action = #selector(saveClicked)
        saveButton.keyEquivalent = "\r"
        saveButton.keyEquivalentModifierMask = [.command]
        saveButton.translatesAutoresizingMaskIntoConstraints = false

        dirtyDot.font = DesignTokens.Typography.body
        dirtyDot.textColor = DesignTokens.Foreground.accent
        dirtyDot.translatesAutoresizingMaskIntoConstraints = false
        dirtyDot.toolTip = "You have unsaved changes."

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(separator)

        let footer = NSStackView(views: [cancelButton, NSView(), dirtyDot, saveButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = DesignTokens.Spacing.sm
        footer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -DesignTokens.Spacing.md),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: DesignTokens.Spacing.lg),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -DesignTokens.Spacing.lg),

            separator.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -DesignTokens.Spacing.md),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            tabView.bottomAnchor.constraint(equalTo: separator.topAnchor, constant: -DesignTokens.Spacing.md),
        ])
    }

    // MARK: - Actions

    @objc private func saveClicked() {
        // Pre-flush hook for tabs that hold UI-only state to be
        // committed alongside the character. Today: Identity's
        // pending-novel-tag opt-ins.
        identityTab.commitPendingTagPromotions()

        // Route through AppStateCardStorage (not Storage.shared directly) so
        // AppState.saveCharacter updates the in-memory cache + posts
        // charactersChanged. Library refresh depends on the cache update.
        let id = draft.flush(storage: AppStateCardStorage())
        DebugLog.shared.write("cardcreator: save \(id) name=\(draft.character.name)")
        onSave?(id)
    }

    @objc private func cancelClicked() {
        onCancel?()
    }

    func handleDirtyChanged() {
        refreshDirtyDot()
        onDirtyChanged?()
    }

    private func refreshDirtyDot() {
        dirtyDot.isHidden = !draft.isDirty
    }

    // MARK: - Tab navigation shortcuts (Cmd-1 ... Cmd-7)

    func selectTab(at index: Int) {
        guard index >= 0, index < tabView.numberOfTabViewItems else { return }
        DebugLog.shared.write("cardcreator: selectTab \(index) (cmd-shortcut)")
        tabView.selectTabViewItem(at: index)
    }

    // MARK: - Drag-drop handling (§5.3d.2)

    /// Called when a `.png` / `.json` card file is dropped on the creator
    /// window. Routes through `AppDelegate.importAndEditCard(from:)` so
    /// the same path covers File-menu picker, Library-window drop, and
    /// creator-window drop. The §3.1 in-place "Replace / Keep / Cancel"
    /// for dirty drafts is a §5.3 deferred polish — for now every drop
    /// spawns a new creator window and the original draft is preserved.
    private func handleDroppedCardFile(_ url: URL) {
        DebugLog.shared.write("cardcreator: drag-drop \(url.lastPathComponent)")
        (NSApp.delegate as? AppDelegate)?.importAndEditCard(from: url)
    }
}

extension CardCreatorViewController: NSTabViewDelegate {
    func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        DebugLog.shared.write("cardcreator: tabView didSelect \(tabViewItem?.label ?? "nil")")
    }
    func tabView(_ tabView: NSTabView, willSelect tabViewItem: NSTabViewItem?) {
        DebugLog.shared.write("cardcreator: tabView willSelect \(tabViewItem?.label ?? "nil")")
    }
    func tabView(_ tabView: NSTabView, shouldSelect tabViewItem: NSTabViewItem?) -> Bool {
        DebugLog.shared.write("cardcreator: tabView shouldSelect? \(tabViewItem?.label ?? "nil")")
        return true
    }
}

// MARK: - Placeholder tab content (§5.3b/c will replace)

private final class PlaceholderTabViewController: NSViewController {
    private let message: String

    init(message: String) {
        self.message = message
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        let label = NSTextField(labelWithString: message)
        label.font = DesignTokens.Typography.callout
        label.textColor = DesignTokens.Foreground.tertiary
        label.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: v.centerYAnchor),
        ])
        self.view = v
    }
}
