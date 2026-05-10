import AppKit

// Phase 10 §10.b — settings UI for the per-EXACT-model
// `ModelCapabilities` store. One window, separate from the main
// `SettingsWindowController` (per the user's "should be a separate
// menu/settings page" — model-specific overrides are a distinct
// concern from app-wide settings).
//
// Layout: vertical scrollable list, one section per known record
// (loaded from `ModelCapabilitiesStore.listAll()`). Each section has
// inline form controls for every `ChatPathOverrides` field plus
// per-section Save and Delete buttons. A trailing "+ Add new model"
// form lets the user pre-encode a record for a model they haven't
// loaded yet (useful for ahead-of-swap preparation).
//
// Per-EXACT-model invariant (V2_PHASE10_SMOKE_HARNESS_RUNBOOK.md):
// every Save / Delete operates on EXACTLY ONE record. The window
// never mutates more than one model's record per user action; there
// is no global "Save All" because there's no shared state across
// models.
final class ModelCapabilitiesWindowController: NSWindowController, NSWindowDelegate {

    private var records: [ModelCapabilities] = []
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    /// Per-section editor state, keyed by model name. Each editor
    /// owns the controls for one record + the Save/Delete handlers.
    private var editors: [String: ModelCapabilityEditor] = [:]
    /// The "+ Add new model" form controls (separate because the
    /// model name doesn't exist yet).
    private let newModelField = NSTextField()
    private let addButton = NSButton(title: "Add", target: nil, action: nil)
    private let refreshButton = NSButton(title: "Reload from disk", target: nil, action: nil)

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1100, height: 680),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // Wider min so at least two cards fit side by side without
        // the user having to drag-resize on first open.
        w.minSize = NSSize(width: 720, height: 520)
        w.title = "Model Capabilities"
        self.init(window: w)
        w.delegate = self
        buildUI()
        reload()
    }

    override func showWindow(_ sender: Any?) {
        // Always re-pull on open — the user may have edited records
        // out-of-band via `swift run ModelCapsAdmin` or by loading a
        // new model that triggered an automatic record (when §10.a's
        // probe runner lands).
        reload()
        super.showWindow(sender)
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Header explaining the per-EXACT-model invariant up-front so
        // the user doesn't expect a "share fix across variants" button
        // that doesn't exist.
        let header = NSTextField(labelWithString: "Per-model overrides")
        header.font = Theme.bold(13)
        let helpText = NSTextField(wrappingLabelWithString:
            "One record per EXACT model name (whatever `/api/v1/model` returns). " +
            "Different fine-tunes / quants of the same family — Qwen3.6-Q4 vs Qwen3.6-Q5 — " +
            "stay isolated; a fix for one variant never inherits to another. " +
            "Each Save / Delete touches exactly one record.")
        helpText.font = Theme.font(10)
        helpText.textColor = .secondaryLabelColor

        // Horizontal layout: cards side-by-side, one fixed-width
        // card per record. Horizontal scroll for browsing many
        // models; vertical scroll falls back to per-card content
        // expansion (currently each card sizes to fit, not scrolled
        // internally). The bottom "Add new model" form is pinned
        // BELOW the scroll so it's always reachable regardless of
        // how far right the user has scrolled.
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        // Per-axis flex: horizontal scroll bar is the primary
        // navigation; vertical exists for the (rare) case where
        // notes / observations push a card past viewport height.
        scroll.autohidesScrollers = false
        scroll.borderType = .bezelBorder
        scroll.drawsBackground = true
        scroll.backgroundColor = .windowBackgroundColor
        scroll.documentView = stack

        refreshButton.bezelStyle = .rounded
        refreshButton.target = self
        refreshButton.action = #selector(reload)
        refreshButton.translatesAutoresizingMaskIntoConstraints = false

        let topBar = NSStackView(views: [header, NSView(), refreshButton])
        topBar.orientation = .horizontal
        topBar.alignment = .centerY
        topBar.spacing = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false

        helpText.translatesAutoresizingMaskIntoConstraints = false

        // Bottom-pinned "Add new model" form — separate from the
        // horizontal-scrolling card list so the user can add a
        // record without scrolling all the way right.
        let addFormContainer = makeAddBox()

        cv.addSubview(topBar)
        cv.addSubview(helpText)
        cv.addSubview(scroll)
        cv.addSubview(addFormContainer)

        NSLayoutConstraint.activate([
            topBar.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            topBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            topBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            helpText.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 4),
            helpText.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            helpText.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scroll.topAnchor.constraint(equalTo: helpText.bottomAnchor, constant: 8),
            scroll.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            scroll.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            scroll.bottomAnchor.constraint(equalTo: addFormContainer.topAnchor, constant: -10),
            addFormContainer.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            addFormContainer.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),
            addFormContainer.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
        ])

        // NSScrollView with an NSStackView documentView: pin the
        // stack to the scroll's contentView so the document
        // geometry is known. For HORIZONTAL scrolling we pin
        // height (vertical fits viewport) and let width grow with
        // arranged subviews. Cards extend past the right edge as
        // they're added; the horizontal scroller exposes them.
        let docContent = scroll.contentView
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: docContent.topAnchor),
            stack.leadingAnchor.constraint(equalTo: docContent.leadingAnchor),
            stack.bottomAnchor.constraint(equalTo: docContent.bottomAnchor),
            stack.heightAnchor.constraint(equalTo: docContent.heightAnchor),
        ])
    }

    /// Fixed width per record card. Wide enough that the form rows
    /// (140pt label column + popups / fields) fit comfortably; narrow
    /// enough that 2-3 cards visible at default window width.
    static let cardWidth: CGFloat = 420

    @objc private func reload() {
        // Preserve scroll position across rebuilds so a Save on
        // record #7 doesn't bounce the user back to the start. With
        // horizontal layout the relevant axis is x; clamp to the new
        // content's max-x so a delete that shortened the row doesn't
        // try to over-scroll.
        let priorOrigin = scroll.documentVisibleRect.origin
        records = (try? ModelCapabilitiesStore.listAll())?
            .sorted(by: { $0.modelName < $1.modelName }) ?? []
        rebuildStack()
        DispatchQueue.main.async { [weak self] in
            guard let self = self,
                  let docView = self.scroll.documentView else { return }
            let viewport = self.scroll.contentView.bounds.size
            let maxX = max(0, docView.frame.width - viewport.width)
            let maxY = max(0, docView.frame.height - viewport.height)
            let clamped = NSPoint(x: min(priorOrigin.x, maxX),
                                  y: min(priorOrigin.y, maxY))
            docView.scroll(clamped)
        }
    }

    private func rebuildStack() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        editors.removeAll()

        if records.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "No model records yet. Add one in the form below, or run `swift run ModelCapsAdmin set <model-name> ...` (or, when §10.a's probe runner lands, just load a new model and the probe will create a record automatically).")
            empty.font = Theme.font(11)
            empty.textColor = .secondaryLabelColor
            empty.lineBreakMode = .byWordWrapping
            empty.maximumNumberOfLines = 0
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalToConstant: 480).isActive = true
        } else {
            for record in records {
                let editor = ModelCapabilityEditor(record: record, owner: self)
                editors[record.modelName] = editor
                stack.addArrangedSubview(editor.box)
                // Each card is fixed-width (Self.cardWidth) so the
                // horizontal stack lays them out side-by-side. Card
                // height is intrinsic — the tallest card determines
                // the row height; shorter cards get top-aligned
                // whitespace (stack.alignment = .top).
                editor.box.widthAnchor.constraint(equalToConstant: Self.cardWidth).isActive = true
            }
        }
    }

    private func makeAddBox() -> NSView {
        // Custom NSView (not NSBox) with a layer-drawn border —
        // NSBox's interaction with NSStackView turned out to be the
        // root cause of both the missing borders on the per-record
        // sections and the y-overlap with the next section. A plain
        // NSView whose layer carries the cornerRadius + border
        // sidesteps the whole NSBox layout machinery.
        let made = ModelCapabilitiesWindowController.makeSectionContainer(title: "Add a new model record")
        let container = made.container
        let inner = made.innerStack

        let label = NSTextField(labelWithString: "Exact model name (e.g. `koboldcpp/Qwen3.6-…-Q5_K_M`):")
        label.lineBreakMode = .byWordWrapping
        label.maximumNumberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false

        newModelField.placeholderString = "model name from /api/v1/model"
        newModelField.translatesAutoresizingMaskIntoConstraints = false
        newModelField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        newModelField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addNewModel)
        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.setContentHuggingPriority(.defaultHigh, for: .horizontal)

        let row = NSStackView(views: [newModelField, addButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.distribution = .fill
        row.translatesAutoresizingMaskIntoConstraints = false

        let helpRow = NSTextField(wrappingLabelWithString:
            "Creates an EMPTY record (all overrides nil = global defaults). " +
            "Edit the fields in the new section that appears, then click Save. " +
            "Useful for pre-encoding a fix you've validated against a quant you're about to load.")
        helpRow.font = Theme.font(10)
        helpRow.textColor = .secondaryLabelColor
        helpRow.lineBreakMode = .byWordWrapping
        helpRow.maximumNumberOfLines = 0
        helpRow.translatesAutoresizingMaskIntoConstraints = false

        for v in [label as NSView, row, helpRow] {
            inner.addArrangedSubview(v)
            v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        return container
    }

    /// Build a layer-drawn rounded "card" container with an internal
    /// vertical NSStackView pinned to its 4 edges. Returns both so
    /// the caller can populate the stack and have the container size
    /// itself to the stack's intrinsic height. Replaces NSBox at
    /// every section site — NSBox + NSStackView arrangement was the
    /// root cause of the screenshot's empty-top-half + sections-
    /// overlapping-each-other layout pathology.
    static func makeSectionContainer(title: String?) -> (container: NSView, innerStack: NSStackView) {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        container.layer?.cornerRadius = 6
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.cgColor

        let inner = NSStackView()
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 8
        inner.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(inner)

        let topInset: CGFloat = title == nil ? 12 : 32
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: container.topAnchor, constant: topInset),
            inner.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            inner.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            inner.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -14),
        ])

        if let title {
            let titleLabel = NSTextField(labelWithString: title)
            titleLabel.font = Theme.bold(12)
            titleLabel.translatesAutoresizingMaskIntoConstraints = false
            container.addSubview(titleLabel)
            NSLayoutConstraint.activate([
                titleLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
                titleLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
                titleLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14),
            ])
        }
        return (container, inner)
    }

    @objc private func addNewModel() {
        let name = newModelField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // No-op if the record already exists (the editor for it is
        // already in the stack); switching to it would be a polish
        // for a future revision.
        if records.contains(where: { $0.modelName == name }) {
            NSSound.beep()
            return
        }
        let fresh = ModelCapabilities(
            modelName: name,
            recordedAt: Date(),
            schemaVersion: ModelCapabilities.currentSchemaVersion,
            notes: nil,
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
        do {
            _ = try ModelCapabilitiesStore.save(fresh)
            newModelField.stringValue = ""
            reload()
        } catch {
            presentError("Couldn't save: \(error)")
        }
    }

    /// Per-record Save handler invoked by `ModelCapabilityEditor`.
    /// Operates on EXACTLY ONE record — never touches sibling
    /// records on disk.
    fileprivate func saveRecord(_ caps: ModelCapabilities) {
        do {
            _ = try ModelCapabilitiesStore.save(caps)
            reload()
        } catch {
            presentError("Save failed for \(caps.modelName): \(error)")
        }
    }

    /// Per-record Delete handler. Confirms first; only the named
    /// record's file is removed from disk.
    fileprivate func deleteRecord(named modelName: String) {
        let alert = NSAlert()
        alert.messageText = "Delete capability record for \(modelName)?"
        alert.informativeText = "Other models' records are unaffected. The chat path will fall back to global defaults for this model until you re-encode overrides."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            do {
                try ModelCapabilitiesStore.delete(modelName: modelName)
                reload()
            } catch {
                presentError("Delete failed: \(error)")
            }
        }
    }

    private func presentError(_ msg: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't write to model_capabilities directory"
        alert.informativeText = msg
        alert.alertStyle = .warning
        alert.runModal()
    }

    func windowWillClose(_ notification: Notification) {
        // Note: per-section edits are NOT auto-saved on close. The
        // user must hit each section's Save button explicitly. This
        // matches the per-EXACT-model invariant — auto-save would
        // mean one window-close potentially writes every record at
        // once, which makes the "exactly one record per action"
        // promise harder to reason about.
    }
}

