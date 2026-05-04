import AppKit

/// Single tile in the Library window's Characters grid (Phase 3 §4.3).
/// `NSCollectionViewItem` keeps the integration with `NSCollectionView` boring
/// — `LibraryWindowController` only has to implement `numberOfItemsInSection`
/// + `itemForRepresentedObjectAt`. Selection state is handled by AppKit;
/// `isSelected` flips the border accent.
final class CharacterCardView: NSCollectionViewItem {
    static let reuseId = NSUserInterfaceItemIdentifier("CharacterCardView")
    static let itemSize = NSSize(width: 140, height: 180)

    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
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
        avatarView.layer?.cornerRadius = 6
        avatarView.layer?.masksToBounds = true
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(avatarView)

        nameLabel.font = Theme.bold(12)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.alignment = .center
        nameLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(nameLabel)

        metaLabel.font = Theme.font(10)
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.alignment = .center
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(metaLabel)

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

            metaLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            metaLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            metaLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
            metaLabel.bottomAnchor.constraint(lessThanOrEqualTo: containerView.bottomAnchor, constant: -8),
        ])
    }

    func configure(with character: Character) {
        nameLabel.stringValue = character.name
        let tagSummary = character.tags.prefix(2).joined(separator: " · ")
        let creator = character.creator.map { "by \($0)" } ?? ""
        let parts = [tagSummary, creator].filter { !$0.isEmpty }
        metaLabel.stringValue = parts.joined(separator: " · ")
        if let avatarData = Storage.shared.loadCharacterAvatar(id: character.id),
           let img = NSImage(data: avatarData) {
            avatarView.image = img
        } else {
            avatarView.image = placeholderAvatar(initials: character.name)
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

/// Render a 96×96 square with the first two letters of `initials` centered on
/// a tinted background. Cheap stand-in when a card has no avatar (e.g. raw
/// `.json` import or persona with no upload).
func placeholderAvatar(initials raw: String) -> NSImage {
    let size = NSSize(width: 96, height: 96)
    let img = NSImage(size: size)
    img.lockFocus()
    let bg = NSColor.controlAccentColor.withAlphaComponent(0.25)
    bg.setFill()
    NSRect(origin: .zero, size: size).fill()
    let trimmed = raw.trimmingCharacters(in: .whitespaces)
    let letters: String = {
        if trimmed.isEmpty { return "?" }
        let parts = trimmed.split(separator: " ").prefix(2)
        return parts.compactMap { $0.first.map(String.init) }.joined().uppercased()
    }()
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 36, weight: .semibold),
        .foregroundColor: NSColor.labelColor,
        .paragraphStyle: para,
    ]
    let str = NSAttributedString(string: letters, attributes: attrs)
    let h = str.size().height
    str.draw(in: NSRect(x: 0, y: (size.height - h) / 2, width: size.width, height: h))
    img.unlockFocus()
    return img
}
