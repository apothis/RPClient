import AppKit

/// Phase 9 §5.3b — list editor for `alternateGreetings` and
/// `groupOnlyGreetings`. Each row is an inline-editable multi-line text
/// view (per V2_DESIGN_LANGUAGE §11 — Notion / Linear pattern: the row IS
/// the edit surface, no per-row modal sheet). Hover-revealed action
/// column per row carries up / down / delete buttons (V2_DESIGN_LANGUAGE
/// §11 hover-handles, Notion convention). Empty state displays a
/// secondary-color callout. "+ Add greeting" footer button binds ⌘⇧A.
final class GreetingListEditor: NSView {

    var onChange: (([String]) -> Void)?

    /// Phase 9 §5.4.b — wires AI single-shot generation. The editor
    /// calls this when the author clicks Generate; the parent tab
    /// fires a side-call against the active chat's template + the
    /// per-window cardCreatorClient and invokes the completion with
    /// the generated text (or nil on failure). The editor handles
    /// spinner state + appending the new entry.
    var onGenerate: ((@escaping (String?) -> Void) -> Void)?

    private let label: String
    private let hint: String?
    private let v3Only: Bool

    private let labelView = NSTextField(labelWithString: "")
    private let stack = NSStackView()
    private let addButton = NSButton(title: "+ Add greeting", target: nil, action: nil)
    private let generateButton = NSButton()
    private let generateSpinner = NSProgressIndicator()
    private let emptyState = NSTextField(labelWithString: "")

    private(set) var values: [String] = []

    init(label: String,
         initialValues: [String],
         hint: String? = nil,
         v3Only: Bool = false) {
        self.label = label
        self.hint = hint
        self.v3Only = v3Only
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValues: initialValues)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(initialValues: [String]) {
        // Header.
        labelView.stringValue = label
        labelView.font = DesignTokens.Typography.headline
        labelView.textColor = DesignTokens.Foreground.primary
        labelView.translatesAutoresizingMaskIntoConstraints = false

        let header = NSStackView(views: [labelView])
        header.orientation = .horizontal
        header.spacing = DesignTokens.Spacing.xs
        header.alignment = .firstBaseline
        header.translatesAutoresizingMaskIntoConstraints = false
        if v3Only {
            header.addArrangedSubview(makeV3Pill())
        }
        addSubview(header)

        // Row stack.
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DesignTokens.Spacing.sm
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        // Empty state.
        emptyState.stringValue = "No greetings yet. Click + Add greeting to start."
        emptyState.font = DesignTokens.Typography.subheadline
        emptyState.textColor = DesignTokens.Foreground.secondary
        emptyState.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyState)

        // Add button.
        addButton.target = self
        addButton.action = #selector(addGreetingClicked)
        addButton.bezelStyle = .rounded
        addButton.controlSize = .small
        addButton.keyEquivalent = "a"
        addButton.keyEquivalentModifierMask = [.command, .shift]
        addButton.translatesAutoresizingMaskIntoConstraints = false

