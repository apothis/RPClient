import AppKit

/// Hosts the inspector tabs (Memory, Entities, Suggestions, …).
///
/// Both `NSTabView` and `NSTabViewController` (in pre-Sonoma layouts at
/// least) are flaky about propagating horizontal resizes from the enclosing
/// `NSSplitView` to the active tab's content view — drags expand the pane
/// briefly, then snap back on release. The fix is to skip the framework tab
/// chrome entirely: a plain segmented control on top, a container view below
/// it, and we pin the active child VC's view to the container with explicit
/// leading/trailing constraints. That way the split-view drag flows straight
/// through to the child without any opportunity for AppKit to "settle" back
/// to a smaller intrinsic size.
final class InspectorViewController: NSViewController {
    private struct Tab {
        let label: String
        let make: () -> NSViewController
    }

    private let segmented = NSSegmentedControl()
    private let segmentedScroll = NSScrollView()
    private let container = NSView()
    private var panes: [NSViewController?] = []
    private var tabs: [Tab] = []
    private var activeIndex: Int = 0
    private var suggestionsIndex: Int = 0
    private var lastSeenSuggestionCount: [UUID: Int] = [:]

    override func loadView() {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 600))
        v.wantsLayer = true
        v.autoresizingMask = [.width, .height]
        view = v

        tabs = [
            Tab(label: "Memory",       make: { MemoryPane() }),
            Tab(label: "Entities",     make: { EntitiesPane() }),
            Tab(label: "World",        make: { WorldInfoPane() }),
            Tab(label: "Cast",         make: { CastPane() }),
            Tab(label: "Branches",     make: { BranchesPane() }),
            Tab(label: "Tree",         make: { TreePane() }),
            Tab(label: "Suggestions",  make: { SuggestionsPane() }),
            Tab(label: "Extraction",   make: { ExtractionPane() }),
            Tab(label: "Summary",      make: { SummaryPane() }),
            Tab(label: "Author's Note",make: { AuthorsNotePane() }),
            Tab(label: "Retrieval",    make: { RetrievalPane() }),
        ]
        panes = Array(repeating: nil, count: tabs.count)
        suggestionsIndex = tabs.firstIndex(where: { $0.label == "Suggestions" }) ?? 0

        segmented.segmentStyle = .texturedSquare
        segmented.trackingMode = .selectOne
        segmented.segmentCount = tabs.count
        for (i, t) in tabs.enumerated() {
            segmented.setLabel(t.label, forSegment: i)
            segmented.setWidth(0, forSegment: i) // auto-fit
        }
        segmented.selectedSegment = 0
        segmented.target = self
        segmented.action = #selector(segmentChanged(_:))
        segmented.translatesAutoresizingMaskIntoConstraints = false

        // Phase 8 §4.3 — wrap the segmented control in a horizontal scroll
        // view so the inspector pane can shrink narrower than the
        // segmented control's intrinsic width. Without this, adding the
        // Cast tab pushed the intrinsic width past the pane's minimum
        // and the user couldn't reclaim the space for the chat window.
        segmentedScroll.translatesAutoresizingMaskIntoConstraints = false
        segmentedScroll.hasHorizontalScroller = true
        segmentedScroll.hasVerticalScroller = false
        segmentedScroll.drawsBackground = false
        segmentedScroll.borderType = .noBorder
        segmentedScroll.documentView = segmented
        // Persistent legacy-style scroller so the user sees "there are
        // more tabs that direction" without having to discover the
        // scroll affordance via trial-and-error. Overlay scrollers were
        // invisible until scrolled, which made horizontal-scroll feel
        // broken on the inspector's tab bar.
        segmentedScroll.scrollerStyle = .legacy
        segmentedScroll.autohidesScrollers = false
        segmentedScroll.horizontalScroller?.controlSize = .small
        v.addSubview(segmentedScroll)

        container.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(container)

        // Reserve enough vertical space for the segmented control plus
        // the persistent legacy scroller below it (~15pt). Segmented
        // control's natural height is ~23pt at .texturedSquare style.
        let segHeight: CGFloat = 40

        NSLayoutConstraint.activate([
            segmentedScroll.topAnchor.constraint(equalTo: v.topAnchor, constant: 6),
            segmentedScroll.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 6),
            segmentedScroll.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -6),
            segmentedScroll.heightAnchor.constraint(equalToConstant: segHeight),

            // The segmented control sits inside the scroll view's content
            // view; pinning top/leading/bottom keeps the row at the right
            // height and the trailing edge floats to the segmented
            // control's intrinsic width (so it scrolls horizontally when
            // the pane is narrower than the full bar).
            segmented.topAnchor.constraint(equalTo: segmentedScroll.contentView.topAnchor),
            segmented.leadingAnchor.constraint(equalTo: segmentedScroll.contentView.leadingAnchor),
            segmented.bottomAnchor.constraint(equalTo: segmentedScroll.contentView.bottomAnchor),

            container.topAnchor.constraint(equalTo: segmentedScroll.bottomAnchor, constant: 6),
            container.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: v.bottomAnchor)
        ])

        showTab(at: 0)

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refreshSuggestionsBadge),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refreshSuggestionsBadge),
            name: AppNotification.currentChatChanged, object: nil)
        refreshSuggestionsBadge()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    // MARK: - Tab switching

    @objc private func segmentChanged(_ sender: NSSegmentedControl) {
        showTab(at: sender.selectedSegment)
    }

    private func showTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        if panes[index] == nil {
            panes[index] = tabs[index].make()
        }
        guard let vc = panes[index] else { return }

        // Remove whichever pane is currently showing.
        for sub in container.subviews { sub.removeFromSuperview() }
        for child in children { child.removeFromParent() }

        addChild(vc)
        let pv = vc.view
        pv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(pv)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: container.topAnchor),
            pv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            pv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        activeIndex = index
        if index == suggestionsIndex, let chat = AppState.shared.currentChat {
            lastSeenSuggestionCount[chat.id] = chat.pendingFactSuggestions.count
        }
        refreshSuggestionsBadge()
    }

    // MARK: - Suggestions tab unread badge

    @objc private func refreshSuggestionsBadge() {
        let baseLabel = "Suggestions"
        guard let chat = AppState.shared.currentChat else {
            segmented.setLabel(baseLabel, forSegment: suggestionsIndex)
            return
        }
        let pending = chat.pendingFactSuggestions.count
        if activeIndex == suggestionsIndex {
            lastSeenSuggestionCount[chat.id] = pending
            segmented.setLabel(baseLabel, forSegment: suggestionsIndex)
            return
        }
        let seen = lastSeenSuggestionCount[chat.id] ?? 0
        let unread = max(0, pending - seen)
        segmented.setLabel(unread > 0 ? "\(baseLabel) ● \(unread)" : baseLabel,
                           forSegment: suggestionsIndex)
    }
}
