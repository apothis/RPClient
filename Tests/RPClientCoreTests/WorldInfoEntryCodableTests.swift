import Foundation
@testable import RPClientCore

func worldInfoEntryCodableTests() -> TestSuite {
    let s = TestSuite("WorldInfoEntryCodable")

    let encoder = JSONEncoder()
    let decoder = JSONDecoder()

    s.test("legacy three-field JSON migrates with sane defaults") {
        let json = """
        {
            "keys": ["Mournbringer", "blade"],
            "content": "An ancient sword that hums when drawn.",
            "tokenCap": 200
        }
        """
        let entry = try decoder.decode(WorldInfoEntry.self, from: Data(json.utf8))
        try expectEqual(entry.keys, ["Mournbringer", "blade"])
        try expectEqual(entry.content, "An ancient sword that hums when drawn.")
        try expectEqual(entry.tokenCap, 200)
        try expectEqual(entry.name, "Mournbringer")
        try expectTrue(entry.secondaryKeys.isEmpty)
        try expectTrue(entry.enabled)
        try expectEqual(entry.injectionMode, .keyword)
        try expectEqual(entry.matchScope, .recentTurns(4))
        try expectEqual(entry.priority, 0)
    }

    s.test("legacy entry with no keys gets Untitled name") {
        let json = """
        { "keys": [], "content": "lonely", "tokenCap": 64 }
        """
        let entry = try decoder.decode(WorldInfoEntry.self, from: Data(json.utf8))
        try expectEqual(entry.name, "Untitled")
    }

    s.test("round-trip preserves all fields") {
        let original = WorldInfoEntry(
            name: "Mournbringer",
            keys: ["Mournbringer", "blade"],
            secondaryKeys: ["sword"],
            content: "A legendary blade.",
            tokenCap: 180,
            enabled: false,
            injectionMode: .always,
            matchScope: .lastUserTurn,
            priority: 5
        )
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(WorldInfoEntry.self, from: data)
        try expectEqual(decoded, original)
    }

    s.test("matchScope round-trips for each variant") {
        for scope: WorldInfoMatchScope in [.recentTurns(2), .recentTurns(8), .lastUserTurn, .entireChat] {
            let entry = WorldInfoEntry(name: "x", keys: ["x"], matchScope: scope)
            let data = try encoder.encode(entry)
            let decoded = try decoder.decode(WorldInfoEntry.self, from: data)
            try expectEqual(decoded.matchScope, scope)
        }
    }

    s.test("Chat decode migrates legacy worldInfo array") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "worldInfo": [
                { "keys": ["dragon"], "content": "A dragon lives nearby.", "tokenCap": 80 }
            ]
        }
        """
        let chatDecoder = JSONDecoder()
        chatDecoder.dateDecodingStrategy = .iso8601
        let chat = try chatDecoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.worldInfo.count, 1)
        let e = chat.worldInfo[0]
        try expectEqual(e.name, "dragon")
        try expectEqual(e.keys, ["dragon"])
        try expectTrue(e.enabled)
    }

    return s
}
