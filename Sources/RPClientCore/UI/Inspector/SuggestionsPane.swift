import AppKit

/// Inspector pane showing the queue of fact suggestions emitted by the §9.3
/// extractor. Each row: `[type] entity — fact` with ✓ (promote to pinned
/// memory) and ✗ (dismiss) buttons. Acts as the trust layer in front of
/// auto-extraction (Step B): the extractor never writes directly to memory
/// any more; the user confirms each suggestion here.
final class SuggestionsPane: NSViewController {
    private let scrollView = NSScrollView()
    private let rowsStack = NSStackView()
    private let helpLabel = NSTextField(labelWithString: "Pending fact suggestions. ✓ promotes to pinned memory, ✗ dismisses.")
    private let countLabel = NSTextField(labelWithString: "")
    private let emptyLabel = NSTextField(labelWithString: "No fact suggestions. Run extraction (Debug menu) or wait for auto-extraction.")

    private var lastChatId: UUID?
    private var renderedIds: [UUID] = []

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        helpLabel.font = Theme.font(11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 0
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(helpLabel)

        rowsStack.orientation = .vertical
        rowsStack.spacing = 4
        rowsStack.alignment = .leading
        rowsStack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 4, right: 4)
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = rowsStack
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)
        rowsStack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor).isActive = true

        emptyLabel.font = Theme.font(11)
        emptyLabel.textColor = .tertiaryLabelColor
        emptyLabel.lineBreakMode = .byWordWrapping
        emptyLabel.maximumNumberOfLines = 0
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(emptyLabel)

        countLabel.font = Theme.mono(11)
        countLabel.textColor = .secondaryLabelColor
        countLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(countLabel)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: countLabel.topAnchor, constant: -6),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: scrollView.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: scrollView.trailingAnchor, constant: -16),

            countLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            countLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        helpLabel.font = Theme.font(11)
        countLabel.font = Theme.mono(11)
        emptyLabel.font = Theme.font(11)
        for view in rowsStack.arrangedSubviews {
            if let field = view.subviews.compactMap({ $0 as? NSTextField }).first {
                field.font = Theme.font(12)
            }
        }
    }

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else {
            renderedIds = []
            rebuildRows(from: [])
            countLabel.stringValue = ""
            emptyLabel.isHidden = false
            return
        }
        let ids = chat.pendingFactSuggestions.map { $0.id }
        // Skip rebuild if nothing changed and same chat — avoids flicker when
        // chatUpdated fires for unrelated reasons (token append, etc.).
        let chatChanged = chat.id != lastChatId
        if !chatChanged && ids == renderedIds { return }
        lastChatId = chat.id
        renderedIds = ids
        rebuildRows(from: chat.pendingFactSuggestions)
        let n = chat.pendingFactSuggestions.count
        countLabel.stringValue = "\(n) suggestion\(n == 1 ? "" : "s") pending"
        emptyLabel.isHidden = n > 0
    }

    private func rebuildRows(from suggestions: [FactSuggestion]) {
        for v in rowsStack.arrangedSubviews { rowsStack.removeArrangedSubview(v); v.removeFromSuperview() }
        for s in suggestions {
            let row = makeRow(suggestion: s)
            rowsStack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: rowsStack.widthAnchor, constant: -8).isActive = true
        }
    }

    private func makeRow(suggestion s: FactSuggestion) -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let typeBadge = NSTextField(labelWithString: s.category)
        typeBadge.font = Theme.mono(10)
        typeBadge.textColor = .secondaryLabelColor
        typeBadge.translatesAutoresizingMaskIntoConstraints = false

        let factField = NSTextField(labelWithString: s.fact)
        factField.font = Theme.font(12)
        factField.lineBreakMode = .byTruncatingTail
        factField.toolTip = s.fact
        factField.translatesAutoresizingMaskIntoConstraints = false

        let accept = NSButton(title: "✓", target: self, action: #selector(acceptRow(_:)))
        accept.bezelStyle = .circular
        accept.toolTip = "Promote to pinned memory"
        accept.identifier = NSUserInterfaceItemIdentifier(s.id.uuidString)
        accept.translatesAutoresizingMaskIntoConstraints = false

        let dismiss = NSButton(title: "×", target: self, action: #selector(dismissRow(_:)))
        dismiss.bezelStyle = .circular
        dismiss.toolTip = "Dismiss"
        dismiss.identifier = NSUserInterfaceItemIdentifier(s.id.uuidString)
        dismiss.translatesAutoresizingMaskIntoConstraints = false

        row.addSubview(typeBadge)
        row.addSubview(factField)
        row.addSubview(accept)
        row.addSubview(dismiss)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 26),

            typeBadge.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            typeBadge.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            typeBadge.widthAnchor.constraint(equalToConstant: 78),

            factField.leadingAnchor.constraint(equalTo: typeBadge.trailingAnchor, constant: 6),
            factField.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            factField.trailingAnchor.constraint(equalTo: accept.leadingAnchor, constant: -6),

            accept.trailingAnchor.constraint(equalTo: dismiss.leadingAnchor, constant: -4),
            accept.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            accept.widthAnchor.constraint(equalToConstant: 24),
            accept.heightAnchor.constraint(equalToConstant: 22),

            dismiss.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            dismiss.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dismiss.widthAnchor.constraint(equalToConstant: 24),
            dismiss.heightAnchor.constraint(equalToConstant: 22)
        ])
        return row
    }

    @objc private func acceptRow(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        AppState.shared.acceptSuggestion(id: id)
    }

    @objc private func dismissRow(_ sender: NSButton) {
        guard let id = sender.identifier.flatMap({ UUID(uuidString: $0.rawValue) }) else { return }
        AppState.shared.dismissSuggestion(id: id)
    }
}
