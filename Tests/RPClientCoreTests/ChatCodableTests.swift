import Foundation
@testable import RPClientCore

func chatCodableTests() -> TestSuite {
    let s = TestSuite("ChatCodable")

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

    s.test("round-trip preserves all fields") {
        // ISO8601 strategy truncates to whole seconds, so normalize before comparing.
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var chat = Chat(title: "Saved")
        chat.created = stamp
        chat.modified = stamp
        chat.turns = [
            Turn(role: .user, text: "hi", ts: stamp),
            Turn(role: .assistant, text: "ok", ts: stamp),
        ]
        chat.memory = "facts"
        chat.summary = "rolling"
        chat.summarizedThrough = 3
        chat.tailReinforceMemory = true
        chat.lastExtractedTurn = 7
        chat.factExtractionScanTurns = 12
        chat.sceneSummaries = [
            SceneSummary(text: "s1", firstTurn: 0, lastTurn: 4),
            SceneSummary(text: "s2", firstTurn: 5, lastTurn: 9),
        ]
        chat.factExtractionPriorities = [
            FactExtractionPriority(text: "names", enabled: true),
            FactExtractionPriority(text: "places", enabled: false),
        ]

        let data = try encoder.encode(chat)
        let decoded = try decoder.decode(Chat.self, from: data)
        try expectEqual(decoded, chat)
    }

    s.test("decode fills defaults for missing optional fields") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced"
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.memory, "")
        try expectEqual(chat.summary, "")
        try expectEqual(chat.summarizedThrough, 0)
        try expectEqual(chat.summaryTokenCap, 350)
        try expectEqual(chat.summaryTriggerRatio, 0.85)
        try expectFalse(chat.tailReinforceMemory)
        try expectEqual(chat.lastExtractedTurn, 0)
        try expectEqual(chat.factExtractionScanTurns, 0)
        try expectTrue(chat.factExtractionPriorities.isEmpty)
        try expectTrue(chat.sceneSummaries.isEmpty)
        // Phase 3 §4 — pre-existing chats without the systemPromptMode key
        // must default to .override (matches SillyTavern, spec'd in V2_PLAN §4.4).
        try expectEqual(chat.systemPromptMode, .override)
    }

    s.test("systemPromptMode round-trips through encode/decode") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var chat = Chat(title: "Merge mode")
        chat.created = stamp
        chat.modified = stamp
        chat.systemPromptMode = .merge
        let data = try encoder.encode(chat)
        let decoded = try decoder.decode(Chat.self, from: data)
        try expectEqual(decoded.systemPromptMode, .merge)
    }

    s.test("sceneSummaries decode falls back from legacy [String]") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "sceneSummaries": ["concert arc", "drive home"]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.sceneSummaries.count, 2)
        try expectEqual(chat.sceneSummaries[0].text, "concert arc")
        try expectNil(chat.sceneSummaries[0].firstTurn)
        try expectNil(chat.sceneSummaries[1].lastTurn)
    }

    s.test("dedupeMigratedEntities merges legacy bracket-prefixed dupes into typed twins") {
        // Mirror the canonical 2026-05-03 chat: Sarah present in both legacy
        // bracket-prefix shape and modern typed shape. Same for Stadium.
        let legacy = [
            Entity(name: "[character] Sarah", type: .event,
                   facts: [Fact(text: "Sarah is energetic"), Fact(text: "Sarah likes Metallica")],
                   pinnedByUser: true),
            Entity(name: "Sarah", aliases: ["Sare"], type: .character,
                   facts: [Fact(text: "Sarah likes Metallica"), Fact(text: "Sarah is 25")]),
            Entity(name: "[location] Stadium", type: .event,
                   facts: [Fact(text: "Stadium hosted Metallica")]),
            Entity(name: "Stadium", type: .location,
                   facts: [Fact(text: "Stadium is in town")]),
            Entity(name: "Apartment", type: .location, facts: [Fact(text: "Apartment is the user's home")]),
            // Pure-text bracket leader (not a real type) — must not be rewritten.
            Entity(name: "[important] Note", type: .event, facts: [Fact(text: "leave alone")]),
        ]
        let merged = Chat.dedupeMigratedEntities(legacy)
        // 6 inputs → 4 outputs (Sarah collapsed, Stadium collapsed, Apartment+Note untouched).
        try expectEqual(merged.count, 4)
        let sarah = try expectNotNil(merged.first(where: { $0.name == "Sarah" && $0.type == .character }))
        try expectEqual(sarah.facts.count, 3) // 2 legacy + 2 modern, with one shared text deduped
        try expectTrue(sarah.facts.contains(where: { $0.text == "Sarah is energetic" }))
        try expectTrue(sarah.facts.contains(where: { $0.text == "Sarah is 25" }))
        try expectEqual(sarah.aliases, ["Sare"])
        try expectTrue(sarah.pinnedByUser, "pinned status from legacy half should win")

        let stadium = try expectNotNil(merged.first(where: { $0.name == "Stadium" }))
        try expectEqual(stadium.type, .location)
        try expectEqual(stadium.facts.count, 2)

        let untouched = try expectNotNil(merged.first(where: { $0.name == "[important] Note" }))
        try expectEqual(untouched.type, .event)
    }

    s.test("dedupe runs on decode for pre-v3 chats") {
        let now = ISO8601DateFormatter().string(from: Date())
        // schemaVersion omitted → defaults to 1; entities present → migration path
        // skipped, but v3 dedup should still run.
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "schemaVersion": 2,
            "entities": [
                {"id": "\(UUID().uuidString)", "name": "[character] Sarah", "aliases": [], "type": "event", "facts": [{"id": "\(UUID().uuidString)", "text": "energetic"}], "pinnedByUser": false, "createdTurn": 0},
                {"id": "\(UUID().uuidString)", "name": "Sarah", "aliases": [], "type": "character", "facts": [{"id": "\(UUID().uuidString)", "text": "loves metal"}], "pinnedByUser": false, "createdTurn": 0}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.entities.count, 1)
        try expectEqual(chat.entities[0].name, "Sarah")
        try expectEqual(chat.entities[0].type, .character)
        try expectEqual(chat.entities[0].facts.count, 2)
        try expectEqual(chat.schemaVersion, 3)
    }

    s.test("factExtractionPriorities migrates from comma-separated string") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Old",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "factExtractionPriorities": "names, places\\nthings"
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.factExtractionPriorities.map(\.text), ["names", "places", "things"])
        try expectTrue(chat.factExtractionPriorities.allSatisfy(\.enabled))
    }

    return s
}
