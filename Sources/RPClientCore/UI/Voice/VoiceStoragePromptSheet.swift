import AppKit

/// First-run sheet that asks the user where Kokoro voice assets should be
/// stored (Phase 6 §7.1g). Fired by `SettingsWindowController` after a save
/// when `VoiceStoragePrompt.shouldPrompt(old:new:)` returns true, and from
/// the "Change location…" button in the Settings storage row.
///
/// UX:
///   - Save with a scout option selected → completion(option.path).
///   - Selecting "Choose another folder…" in the popup fires `NSOpenPanel`
///     immediately (no Save click required) — picking a folder there
///     completes the sheet; cancelling the panel cancels the whole flow.
///   - Cancel → completion(nil). Caller decides what to do (the first-run
///     flow rolls voiceEnabled back to false; Change… is a no-op).
///
/// Implementation note: a class rather than an enum so the popup's
/// `target/action` can fire on a live instance. Each `present` creates a
/// self-retaining sheet coordinator; it removes itself from `active` once
/// completion has fired.
final class VoiceStoragePromptSheet: NSObject {

    /// Sentinel for the "Choose another folder…" entry in the popup.
    fileprivate static let chooseTag: Int = -1

    private static var active: [VoiceStoragePromptSheet] = []

    private weak var parentWindow: NSWindow?
    private let options: [VoiceStorageScout.VoiceStorageOption]
    private let alert: NSAlert
    private let popup: NSPopUpButton
    private var completion: ((URL?) -> Void)?
    /// Set when the popup-action route has taken over (i.e. the user picked
    /// "Choose another folder…"). The alert's own completion handler must
    /// then bow out so it doesn't double-fire `completion(nil)`.
    private var consumedByPopup: Bool = false

    static func present(
        over window: NSWindow,
        options: [VoiceStorageScout.VoiceStorageOption] = VoiceStorageScout.liveOptions(),
        completion: @escaping (URL?) -> Void
    ) {
        let sheet = VoiceStoragePromptSheet(
            window: window, options: options, completion: completion
        )
        active.append(sheet)
        sheet.show()
    }

    private init(window: NSWindow,
                 options: [VoiceStorageScout.VoiceStorageOption],
                 completion: @escaping (URL?) -> Void) {
        self.parentWindow = window
        self.options = options
        self.completion = completion
        self.alert = NSAlert()
        self.popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        super.init()
    }

    private func show() {
        guard let window = parentWindow else {
            finish(with: nil)
            return
        }

        alert.messageText = "Where should voice models be stored?"
        alert.informativeText = """
            The Kokoro base model is about 325 MB, with each voice adding \
            roughly 500 KB. Pick a location with enough free space — an \
            external SSD is ideal if you have one mounted.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        for (idx, opt) in options.enumerated() {
            let item = NSMenuItem(title: opt.label, action: nil, keyEquivalent: "")
            item.tag = idx
            popup.menu?.addItem(item)
        }
        if !options.isEmpty {
            popup.menu?.addItem(NSMenuItem.separator())
        }
        let chooseItem = NSMenuItem(
            title: "Choose another folder…", action: nil, keyEquivalent: ""
        )
        chooseItem.tag = Self.chooseTag
        popup.menu?.addItem(chooseItem)
        popup.selectItem(at: 0)
        popup.target = self
        popup.action = #selector(popupSelectionChanged(_:))
        alert.accessoryView = popup

        alert.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            if self.consumedByPopup { return }
            switch response {
            case .alertFirstButtonReturn:
                self.handleSave()
            default:
                self.finish(with: nil)
            }
        }
    }

    private func handleSave() {
        let tag = popup.selectedItem?.tag ?? 0
        if tag == Self.chooseTag {
            // User clicked Save with "Choose…" selected (didn't go via the
            // popup-action shortcut). Treat the same way: fire the panel.
            presentOpenPanel()
        } else if tag >= 0 && tag < options.count {
            finish(with: options[tag].path)
        } else {
            finish(with: nil)
        }
    }

    @objc private func popupSelectionChanged(_ sender: NSPopUpButton) {
        guard sender.selectedItem?.tag == Self.chooseTag else { return }
        guard let window = parentWindow else { return }
        // Take over the lifecycle: dismiss the alert sheet, then immediately
        // show NSOpenPanel as a sheet on the same window.
        consumedByPopup = true
        window.endSheet(alert.window, returnCode: .cancel)
        DispatchQueue.main.async { [weak self] in
            self?.presentOpenPanel()
        }
    }

    private func presentOpenPanel() {
        guard let window = parentWindow else {
            finish(with: nil)
            return
        }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.showsHiddenFiles = false
        panel.message = "Pick a folder for Kokoro voice models. Use the New Folder button to create one."
        panel.prompt = "Choose"
        panel.beginSheetModal(for: window) { [weak self] response in
            if response == .OK, let url = panel.url {
                self?.finish(with: url)
            } else {
                self?.finish(with: nil)
            }
        }
    }

    private func finish(with url: URL?) {
        let cb = completion
        completion = nil
        cb?(url)
        Self.active.removeAll { $0 === self }
    }
}
