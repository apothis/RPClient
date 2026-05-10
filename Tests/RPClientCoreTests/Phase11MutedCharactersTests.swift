import Foundation
@testable import RPClientCore

/// V2_UI_OVERHAUL §4.k / §D.13 — per-character TTS mute. Schema
/// migration for chats persisted before this field existed +
/// pure-data helper used by both the speaker layer and TurnView.
func phase11MutedCharactersTests() -> TestSuite {
    let s = TestSuite("Phase11MutedCharacters")

    let alice = UUID()
    let bob = UUID()
    let carol = UUID()

    // MARK: - Helper: isMutedCharacter

    s.test("empty muted set → no character is muted") {
        var chat = Chat()
        chat.mutedCharacterIds = []
        try expectFalse(chat.isMutedCharacter(alice))
        try expectFalse(chat.isMutedCharacter(nil))
    }

    s.test("populated muted set returns true only for matching ids") {
        var chat = Chat()
        chat.mutedCharacterIds = [alice, bob]
        try expectTrue(chat.isMutedCharacter(alice))
        try expectTrue(chat.isMutedCharacter(bob))
        try expectFalse(chat.isMutedCharacter(carol))
    }

    s.test("nil character id is never muted (free-form / character-less chat)") {
        var chat = Chat()
        chat.mutedCharacterIds = [alice]
        try expectFalse(chat.isMutedCharacter(nil))
    }

    // MARK: - Codable migration

    s.test("legacy chat JSON without mutedCharacterIds decodes with empty set") {
        // Minimal pre-§4.k chat shape — schemaVersion 4 written before
        // the field existed. Decode must not crash; missing field
        // fills in as empty.
        let json = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Old chat",
            "created": -978307200,
            "modified": -978307200,
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "systemPromptMode": "override",
            "attributionMode": "heuristic",
            "speakerSelection": "roundRobin",
            "activePath": [],
            "cast": [],
            "turns": []
        }
        """.data(using: .utf8)!
        let dec = JSONDecoder()
        let chat = try dec.decode(Chat.self, from: json)
        try expectTrue(chat.mutedCharacterIds.isEmpty)
        try expectFalse(chat.isMutedCharacter(alice))
    }

    s.test("encode→decode round-trip preserves mutedCharacterIds") {
        var chat = Chat()
        chat.mutedCharacterIds = [alice, bob]
        let enc = JSONEncoder()
        let dec = JSONDecoder()
        let data = try enc.encode(chat)
        let restored = try dec.decode(Chat.self, from: data)
        try expectEqual(restored.mutedCharacterIds, Set([alice, bob]))
    }

    s.test("default-initialised chat has an empty muted set") {
        let chat = Chat()
        try expectTrue(chat.mutedCharacterIds.isEmpty)
    }

    return s
}
