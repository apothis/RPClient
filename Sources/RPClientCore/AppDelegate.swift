import AppKit
import UniformTypeIdentifiers

public final class AppDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow!
    private var splitVC: NSSplitViewController!
    private var settingsWC: SettingsWindowController?
    private var factEvalWC: FactExtractorEvalWindow?
    private var libraryWC: LibraryWindowController?
    private var helpWC: HelpWindowController?

    public override init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        _ = AppState.shared

        buildMenu()

        let frame = NSRect(x: 0, y: 0, width: 1100, height: 720)
        window = NSWindow(
            contentRect: frame,
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "RPClient"
        window.center()
        window.setFrameAutosaveName("RPClient.MainWindow")

        let sidebar = SidebarViewController()
        let chat = ChatViewController()
        let inspector = InspectorViewController()

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 180
        sidebarItem.maximumThickness = 320

        let chatItem = NSSplitViewItem(viewController: chat)
        chatItem.minimumThickness = 400

        let inspectorItem = NSSplitViewItem(viewController: inspector)
        inspectorItem.minimumThickness = 280
        inspectorItem.maximumThickness = 900
        inspectorItem.canCollapse = true
        // Hold priority higher than the chat pane so divider drags persist
        // after release. Without this, NSSplitView uses the chat's stronger
        // hold to "settle" the inspector back to its previous width.
        inspectorItem.holdingPriority = NSLayoutConstraint.Priority(rawValue: 251)

        splitVC = NSSplitViewController()
        splitVC.addSplitViewItem(sidebarItem)
        splitVC.addSplitViewItem(chatItem)
        splitVC.addSplitViewItem(inspectorItem)

        window.contentViewController = splitVC
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    public func applicationWillTerminate(_ notification: Notification) {
        AppState.shared.speaker.stop()
    }

    private func buildMenu() {
        let main = NSMenu()

        let appMenuItem = NSMenuItem()
        main.addItem(appMenuItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(
            title: "About RPClient",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Settings…",
            action: #selector(showSettings),
            keyEquivalent: ","))
        appMenu.addItem(NSMenuItem.separator())
        appMenu.addItem(NSMenuItem(
            title: "Hide RPClient",
            action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(
            title: "Quit RPClient",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"))
        appMenuItem.submenu = appMenu

        let fileMenuItem = NSMenuItem()
        main.addItem(fileMenuItem)
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(NSMenuItem(
            title: "New Chat",
            action: #selector(newChat),
            keyEquivalent: "n"))
        fileMenu.addItem(NSMenuItem(
            title: "New Chat with Character…",
            action: #selector(newChatWithCharacter),
            keyEquivalent: "N"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Import Character…",
            action: #selector(importCharacter),
            keyEquivalent: "o"))
        let libraryItem = NSMenuItem(
            title: "Show Library",
            action: #selector(showLibrary),
            keyEquivalent: "L")
        libraryItem.keyEquivalentModifierMask = [.command, .shift]
        fileMenu.addItem(libraryItem)
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Reload Server Info",
            action: #selector(reloadServer),
            keyEquivalent: "r"))
        fileMenu.addItem(NSMenuItem.separator())
        fileMenu.addItem(NSMenuItem(
            title: "Summarize Now",
            action: #selector(summarizeNow),
            keyEquivalent: "S"))
        fileMenuItem.submenu = fileMenu

        let viewMenuItem = NSMenuItem()
        main.addItem(viewMenuItem)
        let viewMenu = NSMenu(title: "View")
        viewMenu.addItem(NSMenuItem(
            title: "Toggle Inspector",
            action: #selector(toggleInspector),
            keyEquivalent: "i"))
        viewMenu.addItem(NSMenuItem.separator())
        // Swipe paging on the trailing assistant turn. Action is `nil` so the
        // selector travels up the responder chain to ChatViewController.
        let prevVariant = NSMenuItem(
            title: "Previous Variant",
            action: Selector(("previousVariant:")),
            keyEquivalent: String(format: "%C", 0xF702))   // NSLeftArrowFunctionKey
        prevVariant.keyEquivalentModifierMask = .command
        viewMenu.addItem(prevVariant)
        let nextVariant = NSMenuItem(
            title: "Next Variant",
            action: Selector(("nextVariant:")),
            keyEquivalent: String(format: "%C", 0xF703))   // NSRightArrowFunctionKey
        nextVariant.keyEquivalentModifierMask = .command
        viewMenu.addItem(nextVariant)
        viewMenuItem.submenu = viewMenu

        let editMenuItem = NSMenuItem()
        main.addItem(editMenuItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(
            title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        editMenu.addItem(NSMenuItem(
            title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(
            title: "Cut",
            action: #selector(NSText.cut(_:)),
            keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(
            title: "Copy",
            action: #selector(NSText.copy(_:)),
            keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(
            title: "Paste",
            action: #selector(NSText.paste(_:)),
            keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(
            title: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"))
        editMenuItem.submenu = editMenu

        let debugMenuItem = NSMenuItem()
        main.addItem(debugMenuItem)
        let debugMenu = NSMenu(title: "Debug")
        debugMenu.addItem(NSMenuItem(
            title: "Fact extraction (eval)…",
            action: #selector(showFactEval),
            keyEquivalent: ""))
        debugMenuItem.submenu = debugMenu

        let helpMenuItem = NSMenuItem()
        main.addItem(helpMenuItem)
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(NSMenuItem(
            title: "RPClient Help",
            action: #selector(showHelp),
            keyEquivalent: "?"))
        helpMenuItem.submenu = helpMenu
        // AppKit auto-routes ⌘? and the "Search" Help menu integration when
        // the menu has the helpMenu role.
        NSApp.helpMenu = helpMenu

        NSApp.mainMenu = main
    }

    @objc private func showFactEval() {
        if factEvalWC == nil {
            factEvalWC = FactExtractorEvalWindow()
        }
        factEvalWC?.showWindow(nil)
        factEvalWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func showSettings() {
        if settingsWC == nil {
            settingsWC = SettingsWindowController()
        }
        settingsWC?.showWindow(nil)
        settingsWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func newChat() {
        AppState.shared.newChat()
    }

    @objc private func newChatWithCharacter() {
        let characters = AppState.shared.characters
        guard !characters.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "No characters yet"
            alert.informativeText = "Import a character card first (File → Import Character…)."
            alert.addButton(withTitle: "Open Library")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { showLibrary() }
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
        // Surface anchored under the title bar of the main window so the user
        // sees it pop where the cursor isn't required.
        let location = NSPoint(x: 20, y: 20)
        let anchor = window.contentView ?? NSView()
        menu.popUp(positioning: nil, at: location, in: anchor)
    }

    @objc private func startChatFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let id = UUID(uuidString: raw),
              let character = AppState.shared.character(id: id) else { return }
        AppState.shared.newChat(withCharacter: character)
    }

    @objc private func importCharacter() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.png, .json]
        panel.message = "Choose a SillyTavern v2 character card (.png or .json)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            _ = try AppState.shared.importCharacter(from: url)
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't import \(url.lastPathComponent)"
            alert.informativeText = String(describing: error)
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    @objc private func showLibrary() {
        if libraryWC == nil {
            libraryWC = LibraryWindowController()
        }
        libraryWC?.showWindow(nil)
        libraryWC?.window?.makeKeyAndOrderFront(nil)
    }

    @objc private func reloadServer() {
        AppState.shared.refreshServerInfo()
    }

    @objc private func summarizeNow() {
        AppState.shared.runSummarizer()
    }

    @objc private func toggleInspector() {
        guard let item = splitVC.splitViewItems.last else { return }
        item.animator().isCollapsed.toggle()
    }

    @objc private func showHelp() {
        if helpWC == nil {
            helpWC = HelpWindowController()
        }
        helpWC?.showWindow(nil)
        helpWC?.window?.makeKeyAndOrderFront(nil)
    }

    /// Entry point for inspector pane "?" buttons (later slices). Opens the
    /// help window scrolled to a specific page and optional anchor. Renamed
    /// from the menu's `showHelp` to keep `#selector(showHelp)` unambiguous.
    public func openHelp(pageId: String, anchor: String? = nil) {
        if helpWC == nil {
            helpWC = HelpWindowController()
        }
        helpWC?.show(pageId: pageId, anchor: anchor)
    }
}
