import Foundation

/// Phase 9 §5.3a — the mutable working copy for the Card Creator window.
/// Encapsulates the three flows (create / edit-existing / import-and-edit)
/// behind a single `CharacterDraft` so the view layer doesn't branch on
/// origin. `flush(storage:)` is the only public mutation that writes —
/// everything else lives in memory and discards on cancel.
///
/// The draft holds both the `Character` Codable record and the avatar PNG
/// bytes (which live alongside the record on disk via `Storage`). Treating
/// the avatar as part of the draft is what makes a "Cancel" on an
/// import-and-edit flow truly discard everything (the imported PNG never
/// reaches `~/Library/Application Support/RPClient/characters/avatars/`).
final class CharacterDraft {

    enum Origin: Equatable {
        /// Fresh draft — no on-disk record. Save mints a new UUID and writes.
        case created
        /// Editing an existing on-disk Character. Save preserves the UUID
        /// and only writes the avatar when bytes differ from baseline.
        case editing(existingId: UUID)
        /// Imported from a PNG/JSON, not yet persisted. Save mints a new
        /// UUID and writes the imported PNG as the avatar (unless the
        /// author replaced it before saving).
        case importing(avatarPNG: Data?)
    }

    let origin: Origin
    var character: Character
    var avatarPNG: Data?
    private(set) var isDirty: Bool

    /// Snapshot of the avatar bytes at draft-construction time. Used by
    /// `.editing` mode to decide whether the avatar needs to be re-written
    /// on flush — byte-equal avatar → skip the disk write.
    private let avatarBaseline: Data?

    init(origin: Origin, character: Character, avatarPNG: Data?, isDirty: Bool) {
        self.origin = origin
        self.character = character
        self.avatarPNG = avatarPNG
        self.avatarBaseline = avatarPNG
        self.isDirty = isDirty
    }

    // MARK: - Factories

    static func newCreate() -> CharacterDraft {
        CharacterDraft(origin: .created, character: Character(), avatarPNG: nil, isDirty: false)
    }

    static func editing(_ c: Character, avatarPNG: Data?) -> CharacterDraft {
        CharacterDraft(
            origin: .editing(existingId: c.id),
            character: c,
            avatarPNG: avatarPNG,
            isDirty: false
        )
    }

    static func importing(_ result: CharacterCardImporter.Result) -> CharacterDraft {
        // Imports start dirty — the user hasn't committed yet. Save semantics
        // mint a new UUID and write the source PNG as the avatar.
        CharacterDraft(
            origin: .importing(avatarPNG: result.avatarPNG),
            character: result.character,
            avatarPNG: result.avatarPNG,
            isDirty: true
        )
    }

    // MARK: - Mutation

    func markDirty() {
        isDirty = true
    }

    // MARK: - Persistence

    /// Re-render the structured Details + Intimacy fence blocks into
    /// `character.description` so the prompt-builder sees them. Called
    /// just before `flush` writes to disk. Reads the live data from
    /// `extensions["rpclient/details"]` and `extensions["rpclient/intimacy"]`,
    /// merges them into the existing description (replacing any stale
    /// fences). Idempotent — safe to call repeatedly.
    func prepareForSave() {
        let details = CardDetails.extractFrom(character)
        let intimacy = CardIntimacy.extractFrom(character)
        character.description = CardStructuredFence.mergeIntoDescription(
            character.description,
            details: details,
            intimacy: intimacy
        )
    }

    /// Persist the draft. Returns the saved `Character.id` (newly-minted on
    /// `.created` / `.importing`, preserved on `.editing`).
    @discardableResult
    func flush(storage: CardStorage) -> UUID {
        prepareForSave()
        let id: UUID
        switch origin {
        case .created, .importing:
            // Mint a fresh UUID — but only if the existing Character.id
            // somehow matches the editing-baseline pattern. In practice
            // Character() generates a new UUID on construction, so the
            // draft's character.id is already fresh. Use it.
            id = character.id
        case .editing(let existingId):
            // Preserve the on-disk record's id even if a downstream
            // mutation accidentally rebound character.id.
            character = withId(character, id: existingId)
            id = existingId
        }

        storage.saveCharacter(character)

        // Avatar dispatch.
        switch origin {
        case .created, .importing:
            if let png = avatarPNG {
                DebugLog.shared.write("cardcreator: flush-avatar write \(png.count)B for \(id) (origin=\(origin))")
                storage.writeCharacterAvatar(png, for: id)
            } else {
                DebugLog.shared.write("cardcreator: flush-avatar skip (nil avatarPNG, origin=\(origin)) id=\(id)")
            }
        case .editing:
            switch (avatarBaseline, avatarPNG) {
            case (.some(let baseline), .some(let current)):
                if baseline != current {
                    DebugLog.shared.write("cardcreator: flush-avatar overwrite \(current.count)B for \(id) (baseline=\(baseline.count)B)")
                    storage.writeCharacterAvatar(current, for: id)
                } else {
                    DebugLog.shared.write("cardcreator: flush-avatar skip (byte-equal) id=\(id)")
                }
            case (.none, .some(let current)):
                DebugLog.shared.write("cardcreator: flush-avatar add \(current.count)B for \(id) (no baseline)")
                storage.writeCharacterAvatar(current, for: id)
            case (.some, .none):
                DebugLog.shared.write("cardcreator: flush-avatar delete for \(id) (cleared)")
                storage.deleteCharacterAvatarFile(for: id)
            case (.none, .none):
                break
            }
        }

        isDirty = false
        return id
    }

    private func withId(_ c: Character, id: UUID) -> Character {
        var copy = c
        // Character.id is `let` — round-trip via Codable to rebind. Cheap
        // for the rare editing-id-mismatch case; never on the create / import
        // hot paths.
        if copy.id != id {
            if let data = try? JSONEncoder().encode(copy),
               var dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                dict["id"] = id.uuidString
                if let patched = try? JSONSerialization.data(withJSONObject: dict),
                   let decoded = try? JSONDecoder().decode(Character.self, from: patched) {
                    copy = decoded
                }
            }
        }
        return copy
    }
}

/// Storage seam used by `CharacterDraft.flush(_:)`. Production passes
/// `Storage.shared` (which conforms via the extension below); tests pass a
/// stub. Keeps the draft pure-testable without mocking the real filesystem.
protocol CardStorage {
    func saveCharacter(_ c: Character)
    func writeCharacterAvatar(_ data: Data, for id: UUID)
    func deleteCharacterAvatarFile(for id: UUID)
}

extension Storage: CardStorage {
    func deleteCharacterAvatarFile(for id: UUID) {
        try? FileManager.default.removeItem(at: characterAvatarURL(id))
    }
}

/// Production conformance — routes `saveCharacter` through
/// `AppState.shared.saveCharacter(_:)` so the in-memory `characters` cache
/// stays in sync (and the Library window's `charactersChanged` listener
/// fires). Direct calls to `Storage.shared.saveCharacter` would only write
/// to disk; the cache wouldn't update until next launch — see §5.3a smoke
/// regression. Tests still use `Storage` (or a stub) for pure-logic coverage.
struct AppStateCardStorage: CardStorage {
    func saveCharacter(_ c: Character) {
        AppState.shared.saveCharacter(c)
    }
    func writeCharacterAvatar(_ data: Data, for id: UUID) {
        Storage.shared.writeCharacterAvatar(data, for: id)
    }
    func deleteCharacterAvatarFile(for id: UUID) {
        Storage.shared.deleteCharacterAvatarFile(for: id)
    }
}
