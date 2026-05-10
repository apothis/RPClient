import AppKit

/// V2_UI_OVERHAUL §4.8.6 / §4.g.3 — composer pill row that
/// width-responsively switches between three layouts:
///   - `.inline`   (≥ 900pt): all pills on one horizontal row.
///   - `.wrap`     (700–899pt): pills greedy-flow into ≤ 2 rows.
///   - `.collapsed` (< 700pt): single `…` button → NSPopover with
///                  pills stacked vertically.
///
/// Uses manual frame-based layout so the geometry decisions stay
/// purely in [PillFlow](PillFlow.swift) (which is unit-tested via
/// `phase11PillFlowTests`). The pill views themselves are arbitrary
/// NSViews supplied by ChatViewController via `setPills(_:)`.
final class FlowPillRow: NSView, NSPopoverDelegate {
    private(set) var pills: [NSView] = []
    private(set) var mode: PillLayoutMode = .inline

    /// Tappable opener used in `.collapsed` mode and as a fallback in
    /// `.wrap` mode if pills overflow the two-row budget.
    private let overflowButton = NSButton()
    private var overflowPopover: NSPopover?

    private let pillSpacing: CGFloat = 8
    private let rowSpacing: CGFloat = 6

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        overflowButton.translatesAutoresizingMaskIntoConstraints = true
        overflowButton.bezelStyle = .inline
        overflowButton.isBordered = false
        overflowButton.imagePosition = .imageOnly
        overflowButton.image = NSImage(
            systemSymbolName: "ellipsis.circle",
            accessibilityDescription: "Show options"
        )
        overflowButton.target = self
        overflowButton.action = #selector(showOverflow)
        overflowButton.toolTip = "Show options"
        overflowButton.isHidden = true
        addSubview(overflowButton)
    }

    required init?(coder: NSCoder) { nil }

    /// V2_UI_OVERHAUL §4.g — install a fresh set of pills. Old pills
    /// are removed from the hierarchy; their owners (ChatViewController)
    /// retain them for later re-installation if needed. Triggers a
    /// re-layout in the current mode.
    func setPills(_ views: [NSView]) {
        // Detach old pills (some may also live inside the overflow
        // popover if the user had it open during a chat switch).
        for p in pills where p.superview != nil {
            p.removeFromSuperview()
        }
        overflowPopover?.close()
        overflowPopover = nil

        pills = views
        for p in pills {
            p.translatesAutoresizingMaskIntoConstraints = true
            addSubview(p)
        }
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    // MARK: - Layout

    override func layout() {
        super.layout()

        let target = PillFlow.mode(forWidth: bounds.width)
        if target != mode {
            // Mode flipped under live resize. Close any open overflow
            // popover first so it doesn't anchor to a button that's
            // about to become hidden again.
            overflowPopover?.close()
            DebugLog.shared.write(
                "[chat-pane] pillRow mode \(mode)→\(target) width=\(Int(bounds.width)) pills=\(pills.count)"
            )
            mode = target
            invalidateIntrinsicContentSize()
        }
        applyLayout()
    }

    private func applyLayout() {
        // Pills moved into the overflow popover get returned to self
        // when the popover closes (see `popoverWillClose`). If we land
        // here mid-flight, pull them back too.
        for p in pills where p.superview !== self {
            p.removeFromSuperview()
            p.translatesAutoresizingMaskIntoConstraints = true
            addSubview(p)
        }

        switch mode {
        case .inline:
            overflowButton.isHidden = true
            layoutInline()
        case .wrap:
            layoutWrap()
        case .collapsed:
            overflowButton.isHidden = false
            layoutCollapsed()
        }
    }

    private func layoutInline() {
        var x: CGFloat = 0
        for p in pills {
            p.isHidden = false
            let s = p.fittingSize
            let y = (bounds.height - s.height) / 2
            p.frame = NSRect(x: x, y: y, width: s.width, height: s.height)
            x += s.width + pillSpacing
        }
    }

    private func layoutWrap() {
        let widths = pills.map { $0.fittingSize.width }
        let split = PillFlow.split(
            widths: widths,
            available: bounds.width,
            spacing: pillSpacing,
            maxRows: 2
        )
        let rowHeight = pills.map { $0.fittingSize.height }.max() ?? 0

        // Top-down: row 0 sits at the top of the bounds.
        for (rowIdx, rowIndices) in split.rows.enumerated() {
            var x: CGFloat = 0
            let y = bounds.height
                - CGFloat(rowIdx + 1) * rowHeight
                - CGFloat(rowIdx) * rowSpacing
            for i in rowIndices {
                pills[i].isHidden = false
                let s = pills[i].fittingSize
                pills[i].frame = NSRect(x: x, y: y, width: s.width, height: s.height)
                x += s.width + pillSpacing
            }
        }

        // Pills past the 2-row budget — show overflow opener inline at
        // the end of the last row, popover holds the spillover.
        if split.overflow.isEmpty {
            overflowButton.isHidden = true
        } else {
            overflowButton.isHidden = false
            let lastRow = split.rows.last ?? []
            let trailingX = lastRow.reduce(CGFloat(0)) { acc, i in
                let s = pills[i].fittingSize
                return acc + s.width + pillSpacing
            }
            let lastRowIdx = max(0, split.rows.count - 1)
            let y = bounds.height
                - CGFloat(lastRowIdx + 1) * rowHeight
                - CGFloat(lastRowIdx) * rowSpacing
            let s = overflowButton.fittingSize
            overflowButton.frame = NSRect(
                x: trailingX,
                y: y + (rowHeight - s.height) / 2,
                width: s.width,
                height: s.height
            )
            for i in split.overflow { pills[i].isHidden = true }
        }
    }

    private func layoutCollapsed() {
        for p in pills { p.isHidden = true }
        let s = overflowButton.fittingSize
        overflowButton.frame = NSRect(
            x: 0,
            y: (bounds.height - s.height) / 2,
            width: s.width,
            height: s.height
        )
    }

    override var intrinsicContentSize: NSSize {
        // Empty row collapses fully — preserves the pre-§4.g chat-pane
        // geometry for chats that don't install any metadata pills yet.
        if pills.isEmpty {
            return NSSize(width: NSView.noIntrinsicMetric, height: 0)
        }
        switch mode {
        case .inline, .collapsed:
            let h = pills.map { $0.fittingSize.height }.max()
                ?? overflowButton.fittingSize.height
            return NSSize(width: NSView.noIntrinsicMetric, height: h)
        case .wrap:
            let pillH = pills.map { $0.fittingSize.height }.max() ?? 0
            let widths = pills.map { $0.fittingSize.width }
            let avail = bounds.width > 0 ? bounds.width : 800
            let split = PillFlow.split(
                widths: widths,
                available: avail,
                spacing: pillSpacing,
                maxRows: 2
            )
            let rows = CGFloat(max(1, split.rows.count))
            return NSSize(
                width: NSView.noIntrinsicMetric,
                height: rows * pillH + (rows - 1) * rowSpacing
            )
        }
    }

    // MARK: - Overflow popover

    @objc private func showOverflow() {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // Decide which pills enter the popover. In `.collapsed` mode,
        // every pill goes in. In `.wrap` mode (overflow case), only
        // the spillover does.
        let widths = pills.map { $0.fittingSize.width }
        let pillsToHost: [NSView]
        switch mode {
        case .collapsed:
            pillsToHost = pills
        case .wrap:
            let split = PillFlow.split(
                widths: widths,
                available: bounds.width,
                spacing: pillSpacing,
                maxRows: 2
            )
            pillsToHost = split.overflow.map { pills[$0] }
        case .inline:
            pillsToHost = []
        }

        for p in pillsToHost {
            p.removeFromSuperview()
            p.translatesAutoresizingMaskIntoConstraints = false
            p.isHidden = false
            stack.addArrangedSubview(p)
        }

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        let vc = NSViewController()
        vc.view = host
        popover.contentViewController = vc
        overflowPopover = popover

        DebugLog.shared.write("[chat-pane] pills overflow popover shown mode=\(mode) hosted=\(pillsToHost.count)")
        popover.show(relativeTo: overflowButton.bounds, of: overflowButton, preferredEdge: .maxY)
    }

    func popoverWillClose(_ notification: Notification) {
        // Move pills back. Constraints layout (stack mode) was
        // installed on them when they entered the popover; now they
        // return to manual frame layout.
        for p in pills where p.superview !== self {
            p.removeFromSuperview()
            p.translatesAutoresizingMaskIntoConstraints = true
            addSubview(p)
        }
        overflowPopover = nil
        needsLayout = true
    }
}
