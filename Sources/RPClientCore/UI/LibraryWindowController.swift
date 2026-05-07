import AppKit
import UniformTypeIdentifiers

/// Library window introduced in Phase 3 §4.3. Two tabs:
///   • Characters — imported via File menu / drag-drop / explicit "+ Import…"
///     button. Tile shows avatar + name + tag/creator line. Selection enables
///     "Start Chat" (creates a new chat with `characterId` set) and "Delete".
///   • Personas — user-created via "+ New Persona" → edit sheet (name +
///     description). Selection enables "Edit" / "Delete".
///
/// The controller subscribes to `charactersChanged` / `personasChanged` so a
/// drag-drop import elsewhere also refreshes this view.
final class LibraryWindowController: NSWindowController, NSWindowDelegate {

    private let tabView = NSTabView()
    private let charactersVC = CharactersTabViewController()
    private let personasVC = PersonasTabViewController()

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 520),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 520, height: 360)
        w.title = "Library"
        w.setFrameAutosaveName("RPClient.LibraryWindow")
        self.init(window: w)
        w.delegate = self
        buildUI()
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        tabView.translatesAutoresizingMaskIntoConstraints = false
        let charsItem = NSTabViewItem(viewController: charactersVC)
        charsItem.label = "Characters"
        let personasItem = NSTabViewItem(viewController: personasVC)
        personasItem.label = "Personas"
        tabView.addTabViewItem(charsItem)
        tabView.addTabViewItem(personasItem)

        cv.addSubview(tabView)
        NSLayoutConstraint.activate([
            tabView.topAnchor.constraint(equalTo: cv.topAnchor, constant: 8),
            tabView.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 8),
            tabView.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -8),
            tabView.bottomAnchor.constraint(equalTo: cv.bottomAnchor, constant: -8),
        ])
    }
}

// MARK: - Characters tab

final class CharactersTabViewController: NSViewController {

    private let newCardButton = NSButton(title: "+ New Card", target: nil, action: nil)
    private let importButton = NSButton(title: "+ Import…", target: nil, action: nil)
    private let startChatButton = NSButton(title: "Start Chat", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit Card…", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let collectionView = LibraryCollectionView()
    private let layout = NSCollectionViewFlowLayout()

    private var items: [Character] = []

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        newCardButton.target = self
        newCardButton.action = #selector(newCard)
        newCardButton.bezelStyle = .rounded
        newCardButton.translatesAutoresizingMaskIntoConstraints = false

        importButton.target = self
        importButton.action = #selector(importCharacter)
        importButton.bezelStyle = .rounded
        importButton.translatesAutoresizingMaskIntoConstraints = false

        startChatButton.target = self
        startChatButton.action = #selector(startChat)
        startChatButton.bezelStyle = .rounded
        startChatButton.isEnabled = false
        startChatButton.translatesAutoresizingMaskIntoConstraints = false

        editButton.target = self
        editButton.action = #selector(editSelection)
        editButton.bezelStyle = .rounded
        editButton.isEnabled = false
        editButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelection)
        deleteButton.bezelStyle = .rounded
        deleteButton.isEnabled = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.font(11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = "No selection."

        layout.itemSize = CharacterCardView.itemSize
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(CharacterCardView.self, forItemWithIdentifier: CharacterCardView.reuseId)
        collectionView.contextMenuProvider = { [weak self] indexPath in
            self?.contextMenu(for: indexPath)
        }
        collectionView.doubleClickHandler = { [weak self] indexPath in
            self?.openCreatorForCharacter(at: indexPath)
        }

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(newCardButton)
        v.addSubview(importButton)
        v.addSubview(startChatButton)
        v.addSubview(editButton)
        v.addSubview(deleteButton)
        v.addSubview(scrollView)
        v.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            newCardButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            newCardButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),

            importButton.centerYAnchor.constraint(equalTo: newCardButton.centerYAnchor),
            importButton.leadingAnchor.constraint(equalTo: newCardButton.trailingAnchor, constant: 8),

