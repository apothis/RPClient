import AppKit
import Foundation
@testable import RPClientCore

func characterCardExporterTests() -> TestSuite {
    let s = TestSuite("CharacterCardExporter")

    // MARK: - v2 JSON export

    s.test("v2 JSON export emits chara_card_v2 envelope with every mapped field") {
        let c = Character(
            name: "Marin",
            description: "Captain.",
            personality: "Wry.",
            scenario: "On the deck.",
            firstMessage: "Welcome aboard.",
            alternateGreetings: ["Greetings."],
            systemPrompt: "Always third-person.",
            postHistoryInstructions: "Stay in character.",
            tags: ["fantasy", "captain"],
            creator: "anon",
            characterVersion: "1.0",
            messageExample: "User: hi\nMarin: hello",
            creatorNotes: "NSFW; tested"
        )
        let data = try CharacterCardExporter.export(c, as: .v2, container: .json)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(obj["spec"] as? String, "chara_card_v2")
        try expectEqual(obj["spec_version"] as? String, "2.0")
        let inner = obj["data"] as! [String: Any]
        try expectEqual(inner["name"] as? String, "Marin")
        try expectEqual(inner["description"] as? String, "Captain.")
        try expectEqual(inner["personality"] as? String, "Wry.")
        try expectEqual(inner["scenario"] as? String, "On the deck.")
        try expectEqual(inner["first_mes"] as? String, "Welcome aboard.")
        try expectEqual(inner["mes_example"] as? String, "User: hi\nMarin: hello")
        try expectEqual(inner["system_prompt"] as? String, "Always third-person.")
        try expectEqual(inner["post_history_instructions"] as? String, "Stay in character.")
        try expectEqual(inner["creator_notes"] as? String, "NSFW; tested")
        try expectEqual((inner["alternate_greetings"] as? [String]), ["Greetings."])
        try expectEqual((inner["tags"] as? [String]), ["fantasy", "captain"])
        try expectEqual(inner["creator"] as? String, "anon")
        try expectEqual(inner["character_version"] as? String, "1.0")
    }

    s.test("v2 export drops every v3-only field") {
        let c = Character(
            name: "Marin",
            messageExample: "ex",
            nickname: "Cap",
            groupOnlyGreetings: ["g"],
            source: ["url"],
            creatorNotesMultilingual: ["en": "x"],
            creationDate: Date(timeIntervalSince1970: 1700000000),
            modificationDate: Date(timeIntervalSince1970: 1700100000)
        )
        let data = try CharacterCardExporter.export(c, as: .v2, container: .json)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let inner = obj["data"] as! [String: Any]
        try expectTrue(inner["nickname"] == nil)
        try expectTrue(inner["group_only_greetings"] == nil)
        try expectTrue(inner["source"] == nil)
        try expectTrue(inner["creator_notes_multilingual"] == nil)
        try expectTrue(inner["creation_date"] == nil)
        try expectTrue(inner["modification_date"] == nil)
        try expectTrue(inner["assets"] == nil)
    }

    s.test("v2 export round-trips through importJSONData") {
        let original = Character(
            name: "Marin",
            description: "Captain.",
            personality: "Wry.",
            scenario: "On the deck.",
            firstMessage: "Welcome.",
            alternateGreetings: ["Hi."],
            systemPrompt: "S",
            postHistoryInstructions: "P",
            tags: ["fantasy"],
            creator: "anon",
            characterVersion: "1.0",
            messageExample: "ex",
            creatorNotes: "notes"
        )
        let exported = try CharacterCardExporter.export(original, as: .v2, container: .json)
        let imported = try CharacterCardImporter.importJSONData(exported).character
        try expectEqual(imported.name, original.name)
        try expectEqual(imported.description, original.description)
        try expectEqual(imported.personality, original.personality)
        try expectEqual(imported.scenario, original.scenario)
        try expectEqual(imported.firstMessage, original.firstMessage)
        try expectEqual(imported.alternateGreetings, original.alternateGreetings)
        try expectEqual(imported.systemPrompt, original.systemPrompt)
        try expectEqual(imported.postHistoryInstructions, original.postHistoryInstructions)
        try expectEqual(imported.tags, original.tags)
        try expectEqual(imported.creator, original.creator)
        try expectEqual(imported.characterVersion, original.characterVersion)
        try expectEqual(imported.messageExample, original.messageExample)
        try expectEqual(imported.creatorNotes, original.creatorNotes)
    }

    s.test("v2 export preserves extensions blob (round-trip)") {
        let ext: [String: JSONValue] = [
            "depth_prompt": .object([
                "prompt": .string("[explicit ok]"),
                "depth": .int(4),
                "role": .string("system"),
            ]),
            "agnai/voice": .object(["service": .string("eleven")]),
        ]
        let original = Character(name: "X", extensions: ext)
        let exported = try CharacterCardExporter.export(original, as: .v2, container: .json)
        let imported = try CharacterCardImporter.importJSONData(exported).character
        try expectTrue(imported.extensions != nil)
        if case .object(let dp) = imported.extensions!["depth_prompt"]! {
            try expectEqual(dp["prompt"], .string("[explicit ok]"))
            try expectEqual(dp["depth"], .int(4))
        } else {
            try expectTrue(false, "depth_prompt should round-trip")
        }
        try expectTrue(imported.extensions!["agnai/voice"] != nil)
    }

    // MARK: - v2 PNG export

    s.test("v2 PNG export embeds chara tEXt chunk and re-imports") {
        let avatar = makeTinyPNGForExporter()
        let c = Character(name: "Marin", description: "Captain.", messageExample: "ex")
        let png = try CharacterCardExporter.export(c, as: .v2, container: .png(avatar: avatar))
        let imported = try CharacterCardImporter.importPNGData(png)
        try expectEqual(imported.character.name, "Marin")
        try expectEqual(imported.character.description, "Captain.")
        try expectEqual(imported.character.messageExample, "ex")
        try expectEqual(imported.avatarPNG, png)
    }

    s.test("v2 PNG export rejects non-PNG avatar bytes") {
        let c = Character(name: "X")
        do {
            _ = try CharacterCardExporter.export(
                c, as: .v2, container: .png(avatar: Data("not a png".utf8))
            )
            try expectTrue(false, "expected throw")
        } catch CharacterCardExporter.ExportError.notAPNG {
            // ok
        }
    }

    // MARK: - v3 JSON export

    s.test("v3 JSON export emits chara_card_v3 envelope with v3-only fields") {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let c = Character(
            name: "Marin",
            description: "Captain.",
            tags: ["fantasy"],
            messageExample: "ex",
            creatorNotes: "notes",
            nickname: "Cap",
            groupOnlyGreetings: ["g1", "g2"],
            source: ["https://x/y"],
            creatorNotesMultilingual: ["en": "notes", "ja": "メモ"],
            creationDate: now,
            modificationDate: now
        )
        let data = try CharacterCardExporter.export(c, as: .v3, container: .json)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        try expectEqual(obj["spec"] as? String, "chara_card_v3")
        try expectEqual(obj["spec_version"] as? String, "3.0")
        let inner = obj["data"] as! [String: Any]
        try expectEqual(inner["nickname"] as? String, "Cap")
        try expectEqual((inner["group_only_greetings"] as? [String]), ["g1", "g2"])
        try expectEqual((inner["source"] as? [String]), ["https://x/y"])
        let ml = inner["creator_notes_multilingual"] as! [String: String]
        try expectEqual(ml["en"], "notes")
        try expectEqual(ml["ja"], "メモ")
        try expectEqual(inner["creation_date"] as? Double, 1_700_000_000)
        try expectEqual(inner["modification_date"] as? Double, 1_700_000_000)
    }

    s.test("v3 export pulls assets out of extensions['rpclient/assets_passthrough'] into data.assets") {
        let assets: [JSONValue] = [
            .object([
                "type": .string("icon"),
                "uri": .string("ccdefault:"),
                "name": .string("main"),
                "ext": .string("png"),
            ]),
            .object([
                "type": .string("emotion"),
                "uri": .string("embeded://assets/emo/happy.png"),
                "name": .string("happy"),
                "ext": .string("png"),
            ]),
        ]
        let c = Character(
            name: "Marin",
            extensions: [
                "rpclient/assets_passthrough": .array(assets),
                "agnai/voice": .object(["service": .string("eleven")]),
            ]
        )
        let data = try CharacterCardExporter.export(c, as: .v3, container: .json)
        let obj = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let inner = obj["data"] as! [String: Any]
        let outAssets = inner["assets"] as! [[String: Any]]
        try expectEqual(outAssets.count, 2)
        try expectEqual(outAssets[0]["type"] as? String, "icon")
        try expectEqual(outAssets[1]["name"] as? String, "happy")
        // Passthrough key is stripped from extensions (otherwise we'd write
        // the same assets twice).
        let outExt = inner["extensions"] as! [String: Any]
        try expectTrue(outExt["rpclient/assets_passthrough"] == nil)
        // Other extensions keys survive.
        try expectTrue(outExt["agnai/voice"] != nil)
    }

    s.test("v3 PNG export writes ccv3 chunk + chara backfill") {
        let avatar = makeTinyPNGForExporter()
        let c = Character(name: "Marin", nickname: "Cap")
        let png = try CharacterCardExporter.export(c, as: .v3, container: .png(avatar: avatar))
        let chunks = try PNGTextChunks.readTextChunks(from: png)
        // Both chunks present: ccv3 (v3-readers) + chara (v2-readers).
        try expectTrue(chunks.contains(where: { $0.keyword == "ccv3" }))
        try expectTrue(chunks.contains(where: { $0.keyword == "chara" }))
    }

    s.test("v3 PNG export round-trips through importPNGData with ccv3-precedence") {
        let avatar = makeTinyPNGForExporter()
        let c = Character(name: "Marin", nickname: "Cap", source: ["https://x"])
        let png = try CharacterCardExporter.export(c, as: .v3, container: .png(avatar: avatar))
        let imported = try CharacterCardImporter.importPNGData(png).character
        try expectEqual(imported.name, "Marin")
        try expectEqual(imported.nickname, "Cap")
        try expectEqual(imported.source, ["https://x"])
    }

    // MARK: - Cross-format export

    s.test("v3 → v2 export drops v3 fields; round-trip through v2 leaves them nil") {
        let c = Character(
            name: "Marin",
            messageExample: "ex",
            nickname: "Cap",
            groupOnlyGreetings: ["g"],
            source: ["url"],
            creatorNotesMultilingual: ["en": "n"]
        )
        let data = try CharacterCardExporter.export(c, as: .v2, container: .json)
        let imported = try CharacterCardImporter.importJSONData(data).character
        // v2-mappable subset survives.
        try expectEqual(imported.name, "Marin")
        try expectEqual(imported.messageExample, "ex")
        // v3-only fields are gone.
        try expectTrue(imported.nickname == nil)
        try expectEqual(imported.groupOnlyGreetings, [])
        try expectEqual(imported.source, [])
        try expectTrue(imported.creatorNotesMultilingual == nil)
    }

    return s
}

private func makeTinyPNGForExporter() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 4,
        pixelsHigh: 4,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 4, height: 4)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    NSColor.systemPink.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
