import AppKit

/// Phase 9 §5.3a — window controller for the Card Creator. Owns the
/// `NSWindow`, the root `CardCreatorViewController`, and the dirty-on-close
/// confirmation flow. Three constructors map to the three `DraftOrigin`
/// modes (V2_PHASE9_CARD_CREATOR §3.1):
///
///   • `init()` — create from scratch.
///   • `init(editing:)` — edit an existing Library card.
///   • `init(importing:)` — import-and-edit a freshly-imported card.
///
/// Window size: 920×720 default, 720×600 minimum. Title reflects the
/// active mode + draft state ("New Character" / "<name>" / "<name>
/// (Unsaved import)"). Closing a dirty draft on `.editing` or `.created`
/// prompts; closing on `.importing` prompts because the import has not yet
/// been committed and Cancel discards everything.
final class CardCreatorWindowController: NSWindowController, NSWindowDelegate {

    private let viewController: CardCreatorViewController
    private let draft: CharacterDraft

    convenience init() {
        self.init(draft: CharacterDraft.newCreate())
    }

    convenience init(editing character: Character) {
        let avatar = Storage.shared.loadCharacterAvatar(id: character.id)
        self.init(draft: CharacterDraft.editing(character, avatarPNG: avatar))
    }

    convenience init(importing result: CharacterCardImporter.Result) {
        self.init(draft: CharacterDraft.importing(result))
    }

    private init(draft: CharacterDraft) {
        self.draft = draft
        let vc = CardCreatorViewController(draft: draft)
        self.viewController = vc

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 920, height: 720),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.minSize = NSSize(width: 720, height: 600)
        window.contentViewController = vc
        window.setFrameAutosaveName("RPClient.CardCreatorWindow")

        super.init(window: window)
        window.delegate = self

        vc.onSave = { [weak self] _ in self?.close() }
        vc.onCancel = { [weak self] in self?.confirmAndCloseIfWanted() }
        vc.onDirtyChanged = { [weak self] in self?.refreshTitle() }

        refreshTitle()
        installMenuShortcuts()
    }

    required init?(coder: NSCoder) { fatalError() }

    // MARK: - Title

    private func refreshTitle() {
        let base: String
        switch draft.origin {
        case .created:
            base = draft.character.name.isEmpty ? "New Character" : draft.character.name
        case .editing:
            base = draft.character.name.isEmpty ? "Untitled" : draft.character.name
        case .importing:
            let name = draft.character.name.isEmpty ? "Imported Card" : draft.character.name
            base = "\(name)  (Unsaved import)"
        }
        window?.title = base
        window?.isDocumentEdited = draft.isDirty
    }

    // MARK: - Tab navigation shortcuts (Cmd-1 ... Cmd-7)

    private func installMenuShortcuts() {
        // The window-level Cmd-1..Cmd-7 are handled by overriding
        // performKeyEquivalent on the window or using a key-down monitor
        // scoped to the window. Cleanest: a local NSEvent monitor.
        guard let window = window else { return }
        NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] event in
            guard let self = self,
                  let window = window,
                  event.window === window,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
                  let chars = event.charactersIgnoringModifiers,
                  let digit = Int(chars),
                  digit >= 1 && digit <= 9 else {
                return event
            }
            self.viewController.selectTab(at: digit - 1)
            return nil
        }
    }

    // MARK: - Close handling

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard draft.isDirty else { return true }
        return confirmDiscardAndClose()
    }

    private func confirmAndCloseIfWanted() {
        if !draft.isDirty {
            close()
            return
        }
        if confirmDiscardAndClose() {
            close()
        }
    }

    private func confirmDiscardAndClose() -> Bool {
        let alert = NSAlert()
        switch draft.origin {
        case .importing:
            alert.messageText = "Discard imported card?"
            alert.informativeText = "The imported character has not been saved. Closing will discard it entirely."
        case .editing:
            alert.messageText = "Discard changes?"
            alert.informativeText = "Your edits to this character will not be saved."
        case .created:
            alert.messageText = "Discard new character?"
            alert.informativeText = "This character has not been saved. Closing will discard it."
        }
        alert.addButton(withTitle: "Discard")
        alert.addButton(withTitle: "Keep editing")
        alert.alertStyle = .warning
        return alert.runModal() == .alertFirstButtonReturn
    }
}
