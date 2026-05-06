import Foundation
@testable import RPClientCore

/// Phase 8 §4.1 — group-chat storage + migration.
///
/// Covers the additions to `Chat` (`cast`, `speakerSelection`) and `Turn`
/// (`speakerId`), the v3→v4 cast-seeding migration that promotes a legacy
/// `characterId` into the first cast member, and the decode-time validation
/// that catches missing/dangling speakerIds on multi-cast chats.
///
/// Pure tests — no AppKit, no AppState. Mirrors `ChatBranchingTests` shape.
func phase8MigrationTests() -> TestSuite {
    let s = TestSuite("Phase8Migration")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    let nowStr = ISO8601DateFormatter().string(from: Date())

    // MARK: - Cast-seeding migration (v3 → v4)

    s.test("v3 chat with characterId set seeds cast = [characterId] and bumps to v4") {
        let chatId = UUID()
        let charId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Solo legacy",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [],
            "schemaVersion": 3,
            "characterId": "\(charId.uuidString)"
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.cast, [charId])
        try expectEqual(chat.schemaVersion, 4)
        try expectEqual(chat.characterId, charId)
    }

    s.test("v3 chat with characterId nil leaves cast empty and bumps to v4") {
        let chatId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Freeform legacy",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [],
            "schemaVersion": 3
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.cast, [])
        try expectEqual(chat.schemaVersion, 4)
        try expectNil(chat.characterId)
    }

    s.test("decoded chat defaults speakerSelection to .roundRobin") {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "x",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [],
            "schemaVersion": 3
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.speakerSelection, .roundRobin)
    }

    s.test("v4 chat with explicit cast round-trips identically") {
        let chatId = UUID()
        let castA = UUID()
        let castB = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Group",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [],
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)", "\(castB.uuidString)"],
            "speakerSelection": "pooled"
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.cast, [castA, castB])
        try expectEqual(chat.schemaVersion, 4)
        try expectEqual(chat.speakerSelection, .pooled)

        // Round-trip: encode, decode, expect same fields.
        let data = try encoder.encode(chat)
        let again = try decoder.decode(Chat.self, from: data)
        try expectEqual(again.cast, chat.cast)
        try expectEqual(again.speakerSelection, chat.speakerSelection)
        try expectEqual(again.schemaVersion, 4)
    }

    // MARK: - Turn.speakerId — decode + round-trip

    s.test("Turn.speakerId decodes when present and is nil when absent") {
        let speaker = UUID()
        let withSpeaker = """
        {
            "id": "\(UUID().uuidString)",
            "role": "assistant",
            "text": "hi",
            "ts": "\(nowStr)",
            "edited": false,
            "speakerId": "\(speaker.uuidString)"
        }
        """
        let withoutSpeaker = """
        {
            "id": "\(UUID().uuidString)",
            "role": "assistant",
            "text": "hi",
            "ts": "\(nowStr)",
            "edited": false
        }
        """
        let t1 = try decoder.decode(Turn.self, from: Data(withSpeaker.utf8))
        let t2 = try decoder.decode(Turn.self, from: Data(withoutSpeaker.utf8))
        try expectEqual(t1.speakerId, speaker)
        try expectNil(t2.speakerId)

        // Round-trip preserves both shapes.
        let r1 = try decoder.decode(Turn.self, from: encoder.encode(t1))
        let r2 = try decoder.decode(Turn.self, from: encoder.encode(t2))
        try expectEqual(r1.speakerId, speaker)
        try expectNil(r2.speakerId)
    }

    // MARK: - Multi-cast validation invariants

    s.test("v4 multi-cast chat throws when assistant turn has nil speakerId") {
        let chatId = UUID()
        let castA = UUID(), castB = UUID()
        let userTurnId = UUID(), asstTurnId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Group",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)", "\(castB.uuidString)"],
            "turns": [
                {"id": "\(userTurnId.uuidString)", "role": "user", "text": "hi", "ts": "\(nowStr)", "edited": false},
                {"id": "\(asstTurnId.uuidString)", "role": "assistant", "text": "hello", "ts": "\(nowStr)", "edited": false}
            ]
        }
        """
        try expectThrows("expected decode to throw on missing speakerId in multi-cast") {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("v4 chat throws when assistant turn speakerId is not in cast") {
        let chatId = UUID()
        let castA = UUID(), castB = UUID(), strangerId = UUID()
        let userTurnId = UUID(), asstTurnId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Group",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)", "\(castB.uuidString)"],
            "turns": [
                {"id": "\(userTurnId.uuidString)", "role": "user", "text": "hi", "ts": "\(nowStr)", "edited": false},
                {"id": "\(asstTurnId.uuidString)", "role": "assistant", "text": "hello", "ts": "\(nowStr)", "edited": false, "speakerId": "\(strangerId.uuidString)"}
            ]
        }
        """
        try expectThrows("expected decode to throw on dangling speakerId") {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("v4 chat throws when user turn carries a non-nil speakerId") {
        let chatId = UUID()
        let castA = UUID()
        let userTurnId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Solo",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)"],
            "turns": [
                {"id": "\(userTurnId.uuidString)", "role": "user", "text": "hi", "ts": "\(nowStr)", "edited": false, "speakerId": "\(castA.uuidString)"}
            ]
        }
        """
        try expectThrows("expected decode to throw on user turn with speakerId") {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("v4 chat throws on duplicate cast member") {
        let chatId = UUID()
        let castA = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Dupe",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)", "\(castA.uuidString)"],
            "turns": []
        }
        """
        try expectThrows("expected decode to throw on duplicate cast UUID") {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("v4 solo chat (cast.count == 1) tolerates nil speakerId on assistant turns") {
        // Back-compat: legacy single-character chats migrated forward have
        // cast = [characterId] and existing assistant turns with no speakerId.
        // Validation must NOT fire on cast.count <= 1.
        let chatId = UUID()
        let castA = UUID()
        let userTurnId = UUID(), asstTurnId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Migrated solo",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)"],
            "turns": [
                {"id": "\(userTurnId.uuidString)", "role": "user", "text": "hi", "ts": "\(nowStr)", "edited": false},
                {"id": "\(asstTurnId.uuidString)", "role": "assistant", "text": "hello", "ts": "\(nowStr)", "edited": false}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.cast.count, 1)
        try expectEqual(chat.turns.count, 2)
        try expectNil(chat.turns[1].speakerId)
    }

    s.test("v4 multi-cast chat with valid speakerIds decodes successfully") {
        let chatId = UUID()
        let castA = UUID(), castB = UUID()
        let userTurnId = UUID(), asstAId = UUID(), asstBId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)",
            "title": "Group OK",
            "created": "\(nowStr)",
            "modified": "\(nowStr)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 4,
            "cast": ["\(castA.uuidString)", "\(castB.uuidString)"],
            "turns": [
                {"id": "\(userTurnId.uuidString)", "role": "user", "text": "hi", "ts": "\(nowStr)", "edited": false},
                {"id": "\(asstAId.uuidString)", "role": "assistant", "text": "hi from A", "ts": "\(nowStr)", "edited": false, "speakerId": "\(castA.uuidString)"},
                {"id": "\(asstBId.uuidString)", "role": "assistant", "text": "hi from B", "ts": "\(nowStr)", "edited": false, "speakerId": "\(castB.uuidString)"}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.cast, [castA, castB])
        try expectEqual(chat.turns[1].speakerId, castA)
        try expectEqual(chat.turns[2].speakerId, castB)
    }

    // MARK: - validateGroupChat invoked directly

    s.test("validateGroupChat surfaces a diagnostic for missing speakerId") {
        let castA = UUID(), castB = UUID()
        let asst = Turn(role: .assistant, text: "x")
        do {
            try Chat.validateGroupChat(cast: [castA, castB], turns: [asst])
            throw TestFailure(message: "expected throw", file: #file, line: #line)
        } catch let DecodingError.dataCorrupted(ctx) {
            try expectTrue(
                ctx.debugDescription.contains("speakerId") ||
                ctx.debugDescription.contains("speaker"),
                "diagnostic should mention speaker: \(ctx.debugDescription)"
            )
        } catch {
            throw TestFailure(message: "unexpected error: \(error)", file: #file, line: #line)
        }
    }

    s.test("validateGroupChat surfaces a diagnostic for dangling speakerId") {
        let castA = UUID()
        let strangerId = UUID()
        var asst = Turn(role: .assistant, text: "x")
        asst.speakerId = strangerId
        do {
            try Chat.validateGroupChat(cast: [castA, UUID()], turns: [asst])
            throw TestFailure(message: "expected throw", file: #file, line: #line)
        } catch let DecodingError.dataCorrupted(ctx) {
            try expectTrue(
                ctx.debugDescription.contains(strangerId.uuidString) ||
                ctx.debugDescription.contains("cast"),
                "diagnostic should reference offending id or cast: \(ctx.debugDescription)"
            )
        } catch {
            throw TestFailure(message: "unexpected error: \(error)", file: #file, line: #line)
        }
    }

    s.test("validateGroupChat passes on solo cast with nil speakerId") {
        let castA = UUID()
        let asst = Turn(role: .assistant, text: "x")
        try Chat.validateGroupChat(cast: [castA], turns: [asst])
    }

    s.test("validateGroupChat passes on empty cast (free-form)") {
        let asst = Turn(role: .assistant, text: "x")
        try Chat.validateGroupChat(cast: [], turns: [asst])
    }

    s.test("validateGroupChat surfaces a diagnostic for user turn with speakerId") {
        let castA = UUID()
        var u = Turn(role: .user, text: "hi")
        u.speakerId = castA
        do {
            try Chat.validateGroupChat(cast: [castA], turns: [u])
            throw TestFailure(message: "expected throw", file: #file, line: #line)
        } catch let DecodingError.dataCorrupted(ctx) {
            try expectTrue(
                ctx.debugDescription.contains("user") ||
                ctx.debugDescription.contains("role"),
                "diagnostic should mention user role: \(ctx.debugDescription)"
            )
        } catch {
            throw TestFailure(message: "unexpected error: \(error)", file: #file, line: #line)
        }
    }

    return s
}
