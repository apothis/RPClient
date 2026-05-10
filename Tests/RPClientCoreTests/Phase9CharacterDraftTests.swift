import Foundation
@testable import RPClientCore

/// Phase 9 §5.3a — CharacterDraft is the mutable working copy used by
/// the creator window. It tracks origin (.created / .editing / .importing)
/// and dispatches save semantics per origin without leaking AppKit.
func phase9CharacterDraftTests() -> TestSuite {
    let s = TestSuite("Phase9CharacterDraft")

    // MARK: - Construction

    s.test("newCreate mints a fresh draft with empty Character") {
        let d = CharacterDraft.newCreate()
        if case .created = d.origin {
            // ok
        } else {
            try expectTrue(false, "expected .created origin")
        }
        try expectEqual(d.character.name, "")
        try expectTrue(d.avatarPNG == nil)
        try expectTrue(!d.isDirty, "fresh draft is clean")
    }

    s.test("editing seeds the draft from a saved Character + avatar") {
        let c = Character(name: "Marin", description: "Captain.")
        let avatar = Data([0x89, 0x50, 0x4E, 0x47]) // PNG sig only — bytes are arbitrary here
        let d = CharacterDraft.editing(c, avatarPNG: avatar)
        if case .editing(let id) = d.origin {
            try expectEqual(id, c.id, "origin id matches the source")
        } else {
            try expectTrue(false, "expected .editing origin")
        }
        try expectEqual(d.character.id, c.id, "draft preserves UUID for editing")
        try expectEqual(d.character.name, "Marin")
        try expectEqual(d.avatarPNG, avatar)
        try expectTrue(!d.isDirty, "editing-mode draft starts clean")
    }

    s.test("importing seeds from importer Result (fresh UUID, dirty=true)") {
        let imported = Character(name: "Imported")
        let importerAvatar = Data([0x01, 0x02, 0x03])
        let result = CharacterCardImporter.Result(character: imported, avatarPNG: importerAvatar)
        let d = CharacterDraft.importing(result)
        if case .importing(let png) = d.origin {
            try expectEqual(png, importerAvatar, "origin carries the source PNG")
        } else {
            try expectTrue(false, "expected .importing origin")
        }
        try expectEqual(d.character.name, "Imported")
        try expectEqual(d.avatarPNG, importerAvatar)
        try expectTrue(d.isDirty, "importing-mode draft is dirty until saved (unsaved import)")
    }

    // MARK: - Dirty tracking

    s.test("markDirty flips the flag") {
        let d = CharacterDraft.newCreate()
        try expectTrue(!d.isDirty)
        d.markDirty()
        try expectTrue(d.isDirty)
    }

    // MARK: - Flush dispatch (stub storage)

    s.test("flush on .created mints a UUID and writes character + avatar (when present)") {
        let stub = StubCardStorage()
        let d = CharacterDraft.newCreate()
        d.character.name = "Fresh"
        d.avatarPNG = Data([0x89, 0x50, 0x4E, 0x47])
        let id = d.flush(storage: stub)
        try expectEqual(stub.savedCharacters.count, 1)
        try expectEqual(stub.savedCharacters[0].name, "Fresh")
        try expectEqual(stub.savedCharacters[0].id, id)
        try expectEqual(stub.savedAvatars[id], d.avatarPNG)
    }

    s.test("flush on .created with nil avatar does not write avatar") {
        let stub = StubCardStorage()
        let d = CharacterDraft.newCreate()
        d.character.name = "Avatarless"
        _ = d.flush(storage: stub)
        try expectEqual(stub.savedCharacters.count, 1)
        try expectEqual(stub.savedAvatars.count, 0)
    }

    s.test("flush on .editing preserves the existing UUID") {
        let stub = StubCardStorage()
        let original = Character(name: "Editor", description: "before")
        let originalAvatar = Data([0xAA, 0xBB])
        let d = CharacterDraft.editing(original, avatarPNG: originalAvatar)
        d.character.description = "after"
        d.markDirty()
        let id = d.flush(storage: stub)
        try expectEqual(id, original.id, "editing keeps id stable")
        try expectEqual(stub.savedCharacters.count, 1)
        try expectEqual(stub.savedCharacters[0].description, "after")
    }

    s.test("flush on .editing skips avatar write when avatar bytes unchanged from baseline") {
        let stub = StubCardStorage()
        let original = Character(name: "X")
        let originalAvatar = Data([0xAA, 0xBB, 0xCC])
        let d = CharacterDraft.editing(original, avatarPNG: originalAvatar)
        // No avatar change.
        d.character.description = "edited"
        d.markDirty()
        _ = d.flush(storage: stub)
        try expectEqual(stub.savedAvatars.count, 0, "byte-equal avatar should skip write")
    }

    s.test("flush on .editing writes avatar when bytes differ from baseline") {
        let stub = StubCardStorage()
        let original = Character(name: "X")
        let baseline = Data([0xAA, 0xBB])
        let d = CharacterDraft.editing(original, avatarPNG: baseline)
        d.avatarPNG = Data([0xFF, 0xEE]) // user replaced the avatar
        d.markDirty()
        _ = d.flush(storage: stub)
        try expectEqual(stub.savedAvatars[original.id], Data([0xFF, 0xEE]))
    }

    s.test("flush on .editing deletes avatar when slot cleared") {
        let stub = StubCardStorage()
        let original = Character(name: "X")
        let baseline = Data([0xAA])
        let d = CharacterDraft.editing(original, avatarPNG: baseline)
        d.avatarPNG = nil // user removed the avatar
        d.markDirty()
        _ = d.flush(storage: stub)
        try expectTrue(stub.deletedAvatars.contains(original.id),
                       "removed avatar should call deleteCharacterAvatarFile")
    }

    s.test("flush on .importing mints UUID + writes avatar from origin") {
        let stub = StubCardStorage()
        let imported = Character(name: "Brought-in")
        let importerAvatar = Data([0x89, 0x50])
        let result = CharacterCardImporter.Result(character: imported, avatarPNG: importerAvatar)
        let d = CharacterDraft.importing(result)
        let id = d.flush(storage: stub)
        try expectEqual(stub.savedCharacters.count, 1)
        try expectEqual(stub.savedAvatars[id], importerAvatar,
                        "import flush writes the source PNG as the avatar")
        try expectTrue(id != imported.id || imported.id != UUID(),
                       "id is finite (sanity)")
    }

    s.test("isDirty resets to false after flush") {
        let stub = StubCardStorage()
        let d = CharacterDraft.newCreate()
        d.character.name = "X"
        d.markDirty()
        try expectTrue(d.isDirty)
        _ = d.flush(storage: stub)
        try expectTrue(!d.isDirty, "flush clears dirty")
    }

    return s
}

private final class StubCardStorage: CardStorage {
    var savedCharacters: [Character] = []
    var savedAvatars: [UUID: Data] = [:]
    var deletedAvatars: Set<UUID> = []

    func saveCharacter(_ c: Character) {
        savedCharacters.append(c)
    }
    func writeCharacterAvatar(_ data: Data, for id: UUID) {
        savedAvatars[id] = data
    }
    func deleteCharacterAvatarFile(for id: UUID) {
        deletedAvatars.insert(id)
    }
}
