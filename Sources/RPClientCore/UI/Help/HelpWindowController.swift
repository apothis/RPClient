import AppKit

/// In-app help window: TOC on the left, rendered markdown on the right, search
/// field in the toolbar. Frozen content — pages live as bundle resources, so
/// edits happen in source, not at runtime.
///
/// Wired in [AppDelegate.swift](../AppDelegate.swift) under the Help menu
/// (⌘?). Inspector panes can deep-link via `show(pageId:anchor:)`.
final class HelpWindowController: NSWindowController, NSWindowDelegate {

    // MARK: - State

    /// Pre-loaded once at init. Help is small (a handful of small files) and
    /// frozen; loading eagerly lets search be instant.
    private struct LoadedPage {
        let page: HelpPage
        let markdown: String
        let lowercaseMarkdown: String
        let rendered: HelpRenderer.Result
    }

    private var loaded: [LoadedPage] = []

    /// Filtered TOC: bookwise pages, optionally filtered by search.
    private var visibleByBook: [HelpBook: [LoadedPage]] = [:]
    private var searchQuery: String = ""
    private var currentPageId: String?

    // MARK: - UI

    private let searchField = NSSearchField()
    private let outline = NSOutlineView()
    private let outlineScroll = NSScrollView()
    private let contentText = NSTextView()
    private let contentScroll = NSScrollView()
    private let missingLabel = NSTextField(labelWithString: "Page not found.")

    convenience init() {
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        w.minSize = NSSize(width: 640, height: 420)
        w.title = "RPClient Help"
        w.setFrameAutosaveName("RPClient.HelpWindow")
        self.init(window: w)
        w.delegate = self
        loadPages()
        rebuildVisible()
        buildUI()
    }

    private func loadPages() {
        loaded = HelpIndex.pages.compactMap { page in
            guard let md = HelpIndex.markdown(for: page) else { return nil }
            let rendered = HelpRenderer.render(md)
            return LoadedPage(
                page: page,
                markdown: md,
                lowercaseMarkdown: md.lowercased(),
                rendered: rendered
            )
        }
    }

    private func buildUI() {
        guard let cv = window?.contentView else { return }

        // Toolbar-ish header with search.
        searchField.placeholderString = "Search help"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        // TOC — NSOutlineView with two book rows as parents.
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("title"))
        col.title = "Help"
        col.width = 220
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.dataSource = self
        outline.delegate = self
        outline.style = .sourceList
        outline.rowHeight = 24
        outline.target = self
        outline.action = #selector(outlineRowClicked)
        outline.autosaveExpandedItems = true
        outline.autosaveName = "RPClient.HelpOutline"

        outlineScroll.documentView = outline
        outlineScroll.hasVerticalScroller = true
        outlineScroll.translatesAutoresizingMaskIntoConstraints = false
        outlineScroll.borderType = .noBorder

