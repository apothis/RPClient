import AppKit

/// Phase 8 §4.3 — Cast inspector tab. Lists the chat's cast members as
/// rows (avatar + name + accent dot + Remove), with a `+ Add character`
/// popup at the bottom that pulls from `AppState.shared.characters`. The
/// cast list is the source of truth for who can be picked as next
/// speaker by `SpeakerPicker`; reordering / "convert to solo" affordances
/// stay deferred — the design doc §6.1 mentions them but §4.3's
/// minimal-UI commit ships add/remove only.
///
/// Free-form chats (`cast.count == 0` AND `characterId == nil`) show a
/// hint that adding any character bootstraps the cast. Solo chats
/// (`cast.count == 1`) show the lone member with no special framing —
/// adding a second member auto-promotes the chat to multi-cast (the
/// new assistant turns will start carrying speakerIds, see
/// `AppState.sendUserMessage`).
final class CastPane: NSViewController {
    private let scrollView = NSScrollView()
    private let stack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: "No chat selected.")
    private let addButton = NSPopUpButton()
    private let convertButton = NSButton()

    override func loadView() {
        let v = NSView()
        v.wantsLayer = true
        self.view = v

        emptyLabel.font = Theme.font(12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.isHidden = true
        v.addSubview(emptyLabel)

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        scrollView.documentView = stack
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        v.addSubview(scrollView)

        addButton.translatesAutoresizingMaskIntoConstraints = false
        addButton.target = self
        addButton.action = #selector(addCharacterPicked)
        v.addSubview(addButton)

        // Phase 8 deferred polish — "Convert to solo chat" button below
        // the +Add picker. Hidden when cast.count <= 1 (no point
        // collapsing a chat that's already solo or free-form).
        convertButton.title = "Convert to solo chat…"
        convertButton.bezelStyle = .rounded
        convertButton.controlSize = .small
        convertButton.target = self
        convertButton.action = #selector(convertToSoloPressed)
        convertButton.translatesAutoresizingMaskIntoConstraints = false
        convertButton.isHidden = true
        v.addSubview(convertButton)

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: v.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: v.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: v.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: addButton.topAnchor, constant: -8),

            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            stack.widthAnchor.constraint(equalTo: scrollView.contentView.widthAnchor),

            addButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            addButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            addButton.bottomAnchor.constraint(equalTo: convertButton.topAnchor, constant: -6),

            convertButton.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 8),
            convertButton.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -8),
            convertButton.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -8),

            emptyLabel.centerXAnchor.constraint(equalTo: v.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: v.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(greaterThanOrEqualTo: v.leadingAnchor, constant: 12),
            emptyLabel.trailingAnchor.constraint(lessThanOrEqualTo: v.trailingAnchor, constant: -12)
        ])

        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(rebuild),
                       name: AppNotification.currentChatChanged, object: nil)
        nc.addObserver(self, selector: #selector(rebuild),
                       name: AppNotification.chatUpdated, object: nil)
        rebuild()
    }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func rebuild() {
        for sub in stack.arrangedSubviews {
            stack.removeArrangedSubview(sub)
            sub.removeFromSuperview()
        }

        guard let chat = AppState.shared.currentChat else {
            emptyLabel.stringValue = "No chat selected."
            emptyLabel.isHidden = false
            scrollView.isHidden = true
            addButton.isHidden = true
            convertButton.isHidden = true
            return
        }
        emptyLabel.isHidden = true
        scrollView.isHidden = false
        addButton.isHidden = false
        convertButton.isHidden = chat.cast.count <= 1

        if chat.cast.isEmpty {
            let hint = NSTextField(labelWithString: "Free-form chat — add a character below to start a cast.")
            hint.font = Theme.font(12)
            hint.textColor = .secondaryLabelColor
            hint.lineBreakMode = .byWordWrapping
            hint.maximumNumberOfLines = 0
            hint.preferredMaxLayoutWidth = 240
            stack.addArrangedSubview(hint)
        } else {
            for (idx, cid) in chat.cast.enumerated() {
                let row = makeRow(characterId: cid, position: idx, total: chat.cast.count)
                stack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -16).isActive = true
            }
        }

        rebuildAddMenu(chat: chat)
    }

    private func makeRow(characterId: UUID, position: Int, total: Int) -> NSView {
        let row = NSView()
        row.wantsLayer = true

        let dot = NSView()
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 5
        dot.layer?.backgroundColor = SpeakerColor.accent(for: characterId).cgColor
        dot.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(dot)

        let avatar = NSImageView()
        let character = AppState.shared.character(id: characterId)
        avatar.image = AvatarSource.shared.image(
            forCharacter: characterId,
            name: character?.name ?? "?"
        )
        avatar.imageScaling = .scaleProportionallyUpOrDown
        avatar.wantsLayer = true
        avatar.layer?.cornerRadius = 12
        avatar.layer?.masksToBounds = true
        avatar.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(avatar)

        let name = NSTextField(labelWithString: character?.name ?? "Unknown character")
        name.font = Theme.font(13)
        name.lineBreakMode = .byTruncatingTail
        name.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(name)

        // Phase 8 deferred polish — up/down reorder arrows. Up disabled
        // on first row, down disabled on last row. Picked over native
        // drag-and-drop because NSStackView has no built-in drag
        // support and cast lists are tiny (typically 2-4 entries) —
        // arrow buttons are simpler, more accessible, and achieve the
        // same UX outcome (change `chat.cast` order, which drives
        // round-robin / picker order).
        let upButton = NSButton(image: NSImage(systemSymbolName: "chevron.up", accessibilityDescription: "Move up")!,
                                target: self, action: #selector(moveMemberUp(_:)))
        upButton.bezelStyle = .inline
        upButton.isBordered = false
        upButton.imagePosition = .imageOnly
        upButton.controlSize = .small
        upButton.tag = position
        upButton.isEnabled = position > 0
        upButton.translatesAutoresizingMaskIntoConstraints = false
        upButton.toolTip = "Move up — speaks earlier in the rotation"
        row.addSubview(upButton)

        let downButton = NSButton(image: NSImage(systemSymbolName: "chevron.down", accessibilityDescription: "Move down")!,
                                  target: self, action: #selector(moveMemberDown(_:)))
        downButton.bezelStyle = .inline
        downButton.isBordered = false
        downButton.imagePosition = .imageOnly
        downButton.controlSize = .small
        downButton.tag = position
        downButton.isEnabled = position < total - 1
        downButton.translatesAutoresizingMaskIntoConstraints = false
        downButton.toolTip = "Move down — speaks later in the rotation"
        row.addSubview(downButton)

        let remove = NSButton(title: "Remove", target: self, action: #selector(removeMember(_:)))
        remove.bezelStyle = .inline
        remove.controlSize = .small
        remove.identifier = NSUserInterfaceItemIdentifier(rawValue: characterId.uuidString)
        remove.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(remove)

        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: 28),

            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 2),
            dot.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 10),
            dot.heightAnchor.constraint(equalToConstant: 10),

            avatar.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 6),
            avatar.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            avatar.widthAnchor.constraint(equalToConstant: 24),
            avatar.heightAnchor.constraint(equalToConstant: 24),

            name.leadingAnchor.constraint(equalTo: avatar.trailingAnchor, constant: 8),
            name.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            name.trailingAnchor.constraint(lessThanOrEqualTo: upButton.leadingAnchor, constant: -8),

            upButton.trailingAnchor.constraint(equalTo: downButton.leadingAnchor, constant: -2),
            upButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            upButton.widthAnchor.constraint(equalToConstant: 18),

            downButton.trailingAnchor.constraint(equalTo: remove.leadingAnchor, constant: -6),
            downButton.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            downButton.widthAnchor.constraint(equalToConstant: 18),

            remove.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -2),
            remove.centerYAnchor.constraint(equalTo: row.centerYAnchor)
        ])
        return row
    }

    @objc private func moveMemberUp(_ sender: NSButton) {
        let from = sender.tag
        guard from > 0 else { return }
        AppState.shared.updateCurrent { c in
            c.reorderCast(from: from, to: from - 1)
        }
    }

    @objc private func moveMemberDown(_ sender: NSButton) {
        let from = sender.tag
        AppState.shared.updateCurrent { c in
            guard from < c.cast.count - 1 else { return }
            c.reorderCast(from: from, to: from + 1)
        }
    }

    @objc private func convertToSoloPressed() {
        guard let chat = AppState.shared.currentChat, chat.cast.count > 1 else { return }
        // Build an alert with one button per cast member ("Keep <name>")
        // plus Cancel. NSAlert renders buttons right-to-left, so the
        // first added button is the rightmost (default action). Cancel
        // goes last so it lands on the left.
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Convert to solo chat"
        alert.informativeText = """
        This reduces the cast to a single member. Existing turns from removed cast members stay in the chat — the speaker layer can still resolve their voice — but those characters won't appear in the round-robin or speaker picker.
        """
        // Add a "Keep" button per cast member, in cast order.
        var keepIds: [UUID] = []
        for cid in chat.cast {
            let name = AppState.shared.character(id: cid)?.name ?? "Unknown"
            alert.addButton(withTitle: "Keep \(name)")
            keepIds.append(cid)
        }
        alert.addButton(withTitle: "Cancel")
        let response = alert.runModal()
        // First button is .alertFirstButtonReturn (1000), second is 1001, …
        let pickedIdx = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard pickedIdx >= 0, pickedIdx < keepIds.count else { return }  // Cancel
        let kept = keepIds[pickedIdx]
        AppState.shared.updateCurrent { c in
            c.convertToSolo(keeping: kept)
        }
    }

    private func rebuildAddMenu(chat: Chat) {
        let menu = NSMenu()
        let title = NSMenuItem(title: "+ Add character…", action: nil, keyEquivalent: "")
        title.isEnabled = false
        menu.addItem(title)

        let castSet = Set(chat.cast)
        let candidates = AppState.shared.characters
            .filter { !castSet.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        if candidates.isEmpty {
            let empty = NSMenuItem(title: "(no characters available)", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            menu.addItem(NSMenuItem.separator())
            for c in candidates {
                let item = NSMenuItem(title: c.name.isEmpty ? "Untitled" : c.name,
                                      action: #selector(addCharacterPicked),
                                      keyEquivalent: "")
                item.target = self
                item.representedObject = c.id
                menu.addItem(item)
            }
        }
        addButton.menu = menu
        // Keep the placeholder visible (auto-selects index 0 = the
        // disabled "+ Add character…" header).
        addButton.selectItem(at: 0)
    }

    @objc private func addCharacterPicked() {
        guard let item = addButton.selectedItem,
              let cid = item.representedObject as? UUID else { return }
        let character = AppState.shared.character(id: cid)
        AppState.shared.updateCurrent { c in
            // Phase 8 §4.3 — solo→multi promotion-gap heal. If this add
            // takes cast.count from 1 to 2 (or higher), the validateGroupChat
            // invariant kicks in for assistant turns: every one must have
            // a non-nil speakerId resolving to the cast. Stamp pre-existing
            // assistant turns with the chat's primary character (the only
            // one in the room before this add) BEFORE the cast grows, so
            // the next save round-trips cleanly. Decode also heals this
            // case but eager-stamping keeps the on-disk JSON honest.
            let willBeMultiCast = !c.cast.contains(cid) && (c.cast.count + 1) > 1
            if willBeMultiCast, let primary = c.characterId ?? c.cast.first {
                for i in c.turns.indices {
                    if c.turns[i].role == .assistant && c.turns[i].speakerId == nil {
                        c.turns[i].speakerId = primary
                    }
                }
            }
            if !c.cast.contains(cid) {
                c.cast.append(cid)
            }
            // Free-form → solo promotion: also set characterId so legacy
            // single-character paths (PromptBuilder solo, voice routing,
            // Inspector tabs that read characterId) keep working until
            // we've fully removed the field. Mirrors the
            // characterId.didSet invariant in reverse.
            if c.characterId == nil {
                c.characterId = cid
            }
            // Phase 8 §4.5 — auto-create a stub entity for the added
            // character so the user can assign a voice to it via the
            // Entities pane immediately, without waiting for the fact
            // extractor to fire + accepting a suggestion. No-op if an
            // entity already matches the character's name (extractor-
            // created or hand-curated).
            if let character {
                c.ensureCharacterEntity(character)
            }
        }
        // Reset the popup to the "+ Add character…" placeholder.
        addButton.selectItem(at: 0)
    }

    @objc private func removeMember(_ sender: NSButton) {
        guard let raw = sender.identifier?.rawValue,
              let cid = UUID(uuidString: raw) else { return }
        AppState.shared.updateCurrent { c in
            c.cast.removeAll { $0 == cid }
            // If the removed member was the legacy chat-level character,
            // unbind it. Existing turns keep their speakerId — they just
            // resolve to nothing in the cast lookup, which the UI
            // surfaces as "Unknown character" (defensive, matches the
            // design doc §6.1 "no special teardown" rule).
            if c.characterId == cid {
                c.characterId = c.cast.first
            }
            if c.pendingSpeakerId == cid {
                c.pendingSpeakerId = nil
            }
        }
    }
}
