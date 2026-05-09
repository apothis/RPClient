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
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 640, height: 420)
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

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 18
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
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
        cv.addSubview(topBar)
        cv.addSubview(helpText)
        cv.addSubview(scroll)

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
            scroll.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -12),
            // Stack width tracks scroll view's content area so the
            // wrap labels reflow properly when the window resizes.
            stack.widthAnchor.constraint(equalTo: scroll.widthAnchor, constant: -8),
        ])
    }

    @objc private func reload() {
        records = (try? ModelCapabilitiesStore.listAll())?
            .sorted(by: { $0.modelName < $1.modelName }) ?? []
        rebuildStack()
    }

    private func rebuildStack() {
        for v in stack.arrangedSubviews {
            stack.removeArrangedSubview(v)
            v.removeFromSuperview()
        }
        editors.removeAll()

        if records.isEmpty {
            let empty = NSTextField(wrappingLabelWithString:
                "No model records yet. Add one below or run `swift run ModelCapsAdmin set <model-name> ...` (or, when §10.a's probe runner lands, just load a new model and the probe will create a record automatically).")
            empty.font = Theme.font(11)
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
        } else {
            for record in records {
                let editor = ModelCapabilityEditor(record: record, owner: self)
                editors[record.modelName] = editor
                stack.addArrangedSubview(editor.box)
            }
        }

        // Trailing "+ Add new model" form — even when records is non-empty.
        let addBox = makeAddBox()
        stack.addArrangedSubview(addBox)
    }

    private func makeAddBox() -> NSView {
        let box = NSBox()
        box.title = "Add a new model record"
        box.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "Exact model name (e.g. `koboldcpp/Qwen3.6-…-Q5_K_M`):")
        newModelField.placeholderString = "model name from /api/v1/model"
        newModelField.translatesAutoresizingMaskIntoConstraints = false

        addButton.bezelStyle = .rounded
        addButton.target = self
        addButton.action = #selector(addNewModel)
        addButton.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView(views: [newModelField, addButton])
        row.orientation = .horizontal
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let helpRow = NSTextField(wrappingLabelWithString:
            "Creates an EMPTY record (all overrides nil = global defaults). " +
            "Edit the fields in the new section that appears, then click Save. " +
            "Useful for pre-encoding a fix you've validated against a quant you're about to load.")
        helpRow.font = Theme.font(10)
        helpRow.textColor = .secondaryLabelColor
        helpRow.translatesAutoresizingMaskIntoConstraints = false

        let inner = NSStackView(views: [label, row, helpRow])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)

        box.contentView = inner
        NSLayoutConstraint.activate([
            newModelField.widthAnchor.constraint(greaterThanOrEqualToConstant: 380),
            inner.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -16),
        ])
        return box
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
/// these together; the editor exposes a `.box` view + Save/Delete
/// callbacks. Holds a copy of the `ModelCapabilities` it was seeded
/// from; user edits update the in-memory copy until Save commits to
/// disk.
private final class ModelCapabilityEditor: NSObject, NSTextFieldDelegate, NSTextViewDelegate {
    let box: NSBox
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
        self.box = NSBox()
        super.init()
        buildUI()
        loadRecord()
    }

    private func buildUI() {
        box.title = record.modelName
        box.translatesAutoresizingMaskIntoConstraints = false

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

        // Thinking-prefill popup. Item titles match the rawValue strings
        // (so Save reads them back via ThinkingPrefill(rawValue:)).
        thinkingPopup.addItem(withTitle: "(use global default)")
        thinkingPopup.addItems(withTitles: ["needed", "harmless", "unknown"])
        thinkingPopup.translatesAutoresizingMaskIntoConstraints = false

        // Sampler popup. Items match SamplerPreset.presets ids.
        samplerPopup.addItem(withTitle: "(use global default)")
        samplerPopup.addItems(withTitles: SamplerPreset.presets.map(\.id))
        samplerPopup.translatesAutoresizingMaskIntoConstraints = false

        stopAugmentField.placeholderString = "comma-separated, use \\n for newline (e.g. `\\nMira:,\\nSarah:`)"
        stopAugmentField.translatesAutoresizingMaskIntoConstraints = false

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

        observationsLabel.font = Theme.font(10)
        observationsLabel.textColor = .secondaryLabelColor

        saveButton.bezelStyle = .rounded
        saveButton.target = self
        saveButton.action = #selector(handleSave)
        saveButton.keyEquivalent = ""

        deleteButton.bezelStyle = .rounded
        deleteButton.target = self
        deleteButton.action = #selector(handleDelete)
        deleteButton.contentTintColor = .systemRed

        revealButton.bezelStyle = .rounded
        revealButton.target = self
        revealButton.action = #selector(handleReveal)

        let buttons = NSStackView(views: [saveButton, deleteButton, NSView(), revealButton])
        buttons.orientation = .horizontal
        buttons.spacing = 8
        buttons.translatesAutoresizingMaskIntoConstraints = false

        // Form rows. Each row is `<label> <control>` glued in a
        // horizontal stack with the label width pinned so columns
        // line up across rows.
        func row(_ labelText: String, _ control: NSView) -> NSStackView {
            let l = NSTextField(labelWithString: labelText)
            l.translatesAutoresizingMaskIntoConstraints = false
            l.widthAnchor.constraint(equalToConstant: 160).isActive = true
            l.alignment = .right
            let r = NSStackView(views: [l, control])
            r.orientation = .horizontal
            r.alignment = .firstBaseline
            r.spacing = 8
            r.translatesAutoresizingMaskIntoConstraints = false
            return r
        }

        let inner = NSStackView(views: [
            recordedLabel,
            row("Notes:", notesScroll),
            row("Thinking-prefill:", thinkingPopup),
            row("Sampler:", samplerPopup),
            row("Stop-augment:", stopAugmentField),
            row("Group-nudge:", groupNudgePopup),
            row("Max-ctx cap:", maxCtxCapField),
            row("Refusal-posture:", refusalPopup),
            detectedLabel,
            observationsLabel,
            buttons,
        ])
        inner.orientation = .vertical
        inner.alignment = .leading
        inner.spacing = 6
        inner.translatesAutoresizingMaskIntoConstraints = false
        inner.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 8, right: 8)

        box.contentView = inner
        NSLayoutConstraint.activate([
            inner.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -16),
            notesScroll.heightAnchor.constraint(equalToConstant: 60),
            notesScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            stopAugmentField.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),
            maxCtxCapField.widthAnchor.constraint(equalToConstant: 100),
        ])
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