            startChatButton.centerYAnchor.constraint(equalTo: newCardButton.centerYAnchor),
            startChatButton.leadingAnchor.constraint(equalTo: importButton.trailingAnchor, constant: 8),

            editButton.centerYAnchor.constraint(equalTo: newCardButton.centerYAnchor),
            editButton.leadingAnchor.constraint(equalTo: startChatButton.trailingAnchor, constant: 8),

            deleteButton.centerYAnchor.constraint(equalTo: newCardButton.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: newCardButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.charactersChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        items = AppState.shared.characters
        collectionView.reloadData()
        updateButtons()
    }

    private func selectedCharacter() -> Character? {
        guard let path = collectionView.selectionIndexPaths.first,
              path.item < items.count else { return nil }
        return items[path.item]
    }

    private func updateButtons() {
        let selected = selectedCharacter()
        startChatButton.isEnabled = selected != nil
        editButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        if let c = selected {
            var lines: [String] = []
            lines.append(c.name)
            if let creator = c.creator, !creator.isEmpty {
                lines.append("by \(creator)" + (c.characterVersion.map { " (v\($0))" } ?? ""))
            } else if let v = c.characterVersion {
                lines.append("v\(v)")
            }
            if !c.tags.isEmpty {
                lines.append("tags: " + c.tags.joined(separator: ", "))
            }
            let description = c.description.trimmingCharacters(in: .whitespacesAndNewlines)
            if !description.isEmpty {
                lines.append(String(description.prefix(220)))
            }
            detailLabel.stringValue = lines.joined(separator: "\n")
        } else {
            detailLabel.stringValue = "No selection."
        }
    }

