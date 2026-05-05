import AppKit

/// Voice library window — Phase 6 §7.1h1 (read-only catalogue + state badges).
/// Lists every voice in `KokoroVoiceCatalogue.all` with filter chips for
/// language and gender. The base-model row sits above the table so users see
/// the umbrella state (model present? voice present?) at a glance.
///
/// Action buttons (Download / Remove / Preview) are deferred to §7.1h2 once
/// the download manager (§7.1j) is real — until then this window is purely
/// informational. State badges already reflect on-disk truth via
/// `KokoroModelStore`.
final class VoiceLibraryWindowController: NSWindowController, NSWindowDelegate {

    private let banner = NSTextField(wrappingLabelWithString: "")
    private let espeakStatusLabel = NSTextField(wrappingLabelWithString: "")
    private let espeakInstallRow = NSStackView()
    private let espeakCommandLabel = NSTextField(labelWithString: "brew install espeak-ng")
    private let espeakCopyButton = NSButton(title: "Copy", target: nil, action: nil)
    private let espeakRecheckButton = NSButton(title: "Re-check", target: nil, action: nil)
    private let baseModelLabel = NSTextField(labelWithString: "")
    private let baseModelButton = NSButton(title: "Download", target: nil, action: nil)
    private let languagePopup = NSPopUpButton()
    private let genderPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")