        // Phase 9 §5.4.b — Generate button alongside Add. Fires a
        // single-shot side-call via onGenerate; result appends as a
        // new row. Spinner shows while the call is in flight.
        generateButton.bezelStyle = .rounded
        generateButton.controlSize = .small
        generateButton.target = self
        generateButton.action = #selector(generateGreetingClicked)
        generateButton.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "Generate")
        generateButton.imagePosition = .imageLeading
        generateButton.title = "Generate"
        generateButton.toolTip = "Append an AI-generated greeting based on the rest of this card."
        generateButton.translatesAutoresizingMaskIntoConstraints = false

        generateSpinner.style = .spinning
        generateSpinner.controlSize = .small
        generateSpinner.isDisplayedWhenStopped = false
        generateSpinner.translatesAutoresizingMaskIntoConstraints = false

        let footerRow = NSStackView(views: [addButton, generateButton, generateSpinner])
        footerRow.orientation = .horizontal
        footerRow.alignment = .centerY
        footerRow.spacing = DesignTokens.Spacing.sm
        footerRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(footerRow)

        var topConstraint: NSLayoutConstraint
        var hintConstraints: [NSLayoutConstraint] = []
        if let hintText = hint {
            let hintView = NSTextField(labelWithString: hintText)
            hintView.font = DesignTokens.Typography.subheadline
            hintView.textColor = DesignTokens.Foreground.secondary
            hintView.lineBreakMode = .byWordWrapping
            hintView.maximumNumberOfLines = 3
            hintView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(hintView)
            hintConstraints = [
                hintView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.xs),
                hintView.leadingAnchor.constraint(equalTo: leadingAnchor),
                hintView.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            ]
            topConstraint = stack.topAnchor.constraint(equalTo: hintView.bottomAnchor, constant: DesignTokens.Spacing.sm)
        } else {
            topConstraint = stack.topAnchor.constraint(equalTo: header.bottomAnchor, constant: DesignTokens.Spacing.sm)
        }

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: topAnchor),
            header.leadingAnchor.constraint(equalTo: leadingAnchor),
            header.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),

            topConstraint,
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),

            emptyState.centerXAnchor.constraint(equalTo: leadingAnchor, constant: 0),
            emptyState.leadingAnchor.constraint(equalTo: stack.leadingAnchor),
            emptyState.topAnchor.constraint(equalTo: stack.topAnchor),

            footerRow.topAnchor.constraint(equalTo: stack.bottomAnchor, constant: DesignTokens.Spacing.sm),
            footerRow.leadingAnchor.constraint(equalTo: leadingAnchor),
            footerRow.bottomAnchor.constraint(equalTo: bottomAnchor),
        ] + hintConstraints)

        // Seed.
        values = initialValues
        rebuildRows()
    }

    // MARK: - Mutation

    @objc private func addGreetingClicked() {
        values.append("")
        rebuildRows()
        onChange?(values)
        // Focus the new row's text view.
        if let lastRow = stack.arrangedSubviews.last as? GreetingRowView {
            window?.makeFirstResponder(lastRow.textView)
        }
    }

    @objc private func generateGreetingClicked() {
        guard let onGenerate = onGenerate else {
            DebugLog.shared.write("greetingList[\(label)]: generate clicked with no onGenerate handler")
            return
        }
        generateButton.isEnabled = false
        generateSpinner.startAnimation(nil)
        onGenerate { [weak self] text in
            guard let self else { return }
            self.generateButton.isEnabled = true
            self.generateSpinner.stopAnimation(nil)
            guard let text, !text.isEmpty else {
                NSSound.beep()
                return
            }
            self.values.append(text)
            self.rebuildRows()
            self.onChange?(self.values)
            // Scroll the new row into view + focus it for inline edit.
            if let lastRow = self.stack.arrangedSubviews.last as? GreetingRowView {
                self.window?.makeFirstResponder(lastRow.textView)
            }
        }
    }

    fileprivate func deleteRow(at index: Int) {
        guard index >= 0 && index < values.count else { return }
        values.remove(at: index)
        rebuildRows()
        onChange?(values)
    }

    fileprivate func moveRow(from source: Int, to dest: Int) {
        guard source >= 0 && source < values.count,
              dest >= 0 && dest < values.count,
              source != dest else { return }
        let item = values.remove(at: source)
        values.insert(item, at: dest)
        rebuildRows()
        onChange?(values)
    }

    fileprivate func updateRow(at index: Int, to text: String) {
        guard index >= 0 && index < values.count else { return }
        values[index] = text
        onChange?(values)
    }

    private func rebuildRows() {
        // Detach all current rows.
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        emptyState.isHidden = !values.isEmpty
        for (i, value) in values.enumerated() {
            let row = GreetingRowView(
                index: i,
                count: values.count,
                value: value,
                editor: self
            )
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
    }

    private func makeV3Pill() -> NSView {
        let pill = NSTextField(labelWithString: "v3")
        pill.font = DesignTokens.Typography.caption2
        pill.textColor = DesignTokens.Foreground.secondary
        pill.translatesAutoresizingMaskIntoConstraints = false
        pill.drawsBackground = false
        let wrap = AppearanceAwareLayerView()
        wrap.translatesAutoresizingMaskIntoConstraints = false
        wrap.backgroundColor = DesignTokens.Background.group
        wrap.cornerRadiusValue = DesignTokens.Radius.chip
        wrap.addSubview(pill)
        NSLayoutConstraint.activate([
            pill.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: 6),
            pill.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -6),
            pill.topAnchor.constraint(equalTo: wrap.topAnchor, constant: 2),
            pill.bottomAnchor.constraint(equalTo: wrap.bottomAnchor, constant: -2),
        ])
        return wrap
    }
}

// MARK: - GreetingRowView

private final class GreetingRowView: NSView {

    let textView = NSTextView()
    private let scrollView = NSScrollView()
    private let actionColumn = NSStackView()
    private let upButton = NSButton(title: "", target: nil, action: nil)
    private let downButton = NSButton(title: "", target: nil, action: nil)
    private let deleteButton = NSButton(title: "", target: nil, action: nil)

