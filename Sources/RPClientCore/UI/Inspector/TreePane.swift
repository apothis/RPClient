import AppKit

/// Phase 7 §3.5 — Tree inspector tab. Renders the chat's full turn tree
/// as a layered top-down minimap. Active path is drawn with a thicker
/// accent edge and the active leaf glows. Click any node to switch to
/// that branch (drilling to its descendant leaf via the existing
/// `switchBranch` rule). Trackpad pan/zoom on the canvas; a "Fit" button
/// resets the view to the natural extent.
///
/// Layout is computed by `MinimapLayout` (pure, tested separately). This
/// file is just NSView mechanics: rendering, hit-testing, and gesture
/// glue. Falls back to an empty-state copy when the chat is linear or
/// missing — a single column of boxes adds no information beyond the
/// chat view itself.
final class TreePane: NSViewController {
    private let canvas = MinimapCanvas()
    private let scrollView = NSScrollView()
    private let emptyLabel = NSTextField(labelWithString:
        "No branches yet — fork a reply with ⌘B to grow the tree.")
    private let fitButton = NSButton(title: "Fit", target: nil, action: nil)

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

        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.4
        scrollView.maxMagnification = 3.0
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = canvas
        v.addSubview(scrollView)

        fitButton.bezelStyle = .rounded
        fitButton.target = self
        fitButton.action = #selector(fitTapped)
        fitButton.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(fitButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: v.topAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            scrollView.bottomAnchor.constraint(equalTo: fitButton.topAnchor, constant: -8),

            fitButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            fitButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(handleChatSwitch),
                       name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(handleTreeChange),
                       name: AppNotification.chatTreeChanged, object: nil)
        rebuild(preserveZoom: false)
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func handleTreeChange() {
        // Rebuild without resetting magnification — the user's zoom level
        // should persist through forks/switches.
        rebuild(preserveZoom: true)
    }

    @objc private func handleChatSwitch() {
        rebuild(preserveZoom: false)
    }

    private func rebuild(preserveZoom: Bool) {
        guard let chat = AppState.shared.currentChat else {
            canvas.update(chat: nil)
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }

        let leafCount = chat.leaves.count
        guard chat.turns.count >= 2, leafCount > 1 else {
            // Linear chat — minimap adds nothing.
            canvas.update(chat: nil)
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        scrollView.isHidden = false

        canvas.update(chat: chat)
        if !preserveZoom {
            scrollView.magnification = 1.0
        }
    }

    @objc private func fitTapped() {
        let bounds = canvas.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let viewport = scrollView.contentView.bounds
        let xRatio = viewport.width / bounds.width
        let yRatio = viewport.height / bounds.height
        let fit = min(xRatio, yRatio, scrollView.maxMagnification)
        let clamped = max(scrollView.minMagnification, fit)
        scrollView.magnification = clamped
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }
}

/// The actual rendered surface. Owns the cached layout dictionary and
/// the click-hit-testing logic so the parent view-controller doesn't
/// have to know about CoreGraphics geometry.
private final class MinimapCanvas: NSView {
    private var chat: Chat?
    private var positions: [UUID: CGPoint] = [:]
    private var activeEdges: Set<MinimapEdge> = []

    /// Per-row vertical step in chat-coords. Tweakable; matches what
    /// reads as "comfortably skimmable" against the inspector pane width.
    private let rowHeight: CGFloat = 56
    /// Per-leaf horizontal step. Wide enough that the 24-char preview
    /// label fits without overlapping the next leaf.
    private let colWidth: CGFloat = 110
    /// Box dimensions for a node; box is centered on the layout point.
    private let boxWidth: CGFloat = 96
    private let boxHeight: CGFloat = 36
    /// Padding around the layout extent so boxes near the edge don't get
    /// clipped at the scroll view boundary.
    private let canvasPadding: CGFloat = 24

    override var isFlipped: Bool { true }