    private var rows: [KokoroVoice] = []
    private var settingsObserver: NSObjectProtocol?
    private var downloadObserver: NSObjectProtocol?

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        // 660 covers the 5 columns at minWidth (180+140+70+110+90 = 590) +
        // intercell spacing + scrollbar + 32 side padding. Below that the
        // Action column eats into State.
        w.minSize = NSSize(width: 660, height: 360)
        w.title = "Voice library"
        // Autosave key bumped (.v2) so any too-narrow frame saved during
        // h1/h2 development gets invalidated and the new default applies.
        w.setFrameAutosaveName("RPClient.VoiceLibraryWindow.v2")
        self.init(window: w)
        w.delegate = self
        buildUI()
        rebuild()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppNotification.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
        downloadObserver = NotificationCenter.default.addObserver(
            forName: AppNotification.kokoroDownloadStateChanged,
            object: nil, queue: .main
        ) { [weak self] note in
            guard let id = note.userInfo?["id"] as? String else { return }
            self?.handleDownloadStateChanged(id: id)
        }
    }

    deinit {
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
        if let o = downloadObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        banner.font = Theme.font(11)
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false

        espeakStatusLabel.font = Theme.font(12)
        espeakStatusLabel.translatesAutoresizingMaskIntoConstraints = false
        espeakCommandLabel.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        espeakCommandLabel.textColor = .labelColor
        espeakCommandLabel.isSelectable = true
        espeakCopyButton.bezelStyle = .rounded
        espeakCopyButton.target = self
        espeakCopyButton.action = #selector(espeakCopyCommand)
        espeakRecheckButton.bezelStyle = .rounded
        espeakRecheckButton.target = self
        espeakRecheckButton.action = #selector(espeakRecheck)
        espeakInstallRow.orientation = .horizontal
        espeakInstallRow.alignment = .centerY
        espeakInstallRow.spacing = 8
        espeakInstallRow.translatesAutoresizingMaskIntoConstraints = false
        espeakInstallRow.addArrangedSubview(espeakCommandLabel)
        espeakInstallRow.addArrangedSubview(espeakCopyButton)
        espeakInstallRow.addArrangedSubview(espeakRecheckButton)

        let espeakSection = NSStackView(views: [espeakStatusLabel, espeakInstallRow])
        espeakSection.orientation = .vertical
        espeakSection.alignment = .leading
        espeakSection.spacing = 4
        espeakSection.translatesAutoresizingMaskIntoConstraints = false

        baseModelLabel.font = Theme.font(12)
        baseModelLabel.lineBreakMode = .byTruncatingTail
        baseModelLabel.usesSingleLineMode = true
        baseModelLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        baseModelLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        baseModelButton.bezelStyle = .rounded
        baseModelButton.target = self
        baseModelButton.action = #selector(baseModelButtonTapped)
        baseModelButton.setContentHuggingPriority(.required, for: .horizontal)

        let baseModelRow = NSStackView(views: [baseModelLabel, baseModelButton])
        baseModelRow.orientation = .horizontal
        baseModelRow.alignment = .centerY
        baseModelRow.spacing = 8
        baseModelRow.translatesAutoresizingMaskIntoConstraints = false

        let langLabel = NSTextField(labelWithString: "Language:")
        let genderLabel = NSTextField(labelWithString: "Gender:")
        languagePopup.bezelStyle = .rounded
        genderPopup.bezelStyle = .rounded
        languagePopup.target = self
        genderPopup.target = self
        languagePopup.action = #selector(filterChanged)
        genderPopup.action = #selector(filterChanged)
        languagePopup.addItem(withTitle: "All")
        for lang in KokoroLanguage.allCases {
            languagePopup.addItem(withTitle: lang.displayLabel)
            languagePopup.lastItem?.representedObject = lang.rawValue
        }
        genderPopup.addItem(withTitle: "All")
        genderPopup.addItem(withTitle: "Female")
        genderPopup.lastItem?.representedObject = KokoroGender.female.rawValue
        genderPopup.addItem(withTitle: "Male")
        genderPopup.lastItem?.representedObject = KokoroGender.male.rawValue

        let filterBar = NSStackView(views: [langLabel, languagePopup, genderLabel, genderPopup, NSView(), countLabel])
        filterBar.orientation = .horizontal
        filterBar.alignment = .centerY
        filterBar.spacing = 8
        filterBar.translatesAutoresizingMaskIntoConstraints = false
        countLabel.font = Theme.font(11)
        countLabel.textColor = .secondaryLabelColor

        configureTable()
        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        cv.addSubview(banner)
        cv.addSubview(espeakSection)
        cv.addSubview(baseModelRow)
        cv.addSubview(filterBar)
        cv.addSubview(scrollView)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            espeakSection.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
            espeakSection.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            espeakSection.trailingAnchor.constraint(lessThanOrEqualTo: cv.trailingAnchor, constant: -16),

            baseModelRow.topAnchor.constraint(equalTo: espeakSection.bottomAnchor, constant: 12),
            baseModelRow.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            baseModelRow.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            filterBar.topAnchor.constraint(equalTo: baseModelRow.bottomAnchor, constant: 12),
            filterBar.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            filterBar.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            scrollView.topAnchor.constraint(equalTo: filterBar.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            scrollView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),
            scrollView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -16),
        ])
    }

    private func configureTable() {
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.rowSizeStyle = .default
        tableView.allowsColumnReordering = false
        tableView.allowsColumnSelection = false
        tableView.dataSource = self
        tableView.delegate = self

        let nameCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameCol.title = "Voice"
        nameCol.minWidth = 140
        nameCol.width = 180
        tableView.addTableColumn(nameCol)

        let langCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("language"))
        langCol.title = "Language"
        langCol.minWidth = 120
        langCol.width = 140
        tableView.addTableColumn(langCol)

        let genderCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("gender"))
        genderCol.title = "Gender"
        genderCol.minWidth = 60
        genderCol.width = 70
        tableView.addTableColumn(genderCol)

        let stateCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("state"))
        stateCol.title = "State"
        stateCol.minWidth = 110
        stateCol.width = 160
        tableView.addTableColumn(stateCol)

        let actionCol = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("action"))
        actionCol.title = "Action"
        actionCol.minWidth = 90
        actionCol.width = 100
        tableView.addTableColumn(actionCol)
    }

    // MARK: - Refresh

    private func rebuild() {
        let s = AppState.shared.settings
        if let raw = s.voiceModelPath, !raw.isEmpty {
            let abbrev = (raw as NSString).abbreviatingWithTildeInPath
            banner.stringValue = "Storage: \(abbrev)"
        } else {
            banner.stringValue = "No storage location set. Open Settings → Voice storage to pick a folder."
        }
        refreshEspeakRow()
        refreshBaseModelRow()
        applyFilter()
    }

    private func refreshEspeakRow() {
        if let url = EspeakNg.find() {
            espeakStatusLabel.stringValue = "espeak-ng (G2P engine): ✓ found at \(url.path)"
            espeakStatusLabel.textColor = .secondaryLabelColor
            espeakInstallRow.isHidden = true
        } else {
            espeakStatusLabel.stringValue = "espeak-ng (G2P engine): ◯ not installed — required for Kokoro voices."
            espeakStatusLabel.textColor = .labelColor
            espeakInstallRow.isHidden = false
        }
    }

    @objc private func espeakCopyCommand() {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString("brew install espeak-ng", forType: .string)
        // Brief visual confirmation: button title flickers to "Copied" for
        // ~1.2s. Cheap feedback that beats a sheet alert.
        let original = espeakCopyButton.title
        espeakCopyButton.title = "Copied"
        espeakCopyButton.isEnabled = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self = self else { return }
            self.espeakCopyButton.title = original
            self.espeakCopyButton.isEnabled = true
        }
    }

    @objc private func espeakRecheck() {
        refreshEspeakRow()
    }

    private func currentStore() -> KokoroModelStore? {
        let s = AppState.shared.settings
        guard let raw = s.voiceModelPath, !raw.isEmpty else { return nil }
        return KokoroModelStore(paths: KokoroStoragePaths(root: URL(fileURLWithPath: raw)))
    }

    private func refreshBaseModelRow() {
        let dl = KokoroDownloadManager.shared.state(of: "model")
        if case .running(let bytes, let total) = dl {
            baseModelLabel.stringValue = "Base model: ⬇︎ \(progressText(bytes: bytes, total: total))"
            baseModelButton.title = "Cancel"
            baseModelButton.isEnabled = true
            return
        }

        guard let store = currentStore() else {
            baseModelLabel.stringValue = "Base model: — (no storage location)"
            baseModelButton.title = "Download"
            baseModelButton.isEnabled = false
            return
        }
        switch store.baseModelState() {
        case .ready:
            baseModelLabel.stringValue = "Base model: ✓ ready"
            baseModelButton.title = "Remove"
            baseModelButton.isEnabled = true
        case .missing:
            let mb = KokoroVoiceCatalogue.modelByteSize / 1_000_000
            baseModelLabel.stringValue = "Base model: ◯ not downloaded (\(mb) MB)"
            baseModelButton.title = "Download"
            baseModelButton.isEnabled = true
        case .volumeUnavailable:
            baseModelLabel.stringValue = "Base model: ⚠︎ volume unavailable"
            baseModelButton.title = "Download"
            baseModelButton.isEnabled = false
        }
    }

    private func progressText(bytes: Int64, total: Int64?) -> String {
        let mb: (Int64) -> String = { b in
            String(format: "%.1f MB", Double(b) / 1_000_000.0)
        }
        if let total = total, total > 0 {
            let pct = Int(Double(bytes) / Double(total) * 100)
            return "\(mb(bytes)) of \(mb(total)) (\(pct)%)"
        }
        return mb(bytes)
    }

    @objc private func baseModelButtonTapped() {
        guard let store = currentStore() else { return }
        let manager = KokoroDownloadManager.shared
        if case .running = manager.state(of: "model") {
            manager.cancel(id: "model")
            return
        }
        switch store.baseModelState() {
        case .ready:
            do {
                try store.removeModel()
                rebuild()
            } catch {
                presentRemoveError(error: error)
            }
        case .missing:
            let task = KokoroDownloadTask(
                asset: .baseModel,
                sourceURL: KokoroVoiceCatalogue.modelDownloadURL,
                destinationURL: store.paths.modelURL,
                expectedBytes: Int64(KokoroVoiceCatalogue.modelByteSize)
            )
            manager.enqueue(task, store: store)
        case .volumeUnavailable:
            break
        }
    }

    private func presentRemoveError(error: Error) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = "Couldn't remove the base model"
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func handleDownloadStateChanged(id: String) {
        if id == "model" {
            refreshBaseModelRow()
            // Base-model completion unlocks per-voice Download buttons,
            // so reload the table to refresh action-cell enabled state.
            if case .completed = KokoroDownloadManager.shared.state(of: id) {
                tableView.reloadData()
            }
        } else {
            voiceDownloadStateChanged(id: id)
        }
    }

    @objc private func filterChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let langRaw = languagePopup.selectedItem?.representedObject as? String
        let genderRaw = genderPopup.selectedItem?.representedObject as? String
        rows = KokoroVoiceCatalogue.all.filter { voice in
            if let r = langRaw, voice.language.rawValue != r { return false }
            if let r = genderRaw, voice.gender.rawValue != r { return false }
            return true
        }
        countLabel.stringValue = "\(rows.count) voice\(rows.count == 1 ? "" : "s")"
        tableView.reloadData()
    }

    private enum VoiceRowAction { case download, cancel, remove, none }

    private func voiceStateLabel(_ voice: KokoroVoice) -> String {
        if let dl = KokoroDownloadManager.shared.state(of: voice.id) {
            switch dl {
            case .running(let bytes, let total):
                return "⬇︎ \(progressText(bytes: bytes, total: total))"
            case .queued:
                return "… queued"
            case .failed(let msg):
                return "⚠︎ \(msg)"
            case .cancelled, .completed:
                break  // fall through to on-disk truth
            }
        }
        guard let store = currentStore() else { return "—" }
        switch store.voiceState(id: voice.id) {
        case .ready: return "✓ installed"
        case .missing: return "◯ not installed"
        case .volumeUnavailable: return "⚠︎ unavailable"
        }
    }

    private func voiceRowAction(_ voice: KokoroVoice) -> VoiceRowAction {
        if case .running = KokoroDownloadManager.shared.state(of: voice.id) { return .cancel }
        if case .queued = KokoroDownloadManager.shared.state(of: voice.id) { return .cancel }
        guard let store = currentStore() else { return .none }
        switch store.voiceState(id: voice.id) {
        case .ready: return .remove
        case .missing: return .download
        case .volumeUnavailable: return .none
        }
    }

    private func voiceActionEnabled(_ voice: KokoroVoice) -> Bool {
        switch voiceRowAction(voice) {
        case .none: return false
        case .cancel, .remove: return true
        case .download:
            // Download enabled only when base model is ready.
            guard let store = currentStore() else { return false }
            if case .ready = store.baseModelState() { return true }
            return false
        }
    }

    private func voiceActionTooltip(_ voice: KokoroVoice) -> String? {
        if voiceRowAction(voice) == .download,
           let store = currentStore(),
           case .ready = store.baseModelState() {
            return nil
        }
        if voiceRowAction(voice) == .download {
            return "Download the base model first"
        }
        return nil
    }

    @objc fileprivate func voiceActionTapped(_ sender: NSButton) {
        let row = sender.tag
        guard row >= 0 && row < rows.count else { return }
        let voice = rows[row]
        switch voiceRowAction(voice) {
        case .cancel:
            KokoroDownloadManager.shared.cancel(id: voice.id)
        case .remove:
            guard let store = currentStore() else { return }
            do {
                try store.removeVoice(id: voice.id)
                reloadRow(for: voice.id)
            } catch {
                presentVoiceError(message: "Couldn't remove \(voice.displayName)", error: error)
            }
        case .download:
            guard let store = currentStore() else { return }
            let task = KokoroDownloadTask(
                asset: .voice(id: voice.id),
                sourceURL: voice.downloadURL,
                destinationURL: store.paths.voiceFileURL(id: voice.id),
                expectedBytes: Int64(KokoroVoiceCatalogue.voiceByteSizeApprox)
            )
            KokoroDownloadManager.shared.enqueue(task, store: store)
        case .none:
            break
        }
    }

    private func presentVoiceError(message: String, error: Error) {
        guard let window = window else { return }
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        alert.beginSheetModal(for: window, completionHandler: nil)
    }

    private func reloadRow(for voiceId: String) {
        guard let idx = rows.firstIndex(where: { $0.id == voiceId }) else { return }
        let columns = IndexSet(integersIn: 0..<tableView.numberOfColumns)
        tableView.reloadData(forRowIndexes: IndexSet(integer: idx), columnIndexes: columns)
    }

    /// Override of handleDownloadStateChanged for non-"model" ids — voice
    /// rows reload themselves rather than the entire table so progress
    /// updates don't churn 54 cells per chunk.
    fileprivate func voiceDownloadStateChanged(id: String) {
        reloadRow(for: id)
    }
}