    private let index: Int
    private let count: Int
    private weak var editor: GreetingListEditor?
    private var heightConstraint: NSLayoutConstraint!

    init(index: Int, count: Int, value: String, editor: GreetingListEditor) {
        self.index = index
        self.count = count
        self.editor = editor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        buildUI(initialValue: value)
    }

    required init?(coder: NSCoder) { fatalError() }

    private func buildUI(initialValue: String) {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        // Canonical NSTextView-in-NSScrollView setup — see MultilineFieldView
        // for the long-form rationale. Without these, the textView's frame
        // can extend beyond the scrollView clip and intercept clicks
        // intended for sibling rows.
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        textView.font = DesignTokens.Typography.body
        textView.textColor = DesignTokens.Foreground.primary
        textView.isEditable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.string = initialValue
        textView.delegate = self
        textView.textContainerInset = NSSize(width: 4, height: 6)

        scrollView.documentView = textView

        addSubview(scrollView)

        upButton.image = NSImage(systemSymbolName: "chevron.up",
                                 accessibilityDescription: "Move greeting up")
        upButton.isBordered = false
        upButton.imagePosition = .imageOnly
        upButton.target = self
        upButton.action = #selector(moveRowUpClicked)
        upButton.isEnabled = index > 0
        upButton.translatesAutoresizingMaskIntoConstraints = false

        downButton.image = NSImage(systemSymbolName: "chevron.down",
                                   accessibilityDescription: "Move greeting down")
        downButton.isBordered = false
        downButton.imagePosition = .imageOnly
        downButton.target = self
        downButton.action = #selector(moveRowDownClicked)
        downButton.isEnabled = index < count - 1
        downButton.translatesAutoresizingMaskIntoConstraints = false

        deleteButton.image = NSImage(systemSymbolName: "trash",
                                     accessibilityDescription: "Remove greeting")
        deleteButton.isBordered = false
        deleteButton.imagePosition = .imageOnly
        deleteButton.target = self
        deleteButton.action = #selector(deleteRowClicked)
        deleteButton.contentTintColor = DesignTokens.Foreground.secondary
        deleteButton.translatesAutoresizingMaskIntoConstraints = false

        actionColumn.orientation = .vertical
        actionColumn.alignment = .trailing
        actionColumn.spacing = DesignTokens.Spacing.xs
        actionColumn.translatesAutoresizingMaskIntoConstraints = false
        actionColumn.addArrangedSubview(upButton)
        actionColumn.addArrangedSubview(downButton)
        actionColumn.addArrangedSubview(deleteButton)
        // Hover-revealed — alpha animates between 0 and 1 on hover.
        actionColumn.alphaValue = 0
        addSubview(actionColumn)

        // Auto-grow up to 200pt, then scroll. Min 60pt for short greetings.
        heightConstraint = scrollView.heightAnchor.constraint(equalToConstant: 60)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: actionColumn.leadingAnchor, constant: -DesignTokens.Spacing.sm),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightConstraint,

            actionColumn.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Spacing.xs),
            actionColumn.trailingAnchor.constraint(equalTo: trailingAnchor),
            actionColumn.widthAnchor.constraint(equalToConstant: 22),
        ])

        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas {
            removeTrackingArea(area)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
    }

    override func mouseEntered(with event: NSEvent) {
        animateActionAlpha(to: 1)
    }

    override func mouseExited(with event: NSEvent) {
        animateActionAlpha(to: 0)
    }

    private func animateActionAlpha(to target: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = DesignTokens.Motion.hoverFade
            ctx.allowsImplicitAnimation = true
            actionColumn.animator().alphaValue = target
        }
    }

    private func recalculateHeight() {
        guard let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container)
        let inset = textView.textContainerInset.height * 2
        let target = max(60, min(200, used.height + inset + 8))
        if abs(heightConstraint.constant - target) > 0.5 {
            heightConstraint.constant = target
        }
    }

    // MARK: - Row actions

    @objc private func moveRowUpClicked() {
        editor?.moveRow(from: index, to: index - 1)
    }

    @objc private func moveRowDownClicked() {
        editor?.moveRow(from: index, to: index + 1)
    }

    @objc private func deleteRowClicked() {
        editor?.deleteRow(at: index)
    }
}

extension GreetingRowView: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) {
        editor?.updateRow(at: index, to: textView.string)
        DispatchQueue.main.async { [weak self] in
            self?.recalculateHeight()
        }
    }
}