// MARK: - Per-record editor

/// Owns the controls for one section. The window controller stitches
/// these together; the editor exposes a `.box` view (the layer-drawn
/// container) + Save/Delete callbacks. Holds a copy of the
/// `ModelCapabilities` it was seeded from; user edits update the
/// in-memory copy until Save commits to disk.
private final class ModelCapabilityEditor: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let box: NSView
    private let inner: NSStackView
    private let owner: ModelCapabilitiesWindowController
    private var record: ModelCapabilities

    private let recordedLabel = NSTextField(labelWithString: "")
    private let notesView = NSTextView()
    private let notesScroll = NSScrollView()

    private let thinkingPopup = NSPopUpButton()
    private let samplerPopup = NSPopUpButton()
    private let stopAugmentField = NSTextField()
    private let groupNudgePopup = NSPopUpButton()
    private let maxCtxCapField = NSTextField()
    private let refusalPopup = NSPopUpButton()

    private let detectedLabel = NSTextField(labelWithString: "")
    private let observationsLabel = NSTextField(labelWithString: "")

    private let saveButton = NSButton(title: "Save changes", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete record", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal in Finder", target: nil, action: nil)

    init(record: ModelCapabilities, owner: ModelCapabilitiesWindowController) {
        self.record = record
        self.owner = owner
        // Section title is the model name itself — rendered as a
        // proper title-bar label inside the rounded card. The cap
        // letter-glyph is a monospaced font for readability of long
        // exact model names; truncation is byTruncatingMiddle so
        // the meaningful suffix (the quant tag) stays visible.
        let made = ModelCapabilitiesWindowController.makeSectionContainer(title: nil)
        self.box = made.container
        self.inner = made.innerStack
        super.init()
        buildUI()
        loadRecord()
    }

    private func buildUI() {
        let titleLabel = NSTextField(labelWithString: record.modelName)
        titleLabel.font = .monospacedSystemFont(ofSize: 12, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.maximumNumberOfLines = 1
        titleLabel.toolTip = record.modelName
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        recordedLabel.font = Theme.font(10)
        recordedLabel.textColor = .secondaryLabelColor

        // Notes (multi-line, free text)
        notesScroll.borderType = .bezelBorder
        notesScroll.hasVerticalScroller = true
        notesView.isRichText = false
        notesView.font = Theme.font(11)
        notesView.isAutomaticQuoteSubstitutionEnabled = false
        notesView.isAutomaticDashSubstitutionEnabled = false
        notesView.delegate = self
        notesView.minSize = NSSize(width: 0, height: 60)
        notesView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        notesView.isVerticallyResizable = true
        notesView.isHorizontallyResizable = false
        notesView.autoresizingMask = [.width]
        notesView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        notesView.textContainer?.widthTracksTextView = true
        notesScroll.documentView = notesView
        notesScroll.translatesAutoresizingMaskIntoConstraints = false

        thinkingPopup.addItem(withTitle: "(use global default)")
        thinkingPopup.addItems(withTitles: ["needed", "harmless", "unknown"])
        thinkingPopup.translatesAutoresizingMaskIntoConstraints = false

        samplerPopup.addItem(withTitle: "(use global default)")
        samplerPopup.addItems(withTitles: SamplerPreset.presets.map(\.id))
        samplerPopup.translatesAutoresizingMaskIntoConstraints = false

        stopAugmentField.placeholderString = "comma-separated, use \\n for newline (e.g. `\\nMira:,\\nSarah:`)"
        stopAugmentField.translatesAutoresizingMaskIntoConstraints = false
        stopAugmentField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stopAugmentField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        groupNudgePopup.addItem(withTitle: "(use global default)")
        groupNudgePopup.addItems(withTitles: ["standard", "strong", "continuing", "stop-augment", "strong-stop"])
        groupNudgePopup.translatesAutoresizingMaskIntoConstraints = false

        maxCtxCapField.placeholderString = "(no cap)"
        maxCtxCapField.translatesAutoresizingMaskIntoConstraints = false

        refusalPopup.addItem(withTitle: "(use global default)")
        refusalPopup.addItems(withTitles: ["permissive", "aligned", "unknown"])
        refusalPopup.translatesAutoresizingMaskIntoConstraints = false

        detectedLabel.font = Theme.font(10)
        detectedLabel.textColor = .secondaryLabelColor
        detectedLabel.lineBreakMode = .byWordWrapping
        detectedLabel.maximumNumberOfLines = 0

        observationsLabel.font = Theme.font(10)
        observationsLabel.textColor = .secondaryLabelColor
        observationsLabel.lineBreakMode = .byWordWrapping
        observationsLabel.maximumNumberOfLines = 0

        // Action buttons. `.required` compression resistance + hugging
        // so they NEVER shrink below intrinsic width — the screenshot
        // showed Save truncated to ":h" because the row was narrow
        // and the spacer was winning the fill battle.
        for b in [saveButton, deleteButton, revealButton] {
            b.bezelStyle = .rounded
            b.translatesAutoresizingMaskIntoConstraints = false
            b.setContentCompressionResistancePriority(.required, for: .horizontal)
            b.setContentHuggingPriority(.required, for: .horizontal)
        }
        // NOTE: do NOT set keyEquivalent = "\r" on multiple Save
        // buttons — AppKit only allows one default button per window
        // and the conflict ends up rendering all of them as a tiny
        // blue default-decoration with no visible title (the "ai"
        // glyph the screenshot showed).
        saveButton.title = "Save"
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.contentTintColor = .systemRed
        revealButton.target = self
        revealButton.action = #selector(handleReveal)

        let buttonSpacer = NSView()
        buttonSpacer.translatesAutoresizingMaskIntoConstraints = false
        // Spacer absorbs ALL slack so the buttons stay at intrinsic
        // width on either side. Below-default hugging + below-default
        // compression resistance is the canonical "stretchy filler"
        // recipe.
        buttonSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        buttonSpacer.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        let buttons = NSStackView(views: [saveButton, deleteButton, buttonSpacer, revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fill
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // Form rows. Each row is `<label> <control>` in a horizontal
        // stack with the label width pinned and the control growing
        // to fill remaining space. `distribution = .fill` (default)
        // honours hugging/compression-resistance to allocate the
        // residual width to the control.
        func row(_ labelText: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: labelText)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 140).isActive = true
            l.alignment = .right
            l.setContentHuggingPriority(.required, for: .horizontal)
            l.setContentCompressionResistancePriority(.required, for: .horizontal)
            let r = NSStackView(views: [l, control])
            r.orientation = .horizontal
            r.alignment = .firstBaseline
            r.distribution = .fill
            r.spacing = 8
            r.translatesAutoresizingMaskIntoConstraints = false
            return r
        }

        let notesRow = row("Notes:", notesScroll)
        let thinkingRow = row("Thinking-prefill:", thinkingPopup)
        let samplerRow = row("Sampler:", samplerPopup)
        let stopRow = row("Stop-augment:", stopAugmentField)
        let nudgeRow = row("Group-nudge:", groupNudgePopup)
        let ctxRow = row("Max-ctx cap:", maxCtxCapField)
        let refusalRow = row("Refusal-posture:", refusalPopup)

        let allRows: [NSView] = [
            titleLabel, recordedLabel, notesRow, thinkingRow, samplerRow,
            stopRow, nudgeRow, ctxRow, refusalRow,
            detectedLabel, observationsLabel, buttons,
        ]
        for v in allRows {
            inner.addArrangedSubview(v)
            // Pin each row to the inner stack's full width so the
            // controls actually expand into the available area
            // instead of clinging to intrinsic width (which gave the
            // squashed-narrow-column look in the screenshot).
            v.widthAnchor.constraint(equalTo: inner.widthAnchor).isActive = true
        }
        // Notes gets more breathing room with the horizontal layout —
        // each card is a column, vertical space is no longer at a
        // premium.
        notesScroll.heightAnchor.constraint(equalToConstant: 100).isActive = true
        maxCtxCapField.widthAnchor.constraint(equalToConstant: 120).isActive = true
    }

    private func loadRecord() {
        let df = ISO8601DateFormatter()
        recordedLabel.stringValue = "Recorded \(df.string(from: record.recordedAt))   schema v\(record.schemaVersion)"
        notesView.string = record.notes ?? ""
        thinkingPopup.selectItem(withTitle: record.overrides.thinkingPrefill?.rawValue ?? "(use global default)")
        samplerPopup.selectItem(withTitle: record.overrides.recommendedSamplerId ?? "(use global default)")
        stopAugmentField.stringValue = (record.overrides.stopSequenceAugmentation ?? [])
            .map { $0.replacingOccurrences(of: "\n", with: "\\n") }
            .joined(separator: ",")
        groupNudgePopup.selectItem(withTitle: record.overrides.groupNudgeStyle?.rawValue ?? "(use global default)")
        maxCtxCapField.stringValue = record.overrides.maxCtxCap.map { String($0) } ?? ""
        refusalPopup.selectItem(withTitle: record.overrides.refusalPostureOverride?.rawValue ?? "(use global default)")

        // Detected facts — read-only display (probe runner writes
        // these; UI should never edit). When empty, hide the section.
        var detLines: [String] = []
        if let v = record.detected.modelFamilyHint { detLines.append("modelFamilyHint=\(v)") }
        if let v = record.detected.maxCtx { detLines.append("maxCtx=\(v)") }
        if let v = record.detected.supportsJsonSchema { detLines.append("supportsJsonSchema=\(v)") }
        if let v = record.detected.supportsEmbeddings { detLines.append("supportsEmbeddings=\(v)") }
        if let v = record.detected.koboldVersion { detLines.append("koboldVersion=\(v)") }
        detectedLabel.stringValue = detLines.isEmpty
            ? "Detected facts: (none recorded yet — runs once §10.a's probe runner lands)"
            : "Detected facts: \(detLines.joined(separator: "  "))"

        // Companion observation log, if one exists for this model.
        // Inline the lookup rather than depending on
        // SmokeFixtures.ModelObservationStore — that target lives at
        // a layer above RPClientCore (smokes depend on us, not the
        // other way around). We need the file path + a count, both
        // cheap to compute from the same sanitisation rule
        // ModelCapabilitiesStore uses.
        let obsURL = Self.observationLogURL(forModelName: record.modelName)
        if let count = Self.countObservations(at: obsURL),
           let runCount = Self.countRuns(at: obsURL) {
            observationsLabel.stringValue = "Observations: \(count) recorded over \(runCount) smoke runs"
                + " (see \(obsURL.lastPathComponent))"
        } else {
            observationsLabel.stringValue = "Observations: none yet (run `swift run SmokeAll` to populate)"
        }
    }

    /// Path to this model's smoke-observations file, computed using
    /// the same sanitisation rule as `ModelCapabilitiesStore`.
    /// `~/Library/Application Support/RPClient/smoke-observations/<sanitised>.json`.
    static func observationLogURL(forModelName name: String) -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("smoke-observations", isDirectory: true)
            .appendingPathComponent("\(ModelCapabilitiesStore.sanitize(modelName: name)).json")
    }

    static func countObservations(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["observations"] as? [Any]
        else { return nil }
        return arr.count
    }

    static func countRuns(at url: URL) -> Int? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let n = obj["runCount"] as? Int
        else { return nil }
        return n
    }

    @objc private func handleSave() {
        // Read the form back into a fresh ChatPathOverrides. Each
        // popup's first item ("(use global default)") maps to nil so
        // a partial override doesn't accidentally write meaningful
        // values for fields the user didn't touch.
        var o = ChatPathOverrides()
        if let title = thinkingPopup.titleOfSelectedItem,
           let v = ThinkingPrefill(rawValue: title) {
            o.thinkingPrefill = v
        }
        if let title = samplerPopup.titleOfSelectedItem,
           SamplerPreset.presets.contains(where: { $0.id == title }) {
            o.recommendedSamplerId = title
        }
        let stopText = stopAugmentField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if !stopText.isEmpty {
            o.stopSequenceAugmentation = stopText
                .split(separator: ",")
                .map { String($0).replacingOccurrences(of: "\\n", with: "\n") }
                .filter { !$0.isEmpty }
        }
        if let title = groupNudgePopup.titleOfSelectedItem,
           let v = GroupNudgeStyle(rawValue: title) {
            o.groupNudgeStyle = v
        }
        if let n = Int(maxCtxCapField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)), n > 0 {
            o.maxCtxCap = n
        }
        if let title = refusalPopup.titleOfSelectedItem,
           let v = RefusalPosture(rawValue: title) {
            o.refusalPostureOverride = v
        }

        let trimmedNotes = notesView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        record.notes = trimmedNotes.isEmpty ? nil : trimmedNotes
        record.overrides = o
        owner.saveRecord(record)
    }

    @objc private func handleDelete() {
        owner.deleteRecord(named: record.modelName)
    }

    @objc private func handleReveal() {
        let url = ModelCapabilitiesStore.reportPath(forModelName: record.modelName)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            // Hasn't been saved yet — open the parent directory instead.
            NSWorkspace.shared.open(ModelCapabilitiesStore.directory())
        }
    }
}
