import Foundation
@testable import RPClientCore

/// Phase 7 §3.2 — SceneSummary migration from `firstTurn/lastTurn: Int?`
/// to `firstTurnId/lastTurnId: UUID?`.
///
/// Strategy: SceneSummary carries both shapes during the migration window.
/// New writes populate only the UUID fields; legacy decoded scenes have
/// only the Int fields. `Chat.init(from:)`'s post-pass resolves the Ints
/// to UUIDs against the spine activePath. Readers go through
/// `firstTurnPosition(in:)` / `lastTurnPosition(in:)` which prefer UUID
/// resolution against the current active path and fall back to the legacy
/// Int when UUID is unavailable.
///
/// Pre-Phase-7 chats migrate cleanly because the spine activePath has
/// `activePath[idx] == turns[idx].id` — Int N maps to the Nth turn's UUID
/// unambiguously.
func sceneSummaryMigrationTests() -> TestSuite {
    let s = TestSuite("SceneSummaryMigration")

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

    // MARK: - SceneSummary field-level migration

    s.test("legacy SceneSummary JSON with firstTurn/lastTurn Ints decodes into Int fields") {
        let json = """
        { "text": "scene", "firstTurn": 2, "lastTurn": 5 }
        """
        let scene = try decoder.decode(SceneSummary.self, from: Data(json.utf8))
        try expectEqual(scene.text, "scene")
        try expectEqual(scene.firstTurn, 2)
        try expectEqual(scene.lastTurn, 5)
        try expectEqual(scene.firstTurnId, nil)
        try expectEqual(scene.lastTurnId, nil)
    }

    s.test("new SceneSummary JSON with firstTurnId/lastTurnId UUIDs decodes into UUID fields") {
        let id1 = UUID(), id2 = UUID()
        let json = """
        { "text": "scene", "firstTurnId": "\(id1.uuidString)", "lastTurnId": "\(id2.uuidString)" }
        """
        let scene = try decoder.decode(SceneSummary.self, from: Data(json.utf8))
        try expectEqual(scene.firstTurnId, id1)
        try expectEqual(scene.lastTurnId, id2)
    }

    s.test("SceneSummary with no positional fields decodes with all nil") {
        let json = """
        { "text": "naked" }
        """
        let scene = try decoder.decode(SceneSummary.self, from: Data(json.utf8))
        try expectEqual(scene.firstTurn, nil)
        try expectEqual(scene.lastTurn, nil)
        try expectEqual(scene.firstTurnId, nil)
        try expectEqual(scene.lastTurnId, nil)
    }

    s.test("SceneSummary round-trip preserves both Int and UUID fields when both are set") {
        let id1 = UUID(), id2 = UUID()
        var scene = SceneSummary(text: "both", firstTurn: 1, lastTurn: 4)
        scene.firstTurnId = id1
        scene.lastTurnId = id2
        let data = try encoder.encode(scene)
        let decoded = try decoder.decode(SceneSummary.self, from: data)
        try expectEqual(decoded.firstTurn, 1)
        try expectEqual(decoded.lastTurn, 4)
        try expectEqual(decoded.firstTurnId, id1)
        try expectEqual(decoded.lastTurnId, id2)
    }

    // MARK: - Chat.init post-pass: legacy Int → UUID resolution against spine

    s.test("Chat.init resolves legacy SceneSummary Ints to UUIDs via the spine activePath") {
        // Legacy chat with three turns and a scene summary covering turns 0–1.
        // After Chat.init's spine migration, activePath = [t0.id, t1.id, t2.id]
        // and the SceneSummary's legacy Ints (0, 1) should be resolved to
        // (t0.id, t1.id) on the new UUID fields.
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID(), id2 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false},
                {"id": "\(id1.uuidString)", "role": "assistant", "text": "b", "ts": "\(now)", "edited": false},
                {"id": "\(id2.uuidString)", "role": "user", "text": "c", "ts": "\(now)", "edited": false}
            ],
            "sceneSummaries": [
                {"text": "arc1", "firstTurn": 0, "lastTurn": 1}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.sceneSummaries.count, 1)
        let scene = chat.sceneSummaries[0]
        try expectEqual(scene.firstTurnId, id0)
        try expectEqual(scene.lastTurnId, id1)
        // Legacy Int fields preserved as-is for backward compat with any
        // reader that hasn't been migrated yet (Phase 7 transition window).
        try expectEqual(scene.firstTurn, 0)
        try expectEqual(scene.lastTurn, 1)
    }

    s.test("Chat.init leaves SceneSummary UUIDs alone when already populated") {
        // Phase 7+ chat: scene already carries UUIDs. Post-pass should NOT
        // overwrite them with anything derived from legacy Ints (which would
        // be nil here anyway).
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Phase7",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false, "parentId": null},
                {"id": "\(id1.uuidString)", "role": "assistant", "text": "b", "ts": "\(now)", "edited": false, "parentId": "\(id0.uuidString)"}
            ],
            "activePath": ["\(id0.uuidString)", "\(id1.uuidString)"],
            "sceneSummaries": [
                {"text": "arc1", "firstTurnId": "\(id0.uuidString)", "lastTurnId": "\(id1.uuidString)"}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.sceneSummaries[0].firstTurnId, id0)
        try expectEqual(chat.sceneSummaries[0].lastTurnId, id1)
    }

    s.test("Chat.init silently skips SceneSummary Int resolution when out of bounds") {
        // Edge case: a hand-edited or corrupted legacy chat has an Int that
        // exceeds the turn count. Don't throw; leave the UUID nil and the
        // Int as-is. Position-helpers will fall back to the Int and the
        // reader can decide what to do (today: treats nil-position as "nil
        // last" → stale).
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false}
            ],
            "sceneSummaries": [
                {"text": "arc1", "firstTurn": 0, "lastTurn": 99}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.sceneSummaries[0].firstTurnId, id0)
        try expectEqual(chat.sceneSummaries[0].lastTurnId, nil) // out of bounds
        try expectEqual(chat.sceneSummaries[0].lastTurn, 99)    // preserved
    }

    // MARK: - Position helpers (branch-aware)

    s.test("firstTurnPosition / lastTurnPosition resolve UUIDs against the current activePath") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        let t2 = Turn(role: .user, text: "c")
        chat.turns = [t0, t1, t2]
        chat.activePath = [t0.id, t1.id, t2.id]

        var scene = SceneSummary(text: "arc1")
        scene.firstTurnId = t0.id
        scene.lastTurnId = t1.id

        try expectEqual(scene.firstTurnPosition(in: chat), 0)
        try expectEqual(scene.lastTurnPosition(in: chat), 1)
    }

    s.test("position helpers return nil when UUIDs are off the current activePath and no Int fallback") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "root")
        let onPath = Turn(role: .assistant, text: "on-path")
        let offPath = Turn(role: .assistant, text: "off-path")
        chat.turns = [t0, onPath, offPath]
        chat.activePath = [t0.id, onPath.id]   // offPath excluded

        var scene = SceneSummary(text: "arc1")
        scene.lastTurnId = offPath.id   // off-branch

        try expectEqual(scene.lastTurnPosition(in: chat), nil)
    }

    s.test("position helpers fall back to legacy Int when UUID is nil") {
        // Legacy SceneSummary that hasn't been migrated (UUID nil, Int set).
        // Resolution falls back to the Int snapshot taken at write time.
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        chat.turns = [t0, t1]
        chat.activePath = [t0.id, t1.id]

        let scene = SceneSummary(text: "legacy", firstTurn: 0, lastTurn: 1)
        try expectEqual(scene.firstTurnPosition(in: chat), 0)
        try expectEqual(scene.lastTurnPosition(in: chat), 1)
    }

    s.test("position helpers prefer UUID over Int when both are present") {
        // After legacy migration, UUID and Int both exist. Helper trusts UUID
        // — that's the canonical answer; Int is a stale snapshot.
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        let t2 = Turn(role: .user, text: "c")
        chat.turns = [t0, t1, t2]
        chat.activePath = [t0.id, t1.id, t2.id]

        var scene = SceneSummary(text: "both", firstTurn: 0, lastTurn: 99)
        scene.firstTurnId = t1.id   // UUID disagrees with Int
        scene.lastTurnId = t2.id

        try expectEqual(scene.firstTurnPosition(in: chat), 1)
        try expectEqual(scene.lastTurnPosition(in: chat), 2)
    }

    return s
}
