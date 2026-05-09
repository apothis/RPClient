import AppKit

protocol EmptyStateViewDelegate: AnyObject {
    func emptyStateDidPickStarter(_ view: EmptyStateView, text: String)
}

/// V2_UI_OVERHAUL §4.6 — empty-state for a fresh chat. Centred avatar
/// + name + scenario one-liner above the composer (composer itself
/// lives elsewhere; this view sits in the transcript area). Three
/// stacked suggestion chips below the composer-shaped gap.
///
/// `configure(character:)` re-skins the view per the bound character:
/// avatar from AvatarSource, name as title, scenario as subtitle.
/// On free-form chats (no character bound) a `person.crop.circle` SF
/// Symbol stands in (V2_DESIGN_LANGUAGE §10 anti-pattern fix —
/// replaces the legacy `✦` glyph).
final class EmptyStateView: NSView {
    weak var delegate: EmptyStateViewDelegate?

    private let avatar = NSImageView()
    private let title = NSTextField(labelWithString: "Start a new chat")
    private let subtitle = NSTextField(labelWithString: "Send a message to begin")
    private let chipsStack = NSStackView()

    /// Static-fallback chip starters used when the bound character has
    /// no scenario / alternate-greetings to seed from. Generic but
    /// neutral — the character-sourced chips are the path that gets
    /// the user into a scene faster.
    private let staticStarters: [String] = [
        "Set the scene",
        "Continue from where we left off",
        "Surprise me"
    ]

    /// Diameter of the centred character avatar. 64pt — bigger than
    /// the per-turn 32pt gutter avatar so it reads as "this is the
    /// character you're about to chat with", not just metadata.
    private let avatarSize: CGFloat = 64

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true

        avatar.imageScaling = .scaleProportionallyUpOrDown
        // Tint applies to SF-Symbol template images (the no-character
        // person.crop.circle fallback) AND to bitmap avatars where it
        // has no effect — safe either way. Without this the symbol
        // rendered with no fill, looking invisible.
        avatar.contentTintColor = .secondaryLabelColor
        avatar.wantsLayer = true
        // Bitmap character avatars are square — clip to a circle.
        // The SF-Symbol fallback is already circular so the clip is a
        // no-op for it.
        avatar.layer?.cornerRadius = avatarSize / 2
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(avatar)

        title.font = DesignTokens.Typography.title2
        title.textColor = .labelColor
        title.alignment = .center
        title.lineBreakMode = .byTruncatingTail
        title.maximumNumberOfLines = 1
        title.translatesAutoresizingMaskIntoConstraints = false
        addSubview(title)

        subtitle.font = DesignTokens.Typography.body
        subtitle.textColor = .secondaryLabelColor
        subtitle.alignment = .center
        subtitle.lineBreakMode = .byWordWrapping
        subtitle.maximumNumberOfLines = 2
        subtitle.preferredMaxLayoutWidth = 480
        subtitle.translatesAutoresizingMaskIntoConstraints = false
        addSubview(subtitle)

        chipsStack.orientation = .vertical
        chipsStack.spacing = DesignTokens.Spacing.sm
        chipsStack.alignment = .centerX
        chipsStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(chipsStack)

        for s in staticStarters {
            let btn = ChipButton(title: s)
            btn.target = self
            btn.action = #selector(chipTapped(_:))
            chipsStack.addArrangedSubview(btn)
        }

        // V2_UI_OVERHAUL §4.6 — bifurcated layout:
        //   • avatar + title + subtitle pinned near the top of the
        //     empty state (top-anchor with breathing room).
        //   • chips pinned to the bottom (just above where the composer
        //     sits in the chat-pane stack — composer is outside this view).
        // The pre-fixup `centerYAnchor.constraint(constant: -100)` placed
        // the avatar 100pt above centre, which pushed it offscreen when
        // the empty state was shorter than ~264pt. Top-anchored breathing
        // room is height-independent.
        NSLayoutConstraint.activate([
            avatar.centerXAnchor.constraint(equalTo: centerXAnchor),
            avatar.topAnchor.constraint(equalTo: topAnchor, constant: DesignTokens.Spacing.xl * 2),
            avatar.widthAnchor.constraint(equalToConstant: avatarSize),
            avatar.heightAnchor.constraint(equalToConstant: avatarSize),

            title.centerXAnchor.constraint(equalTo: centerXAnchor),
            title.topAnchor.constraint(equalTo: avatar.bottomAnchor, constant: DesignTokens.Spacing.md),
            title.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DesignTokens.Spacing.lg),
            title.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignTokens.Spacing.lg),

            subtitle.centerXAnchor.constraint(equalTo: centerXAnchor),
            subtitle.topAnchor.constraint(equalTo: title.bottomAnchor, constant: DesignTokens.Spacing.xs),
            subtitle.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DesignTokens.Spacing.lg),
            subtitle.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignTokens.Spacing.lg),

            chipsStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            chipsStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -DesignTokens.Spacing.xl),
            chipsStack.topAnchor.constraint(greaterThanOrEqualTo: subtitle.bottomAnchor, constant: DesignTokens.Spacing.lg),
            chipsStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: DesignTokens.Spacing.md),
            chipsStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -DesignTokens.Spacing.md)
        ])

        configure(character: nil)
    }

    required init?(coder: NSCoder) { nil }

    /// V2_UI_OVERHAUL §4.6 — re-skin per bound character. Pass nil for
    /// free-form chats (no character) — falls back to the SF Symbol
    /// person glyph + generic copy. Called by ChatViewController when
    /// the empty state is installed for a chat.
    func configure(character: Character?) {
        if let c = character {
            avatar.image = AvatarSource.shared.image(forCharacter: c.id, name: c.name)
            avatar.toolTip = c.name
            title.stringValue = c.name
            let scenario = c.scenario.trimmingCharacters(in: .whitespacesAndNewlines)
            subtitle.stringValue = scenario.isEmpty
                ? "Send a message to begin"
                : scenario
        } else {
            avatar.image = EmptyStateView.makePlaceholderAvatar(size: avatarSize)
            avatar.toolTip = nil
            title.stringValue = "Start a new chat"
            subtitle.stringValue = "Send a message to begin"
        }
    }

    /// SF Symbol fallback for free-form chats — same `person.crop.circle`
    /// glyph the assistant TurnView uses when no character is bound
    /// (V2_UI_OVERHAUL §4.0.h replacement for the legacy `✦`).
    private static func makePlaceholderAvatar(size: CGFloat) -> NSImage {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .light)
        if let img = NSImage(
            systemSymbolName: "person.crop.circle",
            accessibilityDescription: "No character"
        )?.withSymbolConfiguration(cfg) {
            return img
        }
        return NSImage()
    }

    @objc private func chipTapped(_ sender: ChipButton) {
        delegate?.emptyStateDidPickStarter(self, text: sender.title)
    }
}

private final class ChipButton: NSButton {
    init(title: String) {
        super.init(frame: .zero)
        self.title = title
        bezelStyle = .inline
        isBordered = false
        wantsLayer = true
        font = DesignTokens.Typography.body
        contentTintColor = .labelColor
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 32).isActive = true
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        // controlBackgroundColor + separatorColor border resolved at
        // draw time so light/dark switches the chip correctly. Mirrors
        // the CapsulePill pattern used for the per-turn pills (4.d).
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
        layer?.borderColor = NSColor.separatorColor.cgColor
        layer?.borderWidth = 0.5
        layer?.cornerRadius = 16
    }

    override var intrinsicContentSize: NSSize {
        var s = super.intrinsicContentSize
        s.width += 32
        return s
    }
}
