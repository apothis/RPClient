import AppKit

final class SidebarViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let newButton = NSButton(title: "+ New Chat", target: nil, action: nil)

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        newButton.target = self
        newButton.action = #selector(newChat)
        newButton.bezelStyle = .rounded
        newButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(newButton)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.title = "Chats"
        col.width = 200
        tableView.addTableColumn(col)
        tableView.headerView = nil
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        tableView.rowHeight = 56
        tableView.style = .sourceList
        tableView.menu = makeContextMenu()

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        NSLayoutConstraint.activate([
            newButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            newButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            newButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),

            scrollView.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatListChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        // Re-render badges once the model probe lands (and on each
        // statusChanged tick) so chats whose template doesn't match the
        // currently-loaded model flip red.
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.statusChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func reload() {
        tableView.reloadData()
        if let cur = AppState.shared.currentChatId,
           let row = AppState.shared.chats.firstIndex(where: { $0.id == cur }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        }
    }

    @objc private func newChat() {
        AppState.shared.newChat()
    }

    @objc private func rowClicked() {
        let row = tableView.selectedRow
        guard row >= 0, row < AppState.shared.chats.count else { return }
        AppState.shared.selectChat(id: AppState.shared.chats[row].id)
    }

    private func makeContextMenu() -> NSMenu {
        let m = NSMenu()
        let del = NSMenuItem(title: "Delete", action: #selector(deleteSelected), keyEquivalent: "")
        del.target = self
        m.addItem(del)
        return m
    }

    @objc private func deleteSelected() {
        let row = tableView.clickedRow
        guard row >= 0, row < AppState.shared.chats.count else { return }
        let id = AppState.shared.chats[row].id
        let alert = NSAlert()
        alert.messageText = "Delete this chat?"
        alert.informativeText = AppState.shared.chats[row].title
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppState.shared.deleteChat(id: id)
        }
    }
}

extension SidebarViewController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        AppState.shared.chats.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let chat = AppState.shared.chats[row]
        let cell = NSTableCellView()

        let tf = NSTextField(labelWithString: chat.title)
        tf.lineBreakMode = .byTruncatingTail
        tf.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(tf)
        cell.textField = tf

        // Subtitle: total turn count + user-turn count. Two numbers because
        // cadence settings (extractor, summary) are user-turn-based, but the
        // sidebar is also a quick eyeball check for "how long is this chat".
        let total = chat.turns.count
        let userTurns = chat.turns.filter { $0.role == .user }.count
        let subtitle = NSTextField(labelWithString:
            total == 0 ? "empty" : "turn \(total) · \(userTurns) sent"
        )
        subtitle.font = Theme.font(10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(subtitle)

        // Template badge on its own line below the subtitle. Lets the user
        // spot at a glance whether a chat's template matches the currently
        // loaded model — mismatch means empty / echoed replies. Tinted red
        // when the chat's template doesn't match the auto-detected one.
        let detected = AppState.shared.detectedTemplateId
        let mismatch = (detected != nil) && (detected != chat.templateId)
        let badge = NSTextField(labelWithString: chat.templateId)
        badge.font = Theme.mono(9)
        badge.textColor = mismatch ? .systemRed : .tertiaryLabelColor
        badge.toolTip = mismatch
            ? "This chat uses '\(chat.templateId)' but the loaded model looks like '\(detected!)'. Replies may be empty or echoed until you switch."
            : "Prompt template for this chat"
        badge.lineBreakMode = .byTruncatingTail
        badge.translatesAutoresizingMaskIntoConstraints = false
        cell.addSubview(badge)

        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -8),
            tf.topAnchor.constraint(equalTo: cell.topAnchor, constant: 4),

            subtitle.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
            subtitle.trailingAnchor.constraint(equalTo: tf.trailingAnchor),
            subtitle.topAnchor.constraint(equalTo: tf.bottomAnchor, constant: 1),

            badge.leadingAnchor.constraint(equalTo: tf.leadingAnchor),
            badge.trailingAnchor.constraint(equalTo: tf.trailingAnchor),
            badge.topAnchor.constraint(equalTo: subtitle.bottomAnchor, constant: 1)
        ])
        return cell
    }
}