        // Content — read-only NSTextView with our custom URL scheme handler.
        contentText.isEditable = false
        contentText.isSelectable = true
        contentText.drawsBackground = true
        contentText.backgroundColor = .textBackgroundColor
        contentText.textContainerInset = NSSize(width: 24, height: 18)
        contentText.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
            .cursor: NSCursor.pointingHand,
        ]
        contentText.delegate = self
        contentText.isVerticallyResizable = true
        contentText.isHorizontallyResizable = false
        contentText.autoresizingMask = [.width]
        contentText.textContainer?.widthTracksTextView = true
        contentText.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )

        contentScroll.documentView = contentText
        contentScroll.hasVerticalScroller = true
        contentScroll.translatesAutoresizingMaskIntoConstraints = false
        contentScroll.borderType = .noBorder

        missingLabel.font = Theme.font(13)
        missingLabel.textColor = .secondaryLabelColor
        missingLabel.translatesAutoresizingMaskIntoConstraints = false
        missingLabel.isHidden = true

        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.autosaveName = "RPClient.HelpSplit"
        split.addArrangedSubview(outlineScroll)
        split.addArrangedSubview(contentScroll)
        // The outline pane should be narrow and stable; pin it via min/max
        // widths so the divider lands somewhere sensible on first launch.
        outlineScroll.widthAnchor.constraint(greaterThanOrEqualToConstant: 180).isActive = true
        outlineScroll.widthAnchor.constraint(lessThanOrEqualToConstant: 320).isActive = true

        cv.addSubview(searchField)
        cv.addSubview(split)
        cv.addSubview(missingLabel)

        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(equalTo: cv.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: cv.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: cv.trailingAnchor, constant: -12),

            split.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            split.leadingAnchor.constraint(equalTo: cv.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: cv.trailingAnchor),
            split.bottomAnchor.constraint(equalTo: cv.bottomAnchor),

            missingLabel.centerXAnchor.constraint(equalTo: contentScroll.centerXAnchor),
            missingLabel.centerYAnchor.constraint(equalTo: contentScroll.centerYAnchor),
        ])

        outline.expandItem(nil, expandChildren: true)

        // Restore last page or fall back to first page.
        let restoreId = UserDefaults.standard.string(forKey: "RPClient.HelpLastPage")
        let target = restoreId.flatMap { id in loaded.first { $0.page.id == id } }
            ?? loaded.first
        if let target {
            show(pageId: target.page.id, anchor: nil)
        }
    }

    // MARK: - Public

    /// Open the window scrolled to a specific page (and optionally an anchor
    /// inside that page). Used by inspector pane "?" buttons (later slices)
    /// and by the menu wiring.
    func show(pageId: String, anchor: String?) {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        guard let p = loaded.first(where: { $0.page.id == pageId }) else {
            currentPageId = nil
            renderMissing()
            return
        }
        currentPageId = pageId
        UserDefaults.standard.set(pageId, forKey: "RPClient.HelpLastPage")
        renderPage(p, anchor: anchor)
        selectInOutline(p)
    }

    // MARK: - Render

    private func renderPage(_ page: LoadedPage, anchor: String?) {
        missingLabel.isHidden = true
        contentText.isHidden = false
        contentText.textStorage?.setAttributedString(page.rendered.attributed)

        // Highlight search-query matches with a yellow background so users see
        // why a page is in the filtered list. Cleared on every render.
        if !searchQuery.isEmpty {
            highlightSearchMatches(in: page)
        }

        if let anchor, let location = page.rendered.anchors[anchor] {
            scrollTo(location: location)
        } else {
            contentText.scroll(.zero)
        }
    }

    private func renderMissing() {
        contentText.textStorage?.setAttributedString(NSAttributedString())
        contentText.isHidden = true
        missingLabel.isHidden = false
    }

    private func scrollTo(location: Int) {
        guard location >= 0, location <= contentText.string.count else { return }
        let range = NSRange(location: location, length: 0)
        contentText.scrollRangeToVisible(range)
        // Nudge the scroll a touch above the heading so it isn't flush with
        // the top inset of the text view.
        if let lm = contentText.layoutManager, let tc = contentText.textContainer {
            let glyphRange = lm.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = lm.boundingRect(forGlyphRange: glyphRange, in: tc)
            let target = NSPoint(x: 0, y: max(0, rect.origin.y - 8))
            contentText.scroll(target)
        }
    }

    private func highlightSearchMatches(in page: LoadedPage) {
        let q = searchQuery.lowercased()
        guard !q.isEmpty, let storage = contentText.textStorage else { return }
        let plain = storage.string.lowercased() as NSString
        let full = NSRange(location: 0, length: plain.length)
        var search = full
        while search.length > 0 {
            let r = plain.range(of: q, options: [], range: search)
            if r.location == NSNotFound { break }
            storage.addAttribute(.backgroundColor,
                value: NSColor.systemYellow.withAlphaComponent(0.35), range: r)
            let next = r.location + r.length
            search = NSRange(location: next, length: full.length - next)
        }
    }

    // MARK: - Search

    @objc private func searchChanged() {
        searchQuery = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        rebuildVisible()
        outline.reloadData()
        outline.expandItem(nil, expandChildren: true)
        // Re-render current page so highlights refresh.
        if let id = currentPageId, let p = loaded.first(where: { $0.page.id == id }) {
            renderPage(p, anchor: nil)
        }
    }

    private func rebuildVisible() {
        let q = searchQuery.lowercased()
        var byBook: [HelpBook: [LoadedPage]] = [:]
        for book in HelpBook.allCases {
            let pages = loaded.filter { $0.page.book == book }
            if q.isEmpty {
                byBook[book] = pages
            } else {
                byBook[book] = pages.filter { p in
                    p.lowercaseMarkdown.contains(q) ||
                        p.page.title.lowercased().contains(q)
                }
            }
        }
        visibleByBook = byBook
    }

    private func selectInOutline(_ target: LoadedPage) {
        let row = outline.row(forItem: target)
        if row >= 0 {
            outline.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            outline.scrollRowToVisible(row)
        }
    }

    // MARK: - Outline action

    @objc private func outlineRowClicked() {
        let row = outline.clickedRow
        guard row >= 0 else { return }
        let item = outline.item(atRow: row)
        if let page = item as? LoadedPage {
            show(pageId: page.page.id, anchor: nil)
        }
    }
}