    func update(chat: Chat?) {
        self.chat = chat
        guard let chat else {
            positions = [:]
            activeEdges = []
            frame = .zero
            needsDisplay = true
            return
        }
        positions = MinimapLayout.layout(chat: chat, rowHeight: rowHeight, colWidth: colWidth)
        activeEdges = MinimapLayout.activeEdges(chat: chat)

        // Compute canvas size from the layout extent + padding + half a box
        // on each side (because boxes are drawn centered on their points).
        let xs = positions.values.map(\.x)
        let ys = positions.values.map(\.y)
        let maxX = xs.max() ?? 0
        let maxY = ys.max() ?? 0
        let w = maxX + boxWidth + 2 * canvasPadding
        let h = maxY + boxHeight + 2 * canvasPadding
        frame = NSRect(x: 0, y: 0, width: w, height: h)
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let chat else { return }
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let activeLeafId = chat.activePath.last
        let activePathSet = Set(chat.activePath)

        // Edges first so boxes draw on top.
        ctx.setLineCap(.round)
        for t in chat.turns {
            guard let pid = t.parentId,
                  let cp = position(forTurnId: t.id),
                  let pp = position(forTurnId: pid) else { continue }
            let isActive = activeEdges.contains(MinimapEdge(parent: pid, child: t.id))
            ctx.setStrokeColor((isActive ? NSColor.controlAccentColor
                                         : NSColor.tertiaryLabelColor).cgColor)
            ctx.setLineWidth(isActive ? 2.5 : 1.0)
            ctx.beginPath()
            ctx.move(to: pp)
            ctx.addLine(to: cp)
            ctx.strokePath()
        }

        // Boxes.
        for t in chat.turns {
            guard let p = position(forTurnId: t.id) else { continue }
            drawBox(in: ctx, at: p, turn: t,
                    isActiveLeaf: t.id == activeLeafId,
                    isOnActivePath: activePathSet.contains(t.id))
        }
    }

    private func position(forTurnId id: UUID) -> CGPoint? {
        guard let p = positions[id] else { return nil }
        return CGPoint(x: p.x + canvasPadding + boxWidth / 2,
                       y: p.y + canvasPadding + boxHeight / 2)
    }

    private func drawBox(in ctx: CGContext, at center: CGPoint, turn: Turn,
                         isActiveLeaf: Bool, isOnActivePath: Bool) {
        let rect = NSRect(x: center.x - boxWidth / 2,
                          y: center.y - boxHeight / 2,
                          width: boxWidth, height: boxHeight)
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        // Background — accent on active leaf, lighter accent on path,
        // window background otherwise.
        let bg: NSColor
        if isActiveLeaf {
            bg = NSColor.controlAccentColor.withAlphaComponent(0.85)
        } else if isOnActivePath {
            bg = NSColor.controlAccentColor.withAlphaComponent(0.18)
        } else {
            bg = NSColor.controlBackgroundColor
        }
        bg.setFill()
        path.fill()
        // Border — accent on path, secondary otherwise.
        (isOnActivePath ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
        path.lineWidth = isActiveLeaf ? 1.5 : 1.0
        path.stroke()

        // Label: role glyph + first-line preview, truncated to ~24 chars.
        let glyph = turn.role == .user ? "👤" : "✦"
        let preview = firstNonBlankLine(of: turn.text) ?? "—"
        let truncated = preview.count > 24
            ? String(preview.prefix(24)) + "…"
            : preview
        let text = "\(glyph) \(truncated)"
        let textColor: NSColor = isActiveLeaf ? .white : .labelColor
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 10, weight: isActiveLeaf ? .semibold : .regular),
            .foregroundColor: textColor
        ]
        let attr = NSAttributedString(string: text, attributes: attrs)
        let textRect = rect.insetBy(dx: 6, dy: 4)
        attr.draw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func firstNonBlankLine(of text: String) -> String? {
        text.components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }?
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Click → switch branch

    override func mouseDown(with event: NSEvent) {
        guard let chat else { return }
        let pt = convert(event.locationInWindow, from: nil)
        for t in chat.turns {
            guard let center = position(forTurnId: t.id) else { continue }
            let rect = NSRect(x: center.x - boxWidth / 2,
                              y: center.y - boxHeight / 2,
                              width: boxWidth, height: boxHeight)
            if rect.contains(pt) {
                AppState.shared.switchBranch(to: t.id)
                return
            }
        }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