extension VoiceLibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let voice = rows[row]
        let cell = NSTableCellView()

        if column.identifier.rawValue == "action" {
            let button = NSButton(title: "", target: self, action: #selector(voiceActionTapped(_:)))
            button.bezelStyle = .rounded
            button.translatesAutoresizingMaskIntoConstraints = false
            button.tag = row
            switch voiceRowAction(voice) {
            case .download: button.title = "Download"
            case .cancel:   button.title = "Cancel"
            case .remove:   button.title = "Remove"
            case .none:     button.title = "—"
            }
            button.isEnabled = voiceActionEnabled(voice)
            button.toolTip = voiceActionTooltip(voice)
            cell.addSubview(button)
            NSLayoutConstraint.activate([
                button.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 2),
                button.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -2),
                button.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
            ])
            return cell
        }

        let tf = NSTextField(labelWithString: "")
        tf.font = Theme.font(12)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false

        switch column.identifier.rawValue {
        case "name":
            tf.stringValue = "\(voice.displayName)  ·  \(voice.id)"
        case "language":
            tf.stringValue = voice.language.displayLabel
        case "gender":
            tf.stringValue = voice.gender == .female ? "Female" : "Male"
        case "state":
            tf.stringValue = voiceStateLabel(voice)
            tf.textColor = .secondaryLabelColor
        default:
            tf.stringValue = ""
        }

        cell.addSubview(tf)
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 4),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -4),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor)
        ])
        return cell
    }
}
