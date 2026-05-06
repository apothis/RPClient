import AppKit
import UniformTypeIdentifiers

/// Phase 9 §5.3a / §3.6 — the avatar / display-image control on the
/// Identity tab. 128×128 thumbnail with 14pt corner radius, Choose / Remove
/// buttons below, drag-drop replace. Inputs funnel through
/// `Storage.normalizeAvatarData` (max 512px longest side, re-encoded PNG)
/// before landing in the draft, so the on-disk avatar is always normalized.
///
/// Design language: section-radius corners (14pt), `controlBackgroundColor`
/// fill with a 1pt separatorColor border by default, accent border on
/// drag-over (subtle focus-glow envelope per V2_DESIGN_LANGUAGE §11). No
/// in-window cropping; the author crops in their image editor before
/// drop-in (out of scope per V2_PHASE9_CARD_CREATOR §6).
final class AvatarControl: NSView {

    /// Called whenever the avatar bytes change (Choose, drag-drop, Remove).
    /// nil means the user cleared the avatar.
    var onChange: ((Data?) -> Void)?

    private let thumbnail = NSImageView()
    private let placeholderView = NSImageView()
    private let chooseButton = NSButton(title: "Choose image…", target: nil, action: nil)
    private let removeButton = NSButton(title: "Remove", target: nil, action: nil)
    private let formatHint = NSTextField(labelWithString: "PNG / JPEG / WebP / HEIC / GIF — auto-fit")

