import AppKit

/// Phase 7 §3.3b — popover content for the gutter branch glyph. Lists the
/// siblings of a forked turn (first-line preview + relative timestamp) and
/// invokes `onPick` when the user selects one. ChatViewController constructs
/// it on glyph click and routes the pick into `AppState.switchBranch(to:)`.
final class SiblingPickerViewController: NSViewController {
    private let siblings: [Turn]
    private let activeId: UUID
    private let onPick: (UUID) -> Void

    init(siblings: [Turn], activeId: UUID, onPick: @escaping (UUID) -> Void) {
        self.siblings = siblings
        self.activeId = activeId
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 6, right: 6)
        stack.translatesAutoresizingMaskIntoConstraints = false

        for s in siblings {
            stack.addArrangedSubview(makeRow(for: s))
        }

        let container = NSView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 240)
        ])
        view = container
    }

    private func makeRow(for sibling: Turn) -> NSView {
        let isActive = sibling.id == activeId
        let preview = sibling.text
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            ?? "—"
        let truncated = preview.count > 60
            ? String(preview.prefix(60)) + "…"
            : preview

        let title = NSTextField(labelWithString: (isActive ? "● " : "  ") + truncated)
        title.font = NSFont.systemFont(ofSize: 12)
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        let stamp = NSTextField(labelWithString: SiblingPickerViewController.relativeStamp(sibling.ts))
        stamp.font = NSFont.systemFont(ofSize: 10)
        stamp.textColor = .secondaryLabelColor

        let v = NSStackView(views: [title, stamp])
        v.orientation = .vertical
        v.alignment = .leading
        v.spacing = 1
        v.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)

        // Wrap in a clickable button so the row reacts to mouse + obeys
        // standard hover highlighting through the button's tracking.
        let button = ClickableRow(siblingId: sibling.id, onPick: onPick)
        button.translatesAutoresizingMaskIntoConstraints = false
        v.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(v)
        NSLayoutConstraint.activate([
            v.topAnchor.constraint(equalTo: button.topAnchor),
            v.leadingAnchor.constraint(equalTo: button.leadingAnchor),
            v.trailingAnchor.constraint(equalTo: button.trailingAnchor),
            v.bottomAnchor.constraint(equalTo: button.bottomAnchor)
        ])
        return button
    }

    private static func relativeStamp(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}

private final class ClickableRow: NSView {
    private let siblingId: UUID
    private let onPick: (UUID) -> Void
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(siblingId: UUID, onPick: @escaping (UUID) -> Void) {
        self.siblingId = siblingId
        self.onPick = onPick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        let area = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) { onPick(siblingId) }

    override func updateLayer() {
        layer?.backgroundColor = isHovering
            ? NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
            : NSColor.clear.cgColor
    }
}
