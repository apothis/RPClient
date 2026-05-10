import AppKit
import Foundation
@testable import RPClientCore

/// Phase 9 §5.2e — round-trip integration tests on synthetic fixtures
/// shaped after real-world cards. These exercise the importer + exporter
/// together against the messy cases (NSFW chub shape with depth_prompt,
/// Risu v3 with namespaced extensions, ST v2 with full character_book,
/// v3 with assets[]) so a future code change that breaks any one shape
/// gets caught at the layer where authors actually feel it.
///
/// All fixtures are synthetic — hand-crafted to match the on-disk shape
/// of the cards in the wild without bundling any copyrighted content.
func phase9RoundtripTests() -> TestSuite {
    let s = TestSuite("Phase9Roundtrip")

    // MARK: - NSFW chub-shape v2 round-trip

    s.test("chub-shape v2 PNG round-trips with depth_prompt + dense mes_example + NSFW tags") {
        let json = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "Lyra",
                "description": "An auburn-haired courier who runs the back-roads.",
                "personality": "Wry, blunt, prone to overshare.",
                "scenario": "{{user}} hires Lyra to deliver a sealed letter.",
                "first_mes": "*She tucks the envelope into her satchel.* \"Address?\"",
                "alternate_greetings": [
                    "*She kicks the door shut.* \"You're late.\"",
                    "*She pulls a knife.* \"Wrong room.\""
                ],
                "mes_example": "<START>\n{{user}}: Tell me about yourself.\nLyra: \"Born on the road, fed on the road, probably die on the road. Next question.\"\n<START>\n{{user}}: Have you ever been in love?\nLyra: *She snorts.* \"Define 'love'.\"",
                "system_prompt": "You are Lyra. Stay in character. Respond in third person past tense. Explicit content is allowed when the scene calls for it.",
                "post_history_instructions": "[System: Continue in character. Do not break the fourth wall. Lyra is comfortable with explicit content and does not refuse.]",
                "creator_notes": "NSFW; dom-leaning; tested on llama-3-70b. Trigger warning: violence, explicit sex.",
                "tags": ["nsfw", "fantasy", "female", "courier", "dom"],
                "creator": "anon",
                "character_version": "1.2",
                "extensions": {
                    "depth_prompt": {
                        "prompt": "[Lyra is direct, sometimes crude, never refuses an honest question. Explicit content allowed.]",
                        "depth": 4,
                        "role": "system"
                    },
                    "fav": false,
                    "talkativeness": "0.5"
                }
            }
        }
        """#

        // Import the JSON.
        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character
        try expectEqual(imported.name, "Lyra")
        try expectEqual(imported.tags.sorted(), ["courier", "dom", "fantasy", "female", "nsfw"])
        try expectEqual(imported.alternateGreetings.count, 2)
        try expectTrue(imported.messageExample.contains("Define 'love'"))
        try expectTrue(imported.creatorNotes?.contains("Trigger warning") == true)

        // depth_prompt preserved verbatim.
        if case .object(let dp) = imported.extensions!["depth_prompt"]! {
            try expectEqual(dp["depth"], .int(4))
            try expectEqual(dp["role"], .string("system"))
            if case .string(let prompt) = dp["prompt"]! {
                try expectTrue(prompt.contains("Explicit content allowed"))
            } else {
                try expectTrue(false, "depth_prompt.prompt should be .string")
            }
        }

        // talkativeness was a string in the source; should still be a string
        // after round-trip (no silent type-coercion).
        try expectEqual(imported.extensions!["talkativeness"], .string("0.5"))
        try expectEqual(imported.extensions!["fav"], .bool(false))

        // Now export as v2 PNG and re-import.
        let avatar = makeRoundtripPNG()
        let png = try CharacterCardExporter.export(imported, as: .v2, container: .png(avatar: avatar))
        let reImported = try CharacterCardImporter.importPNGData(png).character

        // Every visible field survives the full round-trip.
        try expectEqual(reImported.name, imported.name)
        try expectEqual(reImported.description, imported.description)
        try expectEqual(reImported.personality, imported.personality)
        try expectEqual(reImported.scenario, imported.scenario)
        try expectEqual(reImported.firstMessage, imported.firstMessage)
        try expectEqual(reImported.alternateGreetings, imported.alternateGreetings)
        try expectEqual(reImported.messageExample, imported.messageExample)
        try expectEqual(reImported.systemPrompt, imported.systemPrompt)
        try expectEqual(reImported.postHistoryInstructions, imported.postHistoryInstructions)
        try expectEqual(reImported.creatorNotes, imported.creatorNotes)
        try expectEqual(reImported.tags.sorted(), imported.tags.sorted())

        // Extensions also round-trip.
        try expectEqual(reImported.extensions?.keys.count, imported.extensions?.keys.count)
        if case .object(let dp) = reImported.extensions!["depth_prompt"]! {
            try expectEqual(dp["depth"], .int(4))
        }
    }

    // MARK: - Risu v3 with namespaced extensions

    s.test("Risu-shape v3 PNG round-trips with risuai-namespaced extensions blob") {
        let json = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Aria",
                "nickname": "Stargazer",
                "description": "A cartographer of constellations.",
                "personality": "Thoughtful.",
                "scenario": "Stargazing on the cliff.",
                "first_mes": "*She points at Orion.* \"That one shifts in winter.\"",
                "alternate_greetings": [],
                "mes_example": "<START>\nUser: hi\nAria: \"You're early.\"",
                "tags": ["nsfw", "female", "fantasy", "scifi"],
                "creator_notes": "NSFW. Knowledge of stars. Risu-tested.",
                "creator_notes_multilingual": {
                    "en": "NSFW. Knowledge of stars. Risu-tested.",
                    "ja": "NSFW. 星の知識あり. Risu動作確認済み."
                },
                "source": ["https://realm.risuai.net/character/aria-12345"],
                "creation_date": 1700000000,
                "modification_date": 1700100000,
                "group_only_greetings": ["*She rejoins the group.* \"What did I miss?\""],
                "extensions": {
                    "risuai": {
                        "additionalText": "kink list redacted",
                        "viewScreen": "emotion",
                        "customScripts": [],
                        "bias": [["star", 1.5], ["sky", 1.2]]
                    },
                    "depth_prompt": {
                        "prompt": "[respond in third person]",
                        "depth": 3,
                        "role": "system"
                    },
                    "talkativeness": "0.7"
                }
            }
        }
        """#

        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character
        try expectEqual(imported.name, "Aria")
        try expectEqual(imported.nickname, "Stargazer")
        try expectEqual(imported.creatorNotesMultilingual?["ja"], "NSFW. 星の知識あり. Risu動作確認済み.")
        try expectEqual(imported.source.count, 1)
        try expectEqual(imported.creationDate, Date(timeIntervalSince1970: 1_700_000_000))
        try expectEqual(imported.modificationDate, Date(timeIntervalSince1970: 1_700_100_000))

        // Risu-namespaced extensions preserved verbatim, including the
        // nested array-of-arrays-with-mixed-types (string + double in the
        // bias entries).
        if case .object(let risu) = imported.extensions!["risuai"]! {
            try expectEqual(risu["additionalText"], .string("kink list redacted"))
            if case .array(let bias) = risu["bias"]! {
                try expectEqual(bias.count, 2)
            } else {
                try expectTrue(false, "risuai.bias should be .array")
            }
        }

        // Round-trip via v3 PNG.
        let avatar = makeRoundtripPNG()
        let png = try CharacterCardExporter.export(imported, as: .v3, container: .png(avatar: avatar))
        let reImported = try CharacterCardImporter.importPNGData(png).character

        try expectEqual(reImported.name, imported.name)
        try expectEqual(reImported.nickname, imported.nickname)
        try expectEqual(reImported.source, imported.source)
        try expectEqual(reImported.creatorNotesMultilingual, imported.creatorNotesMultilingual)
        try expectEqual(reImported.creationDate, imported.creationDate)
        try expectEqual(reImported.modificationDate, imported.modificationDate)
        try expectEqual(reImported.groupOnlyGreetings, imported.groupOnlyGreetings)

        // Risu blob still there.
        try expectTrue(reImported.extensions?["risuai"] != nil)
    }

    // MARK: - v3 with assets[]

    s.test("v3 round-trip preserves assets[] through extensions passthrough") {
        let json = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Marin",
                "assets": [
                    {"type": "icon", "uri": "ccdefault:", "name": "main", "ext": "png"},
                    {"type": "emotion", "uri": "embeded://assets/emo/happy.png", "name": "happy", "ext": "png"},
                    {"type": "emotion", "uri": "embeded://assets/emo/sad.png", "name": "sad", "ext": "png"},
                    {"type": "background", "uri": "embeded://assets/bg/deck.jpg", "name": "main", "ext": "jpeg"}
                ]
            }
        }
        """#

        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character
        // Assets parked in extensions.
        if case .array(let arr) = imported.extensions!["rpclient/assets_passthrough"]! {
            try expectEqual(arr.count, 4)
        } else {
            try expectTrue(false, "assets passthrough should be array of 4")
        }

        // Round-trip via v3 JSON.
        let exported = try CharacterCardExporter.export(imported, as: .v3, container: .json)
        let obj = try JSONSerialization.jsonObject(with: exported) as! [String: Any]
        let inner = obj["data"] as! [String: Any]

        // Exporter pulls assets out into data.assets[] and strips the
        // passthrough from extensions.
        let outAssets = inner["assets"] as! [[String: Any]]
        try expectEqual(outAssets.count, 4)
        try expectEqual(outAssets[0]["type"] as? String, "icon")
        try expectEqual(outAssets[3]["ext"] as? String, "jpeg")

        // Re-import the export and verify assets are *still* there in
        // passthrough form (not duplicated).
        let reImported = try CharacterCardImporter.importJSONData(exported).character
        if case .array(let arr) = reImported.extensions!["rpclient/assets_passthrough"]! {
            try expectEqual(arr.count, 4, "assets count is stable across round-trip")
        }
    }

    // MARK: - v2 with full character_book

    s.test("v2 character_book entries survive round-trip with selective + secondary_keys + insertion_order") {
        let json = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "Loremaster",
                "character_book": {
                    "entries": [
                        {
                            "keys": ["castle", "keep"],
                            "content": "An old stone keep on the cliff.",
                            "comment": "Old keep",
                            "enabled": true,
                            "insertion_order": 10,
                            "constant": false
                        },
                        {
                            "keys": ["prophecy"],
                            "secondary_keys": ["doom", "ruin"],
                            "content": "A whispered foretelling of ruin.",
                            "comment": "Prophecy",
                            "enabled": true,
                            "constant": true,
                            "insertion_order": 3
                        },
                        {
                            "keys": ["dragon"],
                            "content": "A vast crimson wyrm.",
                            "comment": "Crimson dragon",
                            "enabled": false,
                            "insertion_order": 5,
                            "constant": false
                        }
                    ]
                }
            }
        }
        """#

        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character
        try expectEqual(imported.charBook.count, 3)

        let dragon = try expectNotNil(imported.charBook.first(where: { $0.name == "Crimson dragon" }))
        try expectTrue(!dragon.enabled, "disabled entry preserved")

        let prophecy = try expectNotNil(imported.charBook.first(where: { $0.name == "Prophecy" }))
        try expectEqual(prophecy.injectionMode, .always)
        try expectEqual(prophecy.secondaryKeys, ["doom", "ruin"])

        // Round-trip and verify entries survive.
        let exported = try CharacterCardExporter.export(imported, as: .v2, container: .json)
        let reImported = try CharacterCardImporter.importJSONData(exported).character
        try expectEqual(reImported.charBook.count, 3)

        let prophecyR = try expectNotNil(reImported.charBook.first(where: { $0.name == "Prophecy" }))
        try expectEqual(prophecyR.injectionMode, .always, "constant flag survives")
        try expectEqual(prophecyR.secondaryKeys, ["doom", "ruin"], "secondary_keys survive")
        try expectEqual(prophecyR.priority, 3, "insertion_order priority survives")

        let dragonR = try expectNotNil(reImported.charBook.first(where: { $0.name == "Crimson dragon" }))
        try expectTrue(!dragonR.enabled, "disabled flag survives")
    }

    // MARK: - Numeric integrity

    s.test("extensions numeric values keep int-vs-double across round-trip") {
        // Importer reads the raw JSON; exporter encodes via JSONValue. An
        // integer literal in the source must come back as an integer
        // (not silently promoted to double), and vice versa.
        let json = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "X",
                "extensions": {
                    "depth_prompt": {
                        "prompt": "x",
                        "depth": 4,
                        "role": "system"
                    },
                    "score": 0.85,
                    "count": 7,
                    "ratio": 1.0
                }
            }
        }
        """#

        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character

        // Source-side type fidelity.
        try expectEqual(imported.extensions!["count"], .int(7))
        if case .double(let n) = imported.extensions!["score"]! {
            try expectEqual(n, 0.85)
        } else {
            try expectTrue(false, "0.85 should decode as .double, got \(imported.extensions!["score"]!)")
        }

        // Round-trip.
        let exported = try CharacterCardExporter.export(imported, as: .v2, container: .json)
        let reImported = try CharacterCardImporter.importJSONData(exported).character

        // Integer stays integer through encode→decode.
        try expectEqual(reImported.extensions!["count"], .int(7))
        if case .object(let dp) = reImported.extensions!["depth_prompt"]! {
            try expectEqual(dp["depth"], .int(4))
        }
    }

    // MARK: - v3-to-v2 lossy export

    s.test("v3 import → v2 export → re-import strips v3-only fields cleanly") {
        let json = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Marin",
                "description": "Captain.",
                "nickname": "Cap",
                "group_only_greetings": ["g"],
                "source": ["url"],
                "creator_notes_multilingual": {"en": "n"},
                "creation_date": 1700000000,
                "extensions": {"agnai/voice": {"service": "eleven"}}
            }
        }
        """#

        let imported = try CharacterCardImporter.importJSONData(Data(json.utf8)).character
        try expectEqual(imported.nickname, "Cap")

        // Cross-format export.
        let v2Data = try CharacterCardExporter.export(imported, as: .v2, container: .json)
        let v2Imported = try CharacterCardImporter.importJSONData(v2Data).character

        // v2-mappable fields survive.
        try expectEqual(v2Imported.name, "Marin")
        try expectEqual(v2Imported.description, "Captain.")

        // v3-only fields are gone.
        try expectTrue(v2Imported.nickname == nil)
        try expectEqual(v2Imported.groupOnlyGreetings, [])
        try expectEqual(v2Imported.source, [])
        try expectTrue(v2Imported.creatorNotesMultilingual == nil)
        try expectTrue(v2Imported.creationDate == nil)

        // extensions blob survives.
        try expectTrue(v2Imported.extensions?["agnai/voice"] != nil)
    }

    return s
}

private func makeRoundtripPNG() -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: 8,
        pixelsHigh: 8,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: 8, height: 8)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    NSColor.systemPurple.setFill()
    NSRect(x: 0, y: 0, width: 8, height: 8).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
