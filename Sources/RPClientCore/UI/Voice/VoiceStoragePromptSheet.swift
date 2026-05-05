import AppKit

/// First-run sheet that asks the user where Kokoro voice assets should be
/// stored (Phase 6 §7.1g). Fired by `SettingsWindowController` after a save
/// when `VoiceStoragePrompt.shouldPrompt(old:new:)` returns true. Lists
/// `VoiceStorageScout.liveOptions()` plus a "Choose…" escape hatch that
/// drops into an `NSOpenPanel`.
///
/// UX:
///   - Save with a scout option selected → completion(option.path).
///   - Save with "Choose…" selected → fire NSOpenPanel; completion(picked
///     URL) or completion(nil) if the user cancelled the open panel.
///   - Cancel → completion(nil). Caller rolls back `voiceEnabled` to false.
enum VoiceStoragePromptSheet {

    /// Sentinel for the "Choose…" entry in the accessory popup.
    private static let chooseTag: Int = -1

    static func present(
        over window: NSWindow,
        options: [VoiceStorageScout.VoiceStorageOption] = VoiceStorageScout.liveOptions(),
        completion: @escaping (URL?) -> Void
    ) {
        let alert = NSAlert()
        alert.messageText = "Where should voice models be stored?"
        alert.informativeText = """
            The Kokoro base model is about 325 MB, with each voice adding \
            roughly 500 KB. Pick a location with enough free space — an \
            external SSD is ideal if you have one mounted.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 26))
        for (idx, opt) in options.enumerated() {
            let item = NSMenuItem(title: opt.label, action: nil, keyEquivalent: "")
            item.tag = idx
            popup.menu?.addItem(item)
        }
        if !options.isEmpty {
            popup.menu?.addItem(NSMenuItem.separator())
        }
        let chooseItem = NSMenuItem(title: "Choose another folder…", action: nil, keyEquivalent: "")
        chooseItem.tag = chooseTag
        popup.menu?.addItem(chooseItem)
        popup.selectItem(at: 0)
        alert.accessoryView = popup

        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else {
                completion(nil)
                return
            }
            let tag = popup.selectedItem?.tag ?? 0
            if tag == chooseTag {
                presentOpenPanel(over: window, completion: completion)
            } else if tag >= 0 && tag < options.count {
                completion(options[tag].path)
            } else {
                completion(nil)
            }
        }
    }

    private static func presentOpenPanel(
        over window: NSWindow,
        completion: @escaping (URL?) -> Void
    ) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Pick a folder for Kokoro voice models. Use the New Folder button to create one."
        panel.prompt = "Choose"
        panel.showsHiddenFiles = false
        panel.beginSheetModal(for: window) { response in
            if response == .OK, let url = panel.url {
                completion(url)
            } else {
                completion(nil)
            }
        }
    }
}
