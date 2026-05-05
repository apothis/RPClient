import AppKit
import UniformTypeIdentifiers

final class SidebarViewController: NSViewController {
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let newButton = NSPopUpButton(frame: .zero, pullsDown: true)

    override func loadView() {
        let v = SidebarRootView()
        v.wantsLayer = true
        v.dropHandler = { [weak self] urls in self?.handleDroppedFiles(urls) ?? false }
        v.registerForDraggedTypes([.fileURL])
        self.view = v

        configureNewButton()
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
        // Pick up new / updated character avatars. AvatarSource clears its
        // own cache on this same notification — reloading the table forces a
        // fresh image() lookup in viewFor row.
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.charactersChanged, object: nil)
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

    /// Configure the sidebar's new-chat button as a pull-down menu so the
    /// V2 §4.3 split (New Chat vs. New Chat with Character…) fits the same
    /// real estate without adding a second button. The first menu item's
    /// title is what shows on the closed button.
    private func configureNewButton() {
        newButton.translatesAutoresizingMaskIntoConstraints = false
        newButton.bezelStyle = .rounded
        newButton.removeAllItems()
        // Pull-down treats item 0 as the visible title; we add a hidden
        // sentinel so item 1+ are the real actions.
        newButton.addItem(withTitle: "+ New")
        let plain = NSMenuItem(
            title: "New Chat",
            action: #selector(newChatPlain),
            keyEquivalent: "")
        plain.target = self
        newButton.menu?.addItem(plain)
        let withChar = NSMenuItem(
            title: "New Chat with Character…",
            action: #selector(newChatWithCharacter),
            keyEquivalent: "")
        withChar.target = self
        newButton.menu?.addItem(withChar)
    }

    @objc private func newChatPlain() {
        AppState.shared.newChat()
    }

    @objc private func newChatWithCharacter() {
        let characters = AppState.shared.characters
        guard !characters.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No characters yet"
            alert.informativeText = "Drag a SillyTavern card PNG onto the sidebar, or use File → Import Character… to add one."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        let menu = NSMenu()
        for c in characters {
            let item = NSMenuItem(
                title: c.name,
                action: #selector(startChatFromMenu(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = c.id.uuidString
            menu.addItem(item)
        }
        // Anchor near the new-chat button so the picker drops in-place.
        let origin = NSPoint(x: 0, y: newButton.bounds.height)
        menu.popUp(positioning: nil, at: origin, in: newButton)
    }

    @objc private func startChatFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let character = AppState.shared.character(id: id) else { return }
        AppState.shared.newChat(withCharacter: character)
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

    /// Try to import every dropped file as a character card. Errors are
    /// surfaced individually so a partial drop (one good PNG, one corrupt)
    /// still imports the good one. Returns true if at least one file was
    /// successfully imported — that's what the dragging machinery uses to
    /// decide whether to flash "accept" feedback to the user.
    private func handleDroppedFiles(_ urls: [URL]) -> Bool {
        guard !urls.isEmpty else { return false }
        var importedCount = 0
        var errors: [(String, Error)] = []
        for url in urls {
            let ext = url.pathExtension.lowercased()
            guard ext == "png" || ext == "json" else { continue }
            do {
                _ = try AppState.shared.importCharacter(from: url)
                importedCount += 1
            } catch {
                errors.append((url.lastPathComponent, error))
            }
        }
        if !errors.isEmpty {
            let alert = NSAlert()
            if errors.count == 1, let first = errors.first {
                alert.messageText = "Couldn't import \(first.0)"
                alert.informativeText = String(describing: first.1)
            } else {
                alert.messageText = "Some imports failed"
                alert.informativeText = errors
                    .map { "• \($0.0): \($0.1)" }
                    .joined(separator: "\n")
            }
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
        return importedCount > 0
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

        // V2_PLAN §6.1 — leading 32px avatar, circular. Resolves the chat's
        // character avatar via AvatarSource (which caches), falling back to
        // an initials placeholder rendered from the chat title when the chat
        // has no character attached.
        let avatar = NSImageView()
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 16
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        if let charId = chat.characterId,
           let character = AppState.shared.character(id: charId) {
            avatar.image = AvatarSource.shared.image(forCharacter: charId, name: character.name)
        } else {
            avatar.image = placeholderAvatar(initials: chat.title)
        }
        cell.addSubview(avatar)

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
            avatar.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            avatar.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 32),
            avatar.heightAnchor.constraint(equalToConstant: 32),

            tf.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
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

/// Root NSView for the sidebar that accepts character-card drops anywhere on
/// its surface. Hands off to a closure (set by `SidebarViewController`) so
/// the dragging logic stays out of the controller.
final class SidebarRootView: NSView {
    /// Returns true if at least one of the dropped URLs was imported.
    var dropHandler: (([URL]) -> Bool)?

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).contains(where: isCardURL) ? .copy : []
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        urls(from: sender).contains(where: isCardURL) ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        let candidates = urls(from: sender).filter(isCardURL)
        guard !candidates.isEmpty else { return false }
        return dropHandler?(candidates) ?? false
    }

    private func urls(from info: NSDraggingInfo) -> [URL] {
        guard let items = info.draggingPasteboard.pasteboardItems else { return [] }
        return items.compactMap { item in
            guard let str = item.string(forType: .fileURL),
                  let url = URL(string: str) else { return nil }
            return url
        }
    }

    private func isCardURL(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "png" || ext == "json"
    }
}
