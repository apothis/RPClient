import AppKit

/// Phase 7 §3.4 — Branches inspector tab. Lists every leaf in the chat's
/// turn tree as a clickable row: the active branch is pinned to the top
/// with a `●` marker; the rest sort by leaf timestamp descending. Each
/// row carries a first-line preview and a "forked at TN" subtitle where
/// TN is the divergence point's position on the active path.
///
/// Subscribes to `currentChatChanged` (rebuild on chat switch) and the
/// new `chatTreeChanged` (rebuild on fork / branch switch / turn delete)
/// — narrower than `chatUpdated` so this pane doesn't redraw on every
/// streamed token.
final class BranchesPane: NSViewController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No branches yet — fork a reply with ⌘B.")

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        emptyLabel.font = Theme.font(12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        v.addSubview(emptyLabel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: v.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: v.bottomAnchor),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild),
                       name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(rebuild),
                       name: AppNotification.chatTreeChanged, object: nil)
        rebuild()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func rebuild() {
        for sub in stack.arrangedSubviews {
            stack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        guard let chat = AppState.shared.currentChat else {
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }

        let leaves = chat.leaves
        // A "branch" is meaningful only when there's > 1 leaf. A linear
        // chat with one leaf doesn't earn the pane's real estate.
        guard leaves.count > 1 else {
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        scrollView.isHidden = false

        let activeLeafId = chat.activePath.last
        // Active branch first; the rest by leaf ts descending (most-recent
        // forks float to the top, matching how users discover them).
        let sorted = leaves.sorted { l, r in
            if l.id == activeLeafId { return true }
            if r.id == activeLeafId { return false }
            return l.ts > r.ts
        }

        for leaf in sorted {
            stack.addArrangedSubview(makeRow(for: leaf, in: chat, isActive: leaf.id == activeLeafId))
        }
    }

    private func makeRow(for leaf: Turn, in chat: Chat, isActive: Bool) -> NSView {
        let preview = firstNonBlankLine(of: leaf.text) ?? "—"
        let truncatedPreview = preview.count > 70
            ? String(preview.prefix(70)) + "…"
            : preview

        let title = NSTextField(labelWithString: (isActive ? "● " : "  ") + truncatedPreview)
        title.font = Theme.font(12, weight: isActive ? .semibold : .regular)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1

        let divergenceLabel: String
        if let divId = chat.divergencePoint(of: leaf.id, against: chat.activePath),
           let divPos = chat.activePosition(of: divId) {
            divergenceLabel = isActive
                ? "leaf at T\(chat.activePath.count) on the active path"
                : "forked at T\(divPos + 1)"
        } else {
            divergenceLabel = "off-path branch"
        }

        let subtitle = NSTextField(labelWithString: divergenceLabel)
        subtitle.font = Theme.font(10)
        subtitle.textColor = .secondaryLabelColor
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.maximumNumberOfLines = 1

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let row = ClickableBranchRow(leafId: leaf.id, isActive: isActive)
        row.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: row.topAnchor),
            stack.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: row.bottomAnchor)
        ])
        return row
    }

    private func firstNonBlankLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
    }
}

/// Click-and-hover behaviour for a Branches pane row. Active branches
/// don't react to clicks (no-op); inactive branches dispatch
/// `AppState.switchBranch(to:)` on click.
private final class ClickableBranchRow: NSView {
    private let leafId: UUID
    private let isActive: Bool
    private var isHovering = false {
        didSet { needsDisplay = true }
    }

    init(leafId: UUID, isActive: Bool) {
        self.leafId = leafId
        self.isActive = isActive
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
        translatesAutoresizingMaskIntoConstraints = false
    }

    required init?(coder: NSCoder) { nil }

    override func mouseEntered(with event: NSEvent) { isHovering = true }
    override func mouseExited(with event: NSEvent) { isHovering = false }
    override func mouseDown(with event: NSEvent) {
        guard !isActive else { return }
        AppState.shared.switchBranch(to: leafId)
    }

    override func updateLayer() {
        let bg: CGColor
        if isActive {
            bg = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
        } else if isHovering {
            bg = NSColor.selectedContentBackgroundColor.withAlphaComponent(0.25).cgColor
        } else {
            bg = NSColor.clear.cgColor
        }
        layer?.backgroundColor = bg
    }
}