    private(set) var avatarData: Data?
    private var isDragOver = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        buildUI()
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        buildUI()
        registerForDraggedTypes([.fileURL])
    }

    private func buildUI() {
        wantsLayer = true
        translatesAutoresizingMaskIntoConstraints = false

        // Frame container — the visible 128×128 square.
        let frame = NSView()
        frame.wantsLayer = true
        frame.translatesAutoresizingMaskIntoConstraints = false
        frame.layer?.backgroundColor = DesignTokens.Background.group.cgColor
        frame.layer?.cornerRadius = DesignTokens.Radius.section
        frame.layer?.cornerCurve = .continuous
        frame.layer?.borderColor = NSColor.separatorColor.cgColor
        frame.layer?.borderWidth = 1
        addSubview(frame)

        // Placeholder glyph for empty state — SF Symbol `person.crop.circle`.
        if let img = NSImage(systemSymbolName: "person.crop.circle",
                             accessibilityDescription: "No image set") {
            let cfg = NSImage.SymbolConfiguration(pointSize: 56, weight: .regular)
                .applying(.init(paletteColors: [DesignTokens.Foreground.tertiary]))
            placeholderView.image = img.withSymbolConfiguration(cfg)
        }
        placeholderView.imageScaling = .scaleProportionallyUpOrDown
        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        frame.addSubview(placeholderView)

        // Avatar image view — overlaid on top, hidden when no avatar.
        thumbnail.imageScaling = .scaleProportionallyUpOrDown
        thumbnail.translatesAutoresizingMaskIntoConstraints = false
        thumbnail.wantsLayer = true
        thumbnail.layer?.cornerRadius = DesignTokens.Radius.section
        thumbnail.layer?.cornerCurve = .continuous
        thumbnail.layer?.masksToBounds = true
        thumbnail.isHidden = true
        frame.addSubview(thumbnail)

        chooseButton.target = self
        chooseButton.action = #selector(chooseImageClicked)
        chooseButton.bezelStyle = .rounded
        chooseButton.controlSize = .small
        chooseButton.translatesAutoresizingMaskIntoConstraints = false

        removeButton.target = self
        removeButton.action = #selector(removeClicked)
        removeButton.bezelStyle = .rounded
        removeButton.controlSize = .small
        removeButton.isEnabled = false
        removeButton.translatesAutoresizingMaskIntoConstraints = false

        let buttonRow = NSStackView(views: [chooseButton, removeButton])
        buttonRow.orientation = .horizontal
        buttonRow.spacing = DesignTokens.Spacing.sm
        buttonRow.translatesAutoresizingMaskIntoConstraints = false
        addSubview(buttonRow)

        formatHint.font = DesignTokens.Typography.subheadline
        formatHint.textColor = DesignTokens.Foreground.tertiary
        formatHint.lineBreakMode = .byWordWrapping
        formatHint.maximumNumberOfLines = 2
        formatHint.translatesAutoresizingMaskIntoConstraints = false
        addSubview(formatHint)

        NSLayoutConstraint.activate([
            // Frame at the top, fixed 128×128.
            frame.topAnchor.constraint(equalTo: topAnchor),
            frame.centerXAnchor.constraint(equalTo: centerXAnchor),
            frame.widthAnchor.constraint(equalToConstant: 128),
            frame.heightAnchor.constraint(equalToConstant: 128),

            placeholderView.centerXAnchor.constraint(equalTo: frame.centerXAnchor),
            placeholderView.centerYAnchor.constraint(equalTo: frame.centerYAnchor),
            placeholderView.widthAnchor.constraint(equalToConstant: 56),
            placeholderView.heightAnchor.constraint(equalToConstant: 56),

            thumbnail.topAnchor.constraint(equalTo: frame.topAnchor),
            thumbnail.leadingAnchor.constraint(equalTo: frame.leadingAnchor),
            thumbnail.trailingAnchor.constraint(equalTo: frame.trailingAnchor),
            thumbnail.bottomAnchor.constraint(equalTo: frame.bottomAnchor),

            // Buttons below the frame, sm gap.
            buttonRow.topAnchor.constraint(equalTo: frame.bottomAnchor, constant: DesignTokens.Spacing.sm),
            buttonRow.centerXAnchor.constraint(equalTo: centerXAnchor),

            // Format hint below buttons, xs gap.
            formatHint.topAnchor.constraint(equalTo: buttonRow.bottomAnchor, constant: DesignTokens.Spacing.xs),
            formatHint.leadingAnchor.constraint(equalTo: leadingAnchor),
            formatHint.trailingAnchor.constraint(equalTo: trailingAnchor),
            formatHint.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),

            widthAnchor.constraint(equalToConstant: 168),
        ])
    }

    // MARK: - Public mutation

    /// Set the avatar bytes. Routes through `Storage.normalizeAvatarData`
    /// to enforce the 512px cap and PNG re-encode. Fires `onChange`.
    func setAvatar(_ data: Data?) {
        if let raw = data, let normalized = Storage.normalizeAvatarData(raw) {
            avatarData = normalized
        } else if data == nil {
            avatarData = nil
        } else {
            // Decoder failed — surface the error via the `onChange`
            // contract by leaving state untouched and not firing.
            DebugLog.shared.write("avatar: ⚠ couldn't decode image bytes (\(data?.count ?? 0)B)")
            return
        }
        refreshDisplay()
        onChange?(avatarData)
    }

    /// Set the avatar without re-running normalization (use when loading
    /// already-on-disk PNG bytes that were normalized at write time). Does
    /// *not* fire `onChange` — for initial state-load only.
    func loadAvatarUnchecked(_ data: Data?) {
        avatarData = data
        refreshDisplay()
    }

    private func refreshDisplay() {
        if let bytes = avatarData, let image = NSImage(data: bytes) {
            thumbnail.image = image
            thumbnail.isHidden = false
            placeholderView.isHidden = true
            removeButton.isEnabled = true
        } else {
            thumbnail.image = nil
            thumbnail.isHidden = true
            placeholderView.isHidden = false
            removeButton.isEnabled = false
        }
    }

    // MARK: - Actions

    @objc private func chooseImageClicked() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.png, .jpeg, .webP, .heic, .gif, .bmp]
        panel.message = "Choose an image for this character. Resized to fit (longest side ≤ 512px)."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let data = try? Data(contentsOf: url) else {
            NSAlert.showSimple(message: "Couldn't read that image",
                               info: "The file at \(url.lastPathComponent) couldn't be loaded.")
            return
        }
        setAvatar(data)
    }

    @objc private func removeClicked() {
        guard avatarData != nil else { return }
        let alert = NSAlert()
        alert.messageText = "Remove avatar?"
        alert.informativeText = "The image will be cleared from this card. Save the card to commit the change."
        alert.addButton(withTitle: "Remove")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        if alert.runModal() == .alertFirstButtonReturn {
            setAvatar(nil)
        }
    }

    // MARK: - Drag-drop

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard hasImageURL(sender) else { return [] }
        isDragOver = true
        animateBorder(toAccent: true)
        return .copy
    }

    override func draggingExited(_ sender: NSDraggingInfo?) {
        isDragOver = false
        animateBorder(toAccent: false)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        defer { animateBorder(toAccent: false); isDragOver = false }
        guard let url = imageURL(sender),
              let data = try? Data(contentsOf: url) else { return false }
        setAvatar(data)
        return true
    }

    private func hasImageURL(_ info: NSDraggingInfo) -> Bool {
        imageURL(info) != nil
    }

    private func imageURL(_ info: NSDraggingInfo) -> URL? {
        guard let urls = info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: nil) as? [URL] else {
            return nil
        }
        return urls.first(where: { url in
            guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return false }
            return [UTType.png, .jpeg, .webP, .heic, .gif, .bmp].contains(where: { type.conforms(to: $0) })
        })
    }

    private func animateBorder(toAccent: Bool) {
        guard let frameLayer = subviews.first?.layer else { return }
        let target = toAccent ? DesignTokens.Foreground.accent.cgColor : NSColor.separatorColor.cgColor
        let anim = CABasicAnimation(keyPath: "borderColor")
        anim.fromValue = frameLayer.borderColor
        anim.toValue = target
        anim.duration = DesignTokens.Motion.hoverFade
        frameLayer.add(anim, forKey: "borderColor")
        frameLayer.borderColor = target
    }
}

/// Small NSAlert convenience — one-button informational alert.
private extension NSAlert {
    static func showSimple(message: String, info: String) {
        let a = NSAlert()
        a.messageText = message
        a.informativeText = info
        a.runModal()
    }
}