// MARK: - NSOutlineViewDataSource / Delegate

extension HelpWindowController: NSOutlineViewDataSource, NSOutlineViewDelegate {

    func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        if item == nil {
            // Top-level: only books with at least one visible page.
            return HelpBook.allCases.filter { (visibleByBook[$0]?.count ?? 0) > 0 }.count
        }
        if let book = item as? HelpBook {
            return visibleByBook[book]?.count ?? 0
        }
        return 0
    }

    func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        if item == nil {
            let books = HelpBook.allCases.filter { (visibleByBook[$0]?.count ?? 0) > 0 }
            return books[index]
        }
        if let book = item as? HelpBook {
            return visibleByBook[book]![index]
        }
        return NSNull()
    }

    func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
        item is HelpBook
    }

    func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let id = NSUserInterfaceItemIdentifier("HelpRow")
        let cell = outlineView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView
            ?? makeRow(id: id)
        if let book = item as? HelpBook {
            cell.textField?.stringValue = book.title.uppercased()
            cell.textField?.font = Theme.font(11, weight: .semibold)
            cell.textField?.textColor = .secondaryLabelColor
        } else if let page = item as? LoadedPage {
            cell.textField?.stringValue = page.page.title
            cell.textField?.font = Theme.font(13)
            cell.textField?.textColor = .labelColor
        }
        return cell
    }

    func outlineView(_ outlineView: NSOutlineView, isGroupItem item: Any) -> Bool {
        item is HelpBook
    }

    func outlineView(_ outlineView: NSOutlineView, shouldSelectItem item: Any) -> Bool {
        item is LoadedPage
    }

    private func makeRow(id: NSUserInterfaceItemIdentifier) -> NSTableCellView {
        let cell = NSTableCellView()
        cell.identifier = id
        let tf = NSTextField(labelWithString: "")
        tf.translatesAutoresizingMaskIntoConstraints = false
        tf.lineBreakMode = .byTruncatingTail
        cell.addSubview(tf)
        cell.textField = tf
        NSLayoutConstraint.activate([
            tf.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 6),
            tf.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -6),
            tf.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }
}

// MARK: - NSTextViewDelegate (link interception)

extension HelpWindowController: NSTextViewDelegate {
    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL else { return false }
        if url.scheme == HelpRenderer.linkScheme {
            // URL has no Swift-native `resourceSpecifier`; bridge through
            // NSURL, or fall back to slicing the absolute string by the
            // known "scheme:" prefix.
            let prefix = "\(HelpRenderer.linkScheme):"
            let abs = url.absoluteString
            let spec = abs.hasPrefix(prefix)
                ? String(abs.dropFirst(prefix.count))
                : abs
            let parts = spec.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
            let pageRaw = parts.first.map(String.init) ?? ""
            let anchor = parts.count > 1 ? String(parts[1]) : nil
            if pageRaw.isEmpty {
                // In-page anchor.
                if let id = currentPageId, let p = loaded.first(where: { $0.page.id == id }),
                   let anchor, let loc = p.rendered.anchors[anchor] {
                    scrollTo(location: loc)
                }
            } else {
                show(pageId: pageRaw, anchor: anchor)
            }
            return true
        }
        // External link — let the system handle it.
        NSWorkspace.shared.open(url)
        return true
    }
}
