import AppKit

/// V2_UI_OVERHAUL §4.9 / §4.g.4 — composer's persona picker. First
/// persona-switching UI in the chat pane. Reads `chat.personaId` and
/// the global persona list, surfaces a button face that summarises
/// the current binding, and opens an `NSPopover` with name +
/// description rows so the user can re-bind without leaving the
/// transcript.
///
/// Sits leading-most in the InputBar pill row per spec. Visual style
/// matches the existing `bezelStyle = .rounded` + `Theme.font(11)`
/// pickers (Server / Voice / Attribution) so the row stays coherent;
/// the §4.9 capsule-pill restyle is a future, separate styling pass
/// and isn't piggy-backed here.
final class PersonaPill: NSView, NSPopoverDelegate {
    private let button = NSButton()
    private var popover: NSPopover?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false

        button.bezelStyle = .rounded
        button.font = Theme.font(11)
        button.target = self
        button.action = #selector(toggle)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.toolTip = "Persona — who you're roleplaying as"
        addSubview(button)

        NSLayoutConstraint.activate([
            button.topAnchor.constraint(equalTo: topAnchor),
            button.bottomAnchor.constraint(equalTo: bottomAnchor),
            button.leadingAnchor.constraint(equalTo: leadingAnchor),
            button.trailingAnchor.constraint(equalTo: trailingAnchor)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.chatUpdated, object: nil)
        nc.addObserver(self, selector: #selector(refresh),
            name: AppNotification.personasChanged, object: nil)
        refresh()
    }

    required init?(coder: NSCoder) { nil }
    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func refresh() {
        let chat = AppState.shared.currentChat
        let title = PersonaPillTitle.resolve(
            personaId: chat?.personaId,
            personas: AppState.shared.personas
        )
        button.title = "Persona: \(title)"
        // Subtle dimming when nothing's bound — caller still gets a
        // clickable affordance, just visually de-emphasised.
        button.contentTintColor = (chat?.personaId == nil)
            ? .secondaryLabelColor
            : .labelColor
    }

    // MARK: - Popover

    @objc private func toggle() {
        if let p = popover, p.isShown {
            p.close()
            return
        }
        showPopover()
    }

    private func showPopover() {
        let p = NSPopover()
        p.behavior = .transient
        p.delegate = self

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        // "None" row at the top — explicit way to clear `personaId`
        // back to nil. Disabled to look like a section divider when
        // already nil-bound; otherwise active.
        let noneRow = makeRow(
            id: nil,
            name: "No persona",
            description: "Don't inject a user-side persona",
            isCurrent: AppState.shared.currentChat?.personaId == nil
        )
        stack.addArrangedSubview(noneRow)

        let personas = AppState.shared.personas
        if personas.isEmpty {
            let hint = NSTextField(labelWithString:
                "No personas yet — open the Personas library to create one.")
            hint.font = Theme.font(11)
            hint.textColor = .tertiaryLabelColor
            hint.maximumNumberOfLines = 2
            hint.preferredMaxLayoutWidth = 260
            stack.addArrangedSubview(hint)
        } else {
            for persona in personas {
                let row = makeRow(
                    id: persona.id,
                    name: persona.name.isEmpty ? "Unnamed persona" : persona.name,
                    description: persona.description,
                    isCurrent: AppState.shared.currentChat?.personaId == persona.id
                )
                stack.addArrangedSubview(row)
            }
        }

        let host = NSView()
        host.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            stack.topAnchor.constraint(equalTo: host.topAnchor),
            stack.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            host.widthAnchor.constraint(lessThanOrEqualToConstant: 320)
        ])
        let vc = NSViewController()
        vc.view = host
        p.contentViewController = vc
        popover = p

        DebugLog.shared.write("[chat-pane] persona pill popover shown personas=\(personas.count)")
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
    }

    private func makeRow(id: UUID?, name: String, description: String, isCurrent: Bool) -> NSView {
        let row = PersonaPillRow(personaId: id, isCurrent: isCurrent)
        row.target = self
        row.action = #selector(rowPicked(_:))
        row.titleLabel.stringValue = isCurrent ? "✓ \(name)" : name
        row.titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        if description.isEmpty {
            row.descriptionLabel.isHidden = true
        } else {
            row.descriptionLabel.stringValue = description
            row.descriptionLabel.isHidden = false
        }
        return row
    }

    @objc private func rowPicked(_ sender: PersonaPillRow) {
        AppState.shared.updateCurrent { c in
            c.personaId = sender.personaId
        }
        popover?.close()
        // refresh fires via chatUpdated notification.
    }

    func popoverDidClose(_ notification: Notification) {
        popover = nil
    }
}

/// V2_UI_OVERHAUL §4.g.4 — single persona row inside the picker
/// popover. Wraps an NSButton's tap behaviour around a vertical
/// `[name, description]` stack so the description is part of the
/// click target and not a separate, dead label.
final class PersonaPillRow: NSButton {
    let personaId: UUID?
    let titleLabel = NSTextField(labelWithString: "")
    let descriptionLabel = NSTextField(labelWithString: "")

    init(personaId: UUID?, isCurrent: Bool) {
        self.personaId = personaId
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        bezelStyle = .inline
        isBordered = false
        title = ""
        imagePosition = .noImage
        contentTintColor = .labelColor

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.translatesAutoresizingMaskIntoConstraints = false
        descriptionLabel.font = Theme.font(11)
        descriptionLabel.textColor = .secondaryLabelColor
        descriptionLabel.maximumNumberOfLines = 2
        descriptionLabel.lineBreakMode = .byTruncatingTail
        descriptionLabel.preferredMaxLayoutWidth = 280

        let stack = NSStackView(views: [titleLabel, descriptionLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 6, bottom: 4, right: 6)
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            widthAnchor.constraint(greaterThanOrEqualToConstant: 220)
        ])
    }

    required init?(coder: NSCoder) { nil }
}

/// V2_UI_OVERHAUL §4.g.4 — pure-data title resolver for the persona
/// pill. Lifted out as a static helper so the binding logic
/// (current id × known personas → display string) can be unit-tested
/// without an NSWindow.
enum PersonaPillTitle {
    static func resolve(personaId: UUID?, personas: [Persona]) -> String {
        guard let pid = personaId else { return "None" }
        guard let p = personas.first(where: { $0.id == pid }) else { return "None" }
        return p.name.isEmpty ? "Unnamed" : p.name
    }
}
