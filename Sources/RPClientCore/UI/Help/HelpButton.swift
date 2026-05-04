import AppKit

/// Small `(?)` button used in inspector pane headers (and later, settings
/// tabs) to open the help window scrolled to a specific page. Centralised so
/// the visual treatment stays uniform and call sites stay one line.
///
/// Wiring goes through `AppDelegate.openHelp(pageId:anchor:)` rather than a
/// direct dependency on `HelpWindowController` — pane code shouldn't need to
/// know about window-controller lifetime.
final class HelpButton: NSButton {
    private let pageId: String
    private let anchor: String?

    init(pageId: String, anchor: String? = nil, tooltip: String = "Open help for this pane") {
        self.pageId = pageId
        self.anchor = anchor
        super.init(frame: .zero)
        image = NSImage(
            systemSymbolName: "questionmark.circle",
            accessibilityDescription: tooltip
        )
        imagePosition = .imageOnly
        imageScaling = .scaleProportionallyDown
        bezelStyle = .inline
        isBordered = false
        contentTintColor = .secondaryLabelColor
        target = self
        action = #selector(tapped)
        toolTip = tooltip
        translatesAutoresizingMaskIntoConstraints = false
        widthAnchor.constraint(equalToConstant: 16).isActive = true
        heightAnchor.constraint(equalToConstant: 16).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    @objc private func tapped() {
        (NSApp.delegate as? AppDelegate)?.openHelp(pageId: pageId, anchor: anchor)
    }
}