    @objc private func importCharacter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .json]
        panel.message = "Choose a SillyTavern v2 character card (.png or .json)."
        let response = panel.runModal()
        guard response == .OK, let url = panel.url else { return }
        do {
            _ = try AppState.shared.importCharacter(from: url)
        } catch {
            presentImportError(error, source: url.lastPathComponent)
        }
    }

    @objc private func startChat() {
        guard let c = selectedCharacter() else { return }
        AppState.shared.newChat(withCharacter: c)
        view.window?.close()
    }

    @objc private func newCard() {
        // Phase 9 §5.3d.1 — open the Card Creator empty. Posts via the
        // App-level helper so all creator windows are tracked in one place.
        (NSApp.delegate as? AppDelegate)?.openNewCardCreator()
    }

    @objc fileprivate func editSelection() {
        guard let c = selectedCharacter() else { return }
        (NSApp.delegate as? AppDelegate)?.openEditCardCreator(for: c)
    }

    /// Open the creator on the character at `indexPath` in the collection
    /// view. Used by the right-click context menu and double-click handler
    /// so the targeted card is edited even if the current selection is
    /// something else.
    fileprivate func openCreatorForCharacter(at indexPath: IndexPath) {
        guard indexPath.item < items.count else { return }
        let c = items[indexPath.item]
        (NSApp.delegate as? AppDelegate)?.openEditCardCreator(for: c)
    }

    /// Build the right-click context menu for the character at `indexPath`,
    /// or a card-less menu when the user right-clicks on empty space.
    fileprivate func contextMenu(for indexPath: IndexPath?) -> NSMenu {
        let menu = NSMenu()
        if let path = indexPath, path.item < items.count {
            let c = items[path.item]
            let edit = NSMenuItem(title: "Edit Card…", action: #selector(contextMenuEdit(_:)), keyEquivalent: "")
            edit.target = self
            edit.representedObject = c.id
            menu.addItem(edit)

            let chat = NSMenuItem(title: "Start Chat", action: #selector(contextMenuStartChat(_:)), keyEquivalent: "")
            chat.target = self
            chat.representedObject = c.id
            menu.addItem(chat)

            menu.addItem(.separator())

            let del = NSMenuItem(title: "Delete…", action: #selector(contextMenuDelete(_:)), keyEquivalent: "")
            del.target = self
            del.representedObject = c.id
            menu.addItem(del)
        } else {
            let new = NSMenuItem(title: "New Card…", action: #selector(newCard), keyEquivalent: "")
            new.target = self
            menu.addItem(new)

            let imp = NSMenuItem(title: "Import…", action: #selector(importCharacter), keyEquivalent: "")
            imp.target = self
            menu.addItem(imp)
        }
        return menu
    }

    @objc private func contextMenuEdit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let c = items.first(where: { $0.id == id }) else { return }
        (NSApp.delegate as? AppDelegate)?.openEditCardCreator(for: c)
    }

    @objc private func contextMenuStartChat(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let c = items.first(where: { $0.id == id }) else { return }
        AppState.shared.newChat(withCharacter: c)
        view.window?.close()
    }

    @objc private func contextMenuDelete(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? UUID,
              let c = items.first(where: { $0.id == id }) else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(c.name)\"?"
        alert.informativeText = "Chats that referenced this card will keep their history but lose the link."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppState.shared.deleteCharacter(id: id)
        }
    }

    @objc private func deleteSelection() {
        guard let c = selectedCharacter() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete \"\(c.name)\"?"
        alert.informativeText = "Chats that referenced this card will keep their history but lose the link."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppState.shared.deleteCharacter(id: c.id)
        }
    }

    private func presentImportError(_ error: Error, source: String) {
        let alert = NSAlert()
        alert.messageText = "Couldn't import \(source)"
        alert.informativeText = friendlyMessage(for: error)
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func friendlyMessage(for error: Error) -> String {
        if let e = error as? CharacterCardImporter.ImportError {
            switch e {
            case .fileTooLarge(let bytes):
                let mb = Double(bytes) / 1_048_576
                return String(format: "File is %.1f MB; the import cap is 2 MB.", mb)
            case .unrecognizedExtension(let ext):
                return "Unsupported file type \".\(ext)\". Use .png or .json."
            case .notAPNG:
                return "That file isn't a PNG."
            case .missingCharaChunk:
                return "PNG has no character data (missing the `chara` tEXt chunk). Make sure it's a SillyTavern v2 card."
            case .invalidBase64:
                return "Character data is corrupted (not valid base64)."
            case .invalidJSON(let detail):
                return "Character JSON is malformed: \(detail)"
            case .unsupportedSpec(let spec):
                return "This card uses \(spec); only chara_card_v2 is supported."
            case .missingName:
                return "Card has no name field."
            }
        }
        return error.localizedDescription
    }
}

extension CharactersTabViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: CharacterCardView.reuseId, for: indexPath)
        if let card = item as? CharacterCardView, indexPath.item < items.count {
            card.configure(with: items[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateButtons()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateButtons()
    }
}

// MARK: - Personas tab

final class PersonasTabViewController: NSViewController {

    private let newButton = NSButton(title: "+ New Persona", target: nil, action: nil)
    private let editButton = NSButton(title: "Edit", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let detailLabel = NSTextField(wrappingLabelWithString: "")
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let layout = NSCollectionViewFlowLayout()

    private var items: [Persona] = []

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        newButton.target = self
        newButton.action = #selector(newPersona)
        newButton.bezelStyle = .rounded
        newButton.translatesAutoresizingMaskIntoConstraints = false

        editButton.target = self
        editButton.action = #selector(editPersona)
        editButton.bezelStyle = .rounded
        editButton.isEnabled = false
        editButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.target = self
        deleteButton.action = #selector(deletePersona)
        deleteButton.bezelStyle = .rounded
        deleteButton.isEnabled = false
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.font(11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.maximumNumberOfLines = 4
        detailLabel.translatesAutoresizingMaskIntoConstraints = false
        detailLabel.stringValue = "No selection."

        layout.itemSize = PersonaCardView.itemSize
        layout.minimumInteritemSpacing = 12
        layout.minimumLineSpacing = 12
        layout.sectionInset = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.clear]
        collectionView.register(PersonaCardView.self, forItemWithIdentifier: PersonaCardView.reuseId)

        scrollView.documentView = collectionView
        scrollView.hasVerticalScroller = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(newButton)
        v.addSubview(editButton)
        v.addSubview(deleteButton)
        v.addSubview(scrollView)
        v.addSubview(detailLabel)

        NSLayoutConstraint.activate([
            newButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            newButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),

            editButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            editButton.leadingAnchor.constraint(equalTo: newButton.trailingAnchor, constant: 8),

            deleteButton.centerYAnchor.constraint(equalTo: newButton.centerYAnchor),
            deleteButton.leadingAnchor.constraint(equalTo: editButton.trailingAnchor, constant: 8),

            scrollView.topAnchor.constraint(equalTo: newButton.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),

            detailLabel.topAnchor.constraint(equalTo: scrollView.bottomAnchor, constant: 8),
            detailLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            detailLabel.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            detailLabel.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.personasChanged, object: nil)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewWillAppear() {
        super.viewWillAppear()
        reload()
    }

    @objc private func reload() {
        items = AppState.shared.personas
        collectionView.reloadData()
        updateButtons()
    }

    private func selectedPersona() -> Persona? {
        guard let path = collectionView.selectionIndexPaths.first,
              path.item < items.count else { return nil }
        return items[path.item]
    }

    private func updateButtons() {
        let selected = selectedPersona()
        editButton.isEnabled = selected != nil
        deleteButton.isEnabled = selected != nil
        if let p = selected {
            let trimmed = p.description.trimmingCharacters(in: .whitespacesAndNewlines)
            detailLabel.stringValue = trimmed.isEmpty ? p.name : "\(p.name)\n\(trimmed.prefix(280))"
        } else {
            detailLabel.stringValue = "No selection."
        }
    }

    @objc private func newPersona() {
        let editor = PersonaEditController(persona: nil) { result in
            AppState.shared.savePersona(result)
        }
        presentAsSheet(editor)
    }

    @objc private func editPersona() {
        guard let p = selectedPersona() else { return }
        let editor = PersonaEditController(persona: p) { updated in
            AppState.shared.savePersona(updated)
        }
        presentAsSheet(editor)
    }

    @objc private func deletePersona() {
        guard let p = selectedPersona() else { return }
        let alert = NSAlert()
        alert.messageText = "Delete persona \"\(p.name)\"?"
        alert.informativeText = "Chats that used this persona will fall back to anonymous."
        alert.addButton(withTitle: "Delete")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            AppState.shared.deletePersona(id: p.id)
        }
    }
}

extension PersonasTabViewController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        let item = collectionView.makeItem(withIdentifier: PersonaCardView.reuseId, for: indexPath)
        if let card = item as? PersonaCardView, indexPath.item < items.count {
            card.configure(with: items[indexPath.item])
        }
        return item
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        updateButtons()
    }

    func collectionView(_ collectionView: NSCollectionView, didDeselectItemsAt indexPaths: Set<IndexPath>) {
        updateButtons()
    }
}

