import Foundation
@testable import RPClientCore

/// Phase 6 §7.2b: `Entity.voice: VoicePreference?`.
///
/// Migration: existing entities persisted before §7.2 have no `voice` key;
/// they must decode with `voice == nil` so the speaker layer falls back to
/// the chat-default voice. New entities round-trip the field. The decoder
/// path is the load-bearing one — encoding a nil `voice` is allowed to
/// either omit or write null; the decoder tolerates both.
func entityVoiceTests() -> TestSuite {
    let s = TestSuite("Entity.voice migration")

    s.test("old-shape JSON without voice decodes as nil") {
        let oldJson = #"""
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "name": "Sage",
            "aliases": ["The mage"],
            "type": "character",
            "facts": [],
            "pinnedByUser": true,
            "createdTurn": 4
        }
        """#.data(using: .utf8)!
        let entity = try JSONDecoder().decode(Entity.self, from: oldJson)
        try expectEqual(entity.name, "Sage")
        try expectNil(entity.voice)
    }

    s.test("new-shape JSON with voice round-trips") {
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "bf_isabella"),
            rate: 1.1,
            pitch: 0.95
        )
        let entity = Entity(
            name: "Isabella",
            type: .character,
            pinnedByUser: true
        ).with(voice: pref)

        let data = try JSONEncoder().encode(entity)
        let decoded = try JSONDecoder().decode(Entity.self, from: data)
        try expectEqual(decoded.voice, pref)
        try expectEqual(decoded.name, "Isabella")
    }

    s.test("explicit null voice decodes as nil") {
        let json = #"""
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "name": "Narrator",
            "aliases": [],
            "type": "character",
            "facts": [],
            "pinnedByUser": false,
            "createdTurn": 0,
            "voice": null
        }
        """#.data(using: .utf8)!
        let entity = try JSONDecoder().decode(Entity.self, from: json)
        try expectNil(entity.voice)
    }

    s.test("malformed voice on an entity rejects the whole entity") {
        // A persisted voice with a corrupt voiceIdentifier is unusable; we'd
        // rather throw than silently drop the preference and bind the user
        // to the wrong voice.
        let json = #"""
        {
            "id": "33333333-3333-3333-3333-333333333333",
            "name": "Bad",
            "aliases": [],
            "type": "character",
            "facts": [],
            "pinnedByUser": false,
            "createdTurn": 0,
            "voice": {"voiceIdentifier": "not-an-id", "rate": 1.0, "pitch": 1.0}
        }
        """#.data(using: .utf8)!
        var threw = false
        do {
            _ = try JSONDecoder().decode(Entity.self, from: json)
        } catch {
            threw = true
        }
        try expectTrue(threw, "Entity decoder should propagate malformed VoicePreference")
    }

    return s
}

private extension Entity {
    func with(voice: VoicePreference?) -> Entity {
        var copy = self
        copy.voice = voice
        return copy
    }
}
