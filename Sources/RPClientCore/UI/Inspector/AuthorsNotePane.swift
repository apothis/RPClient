import AppKit

final class AuthorsNotePane: NSViewController, NSTextViewDelegate {
    private let scrollView = NSScrollView()
    private let textView = NSTextView()
    private let depthStepper = NSStepper()
    private let depthLabel = NSTextField(labelWithString: "Depth: 4")
    private let depthHelp = NSTextField(labelWithString:
        "Injected this many turns from the end. 0 = right before the next reply.")
    private let helpLabel = NSTextField(labelWithString:
        "Author's note. Style/scene cues injected near the end of the prompt.")
    private let helpButton = HelpButton(pageId: "memory-authors-note")

    private var lastChatId: UUID?

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        helpLabel.font = Theme.font(11)
        helpLabel.textColor = .secondaryLabelColor
        helpLabel.lineBreakMode = .byWordWrapping
        helpLabel.maximumNumberOfLines = 0
        helpLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(helpLabel)
        v.addSubview(helpButton)

        textView.isRichText = false
        textView.font = Theme.font(12)
        textView.allowsUndo = true
        textView.delegate = self
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: 0, height: CGFloat.greatestFiniteMagnitude
        )
        textView.minSize = NSSize(width: 0, height: 60)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .lineBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        depthStepper.minValue = 0
        depthStepper.maxValue = 32
        depthStepper.increment = 1
        depthStepper.target = self
        depthStepper.action = #selector(depthChanged)
        depthStepper.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(depthStepper)

        depthLabel.font = Theme.mono(11)
        depthLabel.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(depthLabel)

        depthHelp.font = Theme.font(11)
        depthHelp.textColor = .secondaryLabelColor
        depthHelp.lineBreakMode = .byWordWrapping
        depthHelp.maximumNumberOfLines = 0
        depthHelp.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(depthHelp)

        NSLayoutConstraint.activate([
            helpLabel.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            helpLabel.trailingAnchor.constraint(equalTo: helpButton.leadingAnchor, constant: -6),

            helpButton.topAnchor.constraint(equalTo: v.topAnchor, constant: 10),
            helpButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.topAnchor.constraint(equalTo: helpLabel.bottomAnchor, constant: 8),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),

            scrollView.bottomAnchor.constraint(equalTo: depthLabel.topAnchor, constant: -10),

            depthLabel.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            depthStepper.leadingAnchor.constraint(equalTo: depthLabel.trailingAnchor, constant: 8),
            depthStepper.centerYAnchor.constraint(equalTo: depthLabel.centerYAnchor),

            depthHelp.topAnchor.constraint(equalTo: depthLabel.bottomAnchor, constant: 4),
            depthHelp.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 10),
            depthHelp.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -10),
            depthHelp.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(reload),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(applyFonts),
            name: AppNotification.fontChanged, object: nil)
        reload()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func applyFonts() {
        helpLabel.font = Theme.font(11)
        textView.font = Theme.font(12)
        depthLabel.font = Theme.mono(11)
        depthHelp.font = Theme.font(11)
    }

    @objc private func reload() {
        guard let chat = AppState.shared.currentChat else { return }
        if chat.id != lastChatId {
            lastChatId = chat.id
            textView.string = chat.authorsNote.text
        }
        depthStepper.integerValue = chat.authorsNote.depth
        depthLabel.stringValue = "Depth: \(chat.authorsNote.depth)"
    }

    @objc private func depthChanged() {
        let d = depthStepper.integerValue
        depthLabel.stringValue = "Depth: \(d)"
        AppState.shared.updateCurrent { c in
            c.authorsNote.depth = d
        }
    }

    func textDidEndEditing(_ notification: Notification) {
        let text = textView.string
        AppState.shared.updateCurrent { c in
            c.authorsNote.text = text
        }
    }
}