// MARK: - Persona edit sheet

/// Tiny sheet for creating or editing a `Persona`. Two text controls — name
/// (single-line, 60-char soft cap) and description (multiline) — plus
/// Save / Cancel. The committed persona is delivered through `onSave`; the
/// caller decides what to do with it (typically `AppState.savePersona`).
final class PersonaEditController: NSViewController {
    private let nameField = NSTextField()
    private let descriptionView = NSTextView()
    private let descriptionScroll = NSScrollView()
    private let saveButton = NSButton(title: "Save", target: nil, action: nil)
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let original: Persona?
    private let onSave: (Persona) -> Void

    init(persona: Persona?, onSave: @escaping (Persona) -> Void) {
        self.original = persona
        self.onSave = onSave
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 460, height: 360))
        v.wantsLayer = true
        self.view = v

        let nameLabel = NSTextField(labelWithString: "Name:")
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        nameField.translatesAutoresizingMaskIntoConstraints = false
        nameField.placeholderString = "e.g. Kira"

        let descLabel = NSTextField(labelWithString: "Description (injected each turn):")
        descLabel.translatesAutoresizingMaskIntoConstraints = false

        descriptionView.isRichText = false
        descriptionView.font = Theme.font(12)
        descriptionView.textContainerInset = NSSize(width: 4, height: 4)
        descriptionView.isAutomaticQuoteSubstitutionEnabled = false
        descriptionView.isAutomaticDashSubstitutionEnabled = false
        descriptionView.isAutomaticTextReplacementEnabled = false
        descriptionScroll.documentView = descriptionView
        descriptionScroll.hasVerticalScroller = true
        descriptionScroll.borderType = .lineBorder
        descriptionScroll.translatesAutoresizingMaskIntoConstraints = false

        saveButton.target = self
        saveButton.action = #selector(save)
        saveButton.keyEquivalent = "\r"
        saveButton.translatesAutoresizingMaskIntoConstraints = false
        cancelButton.target = self
        cancelButton.action = #selector(cancel)
        cancelButton.keyEquivalent = "\u{1b}"
        cancelButton.translatesAutoresizingMaskIntoConstraints = false

        v.addSubview(nameLabel)
        v.addSubview(nameField)
        v.addSubview(descLabel)
        v.addSubview(descriptionScroll)
        v.addSubview(saveButton)
        v.addSubview(cancelButton)

        NSLayoutConstraint.activate([
            nameLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 16),
            nameLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),

            nameField.centerYAnchor.constraint(equalTo: nameLabel.centerYAnchor),
            nameField.leadingAnchor.constraint(equalTo: nameLabel.trailingAnchor, constant: 8),
            nameField.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),

            descLabel.topAnchor.constraint(equalTo: nameField.bottomAnchor, constant: 16),
            descLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),

            descriptionScroll.topAnchor.constraint(equalTo: descLabel.bottomAnchor, constant: 6),
            descriptionScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 16),
            descriptionScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),
            descriptionScroll.bottomAnchor.constraint(equalTo: saveButton.topAnchor, constant: -16),

            saveButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -16),
            saveButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -16),

            cancelButton.centerYAnchor.constraint(equalTo: saveButton.centerYAnchor),
            cancelButton.trailingAnchor.constraint(equalTo: saveButton.leadingAnchor, constant: -8),
        ])

        if let original = original {
            nameField.stringValue = original.name
            descriptionView.string = original.description
        }
    }

    @objc private func save() {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            NSSound.beep()
            view.window?.makeFirstResponder(nameField)
            return
        }
        let description = descriptionView.string
        let persona: Persona
        if var existing = original {
            existing.name = name
            existing.description = description
            persona = existing
        } else {
            persona = Persona(name: name, description: description)
        }
        onSave(persona)
        dismiss(nil)
    }

    @objc private func cancel() {
        dismiss(nil)
    }
}


// MARK: - LibraryCollectionView (Phase 9 §5.3d.1)

/// `NSCollectionView` subclass that vends per-item right-click context
/// menus and detects double-click on cards. Both behaviors flow back to
/// the parent `CharactersTabViewController` through closures so the
/// view-model logic stays in the controller and the subclass stays
/// presentation-only.
final class LibraryCollectionView: NSCollectionView {

    /// Build a context menu for the item at `indexPath` (or for empty space
    /// when `indexPath` is nil). The collection view returns the menu;
    /// AppKit handles the rest.
    var contextMenuProvider: ((IndexPath?) -> NSMenu?)?

    /// Fired when the user double-clicks on an item.
    var doubleClickHandler: ((IndexPath) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let pointInView = convert(event.locationInWindow, from: nil)
        let path = indexPathForItem(at: pointInView)
        return contextMenuProvider?(path)
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            let pointInView = convert(event.locationInWindow, from: nil)
            if let path = indexPathForItem(at: pointInView) {
                doubleClickHandler?(path)
                return
            }
        }
        super.mouseDown(with: event)
    }
}
