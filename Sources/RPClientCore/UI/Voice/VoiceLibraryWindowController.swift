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
    private let baseModelRow = NSTextField(labelWithString: "")
    private let languagePopup = NSPopUpButton()
    private let genderPopup = NSPopUpButton()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let countLabel = NSTextField(labelWithString: "")

    private var rows: [KokoroVoice] = []
    private var settingsObserver: NSObjectProtocol?

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 480, height: 320)
        w.title = "Voice library"
        w.setFrameAutosaveName("RPClient.VoiceLibraryWindow")
        self.init(window: w)
        w.delegate = self
        buildUI()
        rebuild()
        settingsObserver = NotificationCenter.default.addObserver(
            forName: AppNotification.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.rebuild()
        }
    }

    deinit {
        if let o = settingsObserver { NotificationCenter.default.removeObserver(o) }
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        banner.font = Theme.font(11)
        banner.textColor = .secondaryLabelColor
        banner.translatesAutoresizingMaskIntoConstraints = false

        baseModelRow.font = Theme.font(12)
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
        cv.addSubview(baseModelRow)
        cv.addSubview(filterBar)
        cv.addSubview(scrollView)

        NSLayoutConstraint.activate([
            banner.topAnchor.constraint(equalTo: cv.topAnchor, constant: 12),
            banner.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 16),
            banner.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -16),

            baseModelRow.topAnchor.constraint(equalTo: banner.bottomAnchor, constant: 8),
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
        stateCol.minWidth = 80
        stateCol.width = 100
        tableView.addTableColumn(stateCol)
    }

    // MARK: - Refresh

    private func rebuild() {
        let s = AppState.shared.settings
        if let raw = s.voiceModelPath, !raw.isEmpty {
            let url = URL(fileURLWithPath: raw)
            let abbrev = (raw as NSString).abbreviatingWithTildeInPath
            banner.stringValue = "Storage: \(abbrev)"
            baseModelRow.stringValue = baseModelRowText(rootURL: url)
        } else {
            banner.stringValue = "No storage location set. Open Settings → Voice storage to pick a folder."
            baseModelRow.stringValue = "Base model: — (no storage location)"
        }
        applyFilter()
    }

    private func baseModelRowText(rootURL: URL) -> String {
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: rootURL))
        switch store.baseModelState() {
        case .ready: return "Base model: ✓ ready"
        case .missing: return "Base model: ◯ not downloaded"
        case .volumeUnavailable: return "Base model: ⚠︎ volume unavailable"
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

    private func voiceStateLabel(_ voice: KokoroVoice) -> String {
        let s = AppState.shared.settings
        guard let raw = s.voiceModelPath, !raw.isEmpty else { return "—" }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: URL(fileURLWithPath: raw)))
        switch store.voiceState(id: voice.id) {
        case .ready: return "✓ installed"
        case .missing: return "◯ not installed"
        case .volumeUnavailable: return "⚠︎ unavailable"
        }
    }
}

extension VoiceLibraryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard let column = tableColumn, row < rows.count else { return nil }
        let voice = rows[row]
        let cell = NSTableCellView()
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
