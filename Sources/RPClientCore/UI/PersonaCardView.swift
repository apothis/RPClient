import AppKit

/// Tile in the Library window's Personas grid (Phase 3 §4.3). Mirrors
/// `CharacterCardView` but with a single subtitle line — personas don't have
/// tags or creators, just `description`.
final class PersonaCardView: NSCollectionViewItem {
    static let reuseId = NSUserInterfaceItemIdentifier("PersonaCardView")
    static let itemSize = NSSize(width: 140, height: 180)

    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let snippetLabel = NSTextField(labelWithString: "")
    private let containerView = NSView()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        containerView.wantsLayer = true
        containerView.layer?.cornerRadius = 8
        containerView.layer?.borderWidth = 1
        containerView.layer?.borderColor = NSColor.separatorColor.cgColor
        containerView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(containerView)

        avatarView.imageScaling = .scaleProportionallyUpOrDown
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 48
        avatarView.layer?.masksToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(avatarView)

        nameLabel.font = Theme.bold(12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(nameLabel)

        snippetLabel.font = Theme.font(10)
        snippetLabel.textColor = .secondaryLabelColor
        snippetLabel.lineBreakMode = .byTruncatingTail
        snippetLabel.alignment = .center
        snippetLabel.maximumNumberOfLines = 2
        snippetLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(snippetLabel)

        NSLayoutConstraint.activate([
            containerView.topAnchor.constraint(equalTo: v.topAnchor, constant: 4),
            containerView.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 4),
            containerView.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -4),
            containerView.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -4),

            avatarView.topAnchor.constraint(equalTo: containerView.topAnchor, constant: 10),
            avatarView.centerXAnchor.constraint(equalTo: containerView.centerXAnchor),
            avatarView.widthAnchor.constraint(equalToConstant: 96),
            avatarView.heightAnchor.constraint(equalToConstant: 96),

            nameLabel.topAnchor.constraint(equalTo: avatarView.bottomAnchor, constant: 8),
            nameLabel.leadingAnchor.constraint(equalTo: containerView.leadingAnchor, constant: 8),
            nameLabel.trailingAnchor.constraint(equalTo: containerView.trailingAnchor, constant: -8),

            snippetLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            snippetLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            snippetLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            snippetLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -8),
        ])
    }

    func configure(with persona: Persona) {
        nameLabel.stringValue = persona.name.isEmpty ? "(unnamed)" : persona.name
        let trimmed = persona.description
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\n", with: " ")
        snippetLabel.stringValue = String(trimmed.prefix(80))
        if let avatarData = Storage.shared.loadPersonaAvatar(id: persona.id),
           let img = NSImage(data: avatarData) {
            avatarView.image = img
        } else {
            avatarView.image = placeholderAvatar(initials: persona.name)
        }
    }

    override var isSelected: Bool {
        didSet { applySelectionStyle() }
    }

    private func applySelectionStyle() {
        if isSelected {
            containerView.layer?.borderColor = NSColor.controlAccentColor.cgColor
            containerView.layer?.borderWidth = 2
            containerView.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.08).cgColor
        } else {
            containerView.layer?.borderColor = NSColor.separatorColor.cgColor
            containerView.layer?.borderWidth = 1
            containerView.layer?.backgroundColor = nil
        }
    }
}
