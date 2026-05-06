import AppKit
import Foundation
@testable import RPClientCore

func characterCardImporterTests() -> TestSuite {
    let s = TestSuite("CharacterCardImporter")

    // MARK: PNGTextChunks

    s.test("PNGTextChunks rejects non-PNG input") {
        let bad = Data("not a png".utf8)
        do {
            _ = try PNGTextChunks.readTextChunks(from: bad)
            try expectTrue(false, "expected throw")
        } catch PNGTextChunks.ParseError.notAPNG {
            // ok
        }
    }

    s.test("PNGTextChunks round-trips a tEXt chunk via injectTextChunk") {
        let basePNG = makeTinyPNG()
        let injected = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "chara", text: "hello-world")
        )
        let chunks = try PNGTextChunks.readTextChunks(from: injected)
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].keyword, "chara")
        try expectEqual(chunks[0].text, "hello-world")
    }

    s.test("PNGTextChunks ignores non-text chunks") {
        let png = makeTinyPNG()
        let chunks = try PNGTextChunks.readTextChunks(from: png)
        try expectEqual(chunks.count, 0, "synthesized PNG should have no tEXt chunks")
    }

    // MARK: V2 importer (JSON path)

    s.test("v2 JSON import maps every supported field") {
        let json = canonicalV2JSON
        let result = try CharacterCardImporter.importJSONData(Data(json.utf8))
        let c = result.character
        try expectEqual(c.name, "Nyx")
        try expectEqual(c.description, "Half-elven ranger.")
        try expectEqual(c.personality, "Stoic, dry humor.")
        try expectEqual(c.scenario, "Lost in the borderlands.")
        try expectEqual(c.firstMessage, "*She lowers her bow.* \"You're not who I expected.\"")
        try expectEqual(c.alternateGreetings, ["*She nocks an arrow.* \"Stop right there.\""])
        try expectEqual(c.systemPrompt, "Always respond in third person.")
        try expectEqual(c.postHistoryInstructions, "Stay in character.")
        try expectEqual(c.tags, ["fantasy", "ranger"])
        try expectEqual(c.creator, "anon")
        try expectEqual(c.characterVersion, "1.0")
        try expectNil(result.avatarPNG)
    }

    s.test("v2 character_book entries map to WorldInfoEntry with sensible flags") {
        let result = try CharacterCardImporter.importJSONData(Data(canonicalV2JSON.utf8))
        let entries = result.character.charBook
        try expectEqual(entries.count, 2)

        let castle = try expectNotNil(entries.first(where: { $0.name == "Old keep" }))
        try expectEqual(castle.keys, ["castle", "keep"])
        try expectEqual(castle.content, "An old stone keep on the cliff.")
        try expectEqual(castle.injectionMode, .keyword)
        try expectTrue(castle.enabled)
        try expectEqual(castle.priority, 10) // from insertion_order
        try expectTrue(castle.secondaryKeys.isEmpty)

        let prophecy = try expectNotNil(entries.first(where: { $0.name == "Prophecy" }))
        // constant: true → injectionMode = .always
        try expectEqual(prophecy.injectionMode, .always)
        try expectEqual(prophecy.secondaryKeys, ["doom", "ruin"])
        // No insertion_order, but priority field set on the source entry.
        try expectEqual(prophecy.priority, 3)
    }

    s.test("v1 flat-shape cards import (TavernAI / kobold)") {
        // No `spec`, no `data` — fields live at the top level. KoboldAI
        // Lite exports look like this. We accept and map. Phase 9 §5.2c:
        // mes_example is now restored as a first-class field; description
        // stays clean.
        let v1 = #"""
        {
            "name": "Old Card",
            "description": "An aging archivist.",
            "personality": "Quiet, watchful.",
            "scenario": "A library after closing.",
            "first_mes": "*She looks up.* \"Did you need something?\"",
            "mes_example": "<START>\nUser: hi\nOld Card: hello",
            "tags": ["fantasy"]
        }
        """#
        let result = try CharacterCardImporter.importJSONData(Data(v1.utf8))
        let c = result.character
        try expectEqual(c.name, "Old Card")
        try expectEqual(c.personality, "Quiet, watchful.")
        try expectEqual(c.scenario, "A library after closing.")
        try expectEqual(c.firstMessage, "*She looks up.* \"Did you need something?\"")
        try expectEqual(c.tags, ["fantasy"])
        // §5.2c: description is no longer squashed with the example prefix;
        // mes_example lands in messageExample first-class.
        try expectEqual(c.description, "An aging archivist.")
        try expectEqual(c.messageExample, "<START>\nUser: hi\nOld Card: hello")
        // v1 has no v2-only fields; they default to empty/nil.
        try expectTrue(c.alternateGreetings.isEmpty)
        try expectNil(c.systemPrompt)
        try expectNil(c.postHistoryInstructions)
        try expectTrue(c.charBook.isEmpty)
    }

    s.test("Pygmalion-aliased v1 cards import via char_name / char_persona / char_greeting / world_scenario") {
        let pyg = #"""
        {
            "char_name": "Pyg",
            "char_persona": "Lab assistant.",
            "world_scenario": "A bustling research station.",
            "char_greeting": "Welcome aboard.",
            "example_dialogue": "<START>\nUser: hi\nPyg: hi"
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(pyg.utf8)).character
        try expectEqual(c.name, "Pyg")
        try expectEqual(c.personality, "Lab assistant.")
        try expectEqual(c.scenario, "A bustling research station.")
        try expectEqual(c.firstMessage, "Welcome aboard.")
        // §5.2c: example_dialogue → messageExample, not description.
        try expectEqual(c.messageExample, "<START>\nUser: hi\nPyg: hi")
        try expectTrue(c.description.isEmpty)
    }

    s.test("explicit chara_card_v1 spec is also accepted") {
        // Some kobold exports include `spec: "chara_card_v1"` even though
        // it's effectively the same flat shape. We treat v1 as v1 either
        // way — only unknown spec values reject.
        let v1 = #"""
        {
            "spec": "chara_card_v1",
            "name": "Tagged",
            "description": "explicit v1"
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v1.utf8)).character
        try expectEqual(c.name, "Tagged")
        try expectEqual(c.description, "explicit v1")
    }

    s.test("unknown spec values still reject with unsupportedSpec") {
        // §5.2c added v3 support; an unknown future spec still rejects.
        let future = #"""
        {
            "spec": "chara_card_v999",
            "data": {"name": "Time Traveller"}
        }
        """#
        do {
            _ = try CharacterCardImporter.importJSONData(Data(future.utf8))
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.unsupportedSpec(let s) {
            try expectEqual(s, "chara_card_v999")
        }
    }

    s.test("missing name is rejected even on a v2-shaped card") {
        let json = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {"description": "no name"}
        }
        """#
        do {
            _ = try CharacterCardImporter.importJSONData(Data(json.utf8))
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.missingName {
            // ok
        }
    }

    s.test("invalid JSON throws invalidJSON") {
        let bad = Data("{not json".utf8)
        do {
            _ = try CharacterCardImporter.importJSONData(bad)
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.invalidJSON {
            // ok
        }
    }

    // MARK: V2 importer (PNG path)

    s.test("v2 PNG import extracts character and returns the source bytes as avatar") {
        let basePNG = makeTinyPNG()
        let b64 = Data(canonicalV2JSON.utf8).base64EncodedString()
        let cardPNG = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "chara", text: b64)
        )
        let result = try CharacterCardImporter.importPNGData(cardPNG)
        try expectEqual(result.character.name, "Nyx")
        try expectEqual(result.avatarPNG, cardPNG, "importer should pass the source PNG through verbatim")
    }

    s.test("PNG without a chara tEXt chunk is rejected") {
        let basePNG = makeTinyPNG()
        let withOther = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "Author", text: "someone")
        )
        do {
            _ = try CharacterCardImporter.importPNGData(withOther)
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.missingCharaChunk {
            // ok
        }
    }

    s.test("PNG with non-base64 chara payload throws invalidBase64") {
        let basePNG = makeTinyPNG()
        let cardPNG = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "chara", text: "@@@not-base64@@@")
        )
        do {
            _ = try CharacterCardImporter.importPNGData(cardPNG)
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.invalidBase64 {
            // ok
        }
    }

    // MARK: Phase 9 §5.2c — v2 first-class new fields

    s.test("v2 import populates messageExample first-class (no description squash)") {
        let v2 = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "Mira",
                "description": "An apothecary.",
                "mes_example": "<START>\nUser: hi\nMira: hello"
            }
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v2.utf8)).character
        try expectEqual(c.description, "An apothecary.")
        try expectEqual(c.messageExample, "<START>\nUser: hi\nMira: hello")
    }

    s.test("v2 import maps creator_notes") {
        let v2 = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "Mira",
                "creator_notes": "NSFW; tested on llama3-70b."
            }
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v2.utf8)).character
        try expectEqual(c.creatorNotes, "NSFW; tested on llama3-70b.")
    }

    s.test("v2 import preserves extensions blob verbatim") {
        let v2 = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {
                "name": "Mira",
                "extensions": {
                    "depth_prompt": {
                        "prompt": "[stay explicit]",
                        "depth": 4,
                        "role": "system"
                    },
                    "agnai/voice": {"service": "elevenlabs"},
                    "risuai": {"additionalText": "kink list"}
                }
            }
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v2.utf8)).character
        try expectTrue(c.extensions != nil)
        try expectEqual(c.extensions!.keys.count, 3)

        if case .object(let dp) = c.extensions!["depth_prompt"]! {
            try expectEqual(dp["prompt"], .string("[stay explicit]"))
            try expectEqual(dp["depth"], .int(4))
            try expectEqual(dp["role"], .string("system"))
        } else {
            try expectTrue(false, "depth_prompt should be .object")
        }
    }

    s.test("v2 import without extensions leaves extensions nil") {
        let v2 = #"""
        {
            "spec": "chara_card_v2",
            "spec_version": "2.0",
            "data": {"name": "Mira"}
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v2.utf8)).character
        try expectTrue(c.extensions == nil)
    }

    // MARK: Phase 9 §5.2c — v3 spec acceptance + field mapping

    s.test("v3 spec is accepted (was rejected pre-§5.2c)") {
        let v3 = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {"name": "TimeTraveller"}
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v3.utf8)).character
        try expectEqual(c.name, "TimeTraveller")
    }

    s.test("v3 import maps every v3-only field") {
        let v3 = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Marin",
                "nickname": "Captain",
                "creator_notes": "rooftop view",
                "creator_notes_multilingual": {
                    "en": "rooftop view",
                    "ja": "屋上の眺め"
                },
                "group_only_greetings": ["Welcome aboard.", "Crew, attention."],
                "source": ["https://chub.ai/x/marin", "char-id-12345"],
                "creation_date": 1700000000,
                "modification_date": 1700100000
            }
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v3.utf8)).character
        try expectEqual(c.nickname, "Captain")
        try expectEqual(c.creatorNotes, "rooftop view")
        try expectEqual(c.creatorNotesMultilingual?["en"], "rooftop view")
        try expectEqual(c.creatorNotesMultilingual?["ja"], "屋上の眺め")
        try expectEqual(c.groupOnlyGreetings.count, 2)
        try expectEqual(c.groupOnlyGreetings[0], "Welcome aboard.")
        try expectEqual(c.source, ["https://chub.ai/x/marin", "char-id-12345"])
        try expectEqual(c.creationDate, Date(timeIntervalSince1970: 1_700_000_000))
        try expectEqual(c.modificationDate, Date(timeIntervalSince1970: 1_700_100_000))
    }

    s.test("v3 assets[] preserved through extensions['rpclient/assets_passthrough']") {
        let v3 = #"""
        {
            "spec": "chara_card_v3",
            "spec_version": "3.0",
            "data": {
                "name": "Marin",
                "assets": [
                    {"type": "icon", "uri": "ccdefault:", "name": "main", "ext": "png"},
                    {"type": "emotion", "uri": "embeded://assets/emo/happy.png", "name": "happy", "ext": "png"}
                ]
            }
        }
        """#
        let c = try CharacterCardImporter.importJSONData(Data(v3.utf8)).character
        try expectTrue(c.extensions != nil)
        let passthrough = try expectNotNil(c.extensions?["rpclient/assets_passthrough"])
        if case .array(let arr) = passthrough {
            try expectEqual(arr.count, 2)
            if case .object(let first) = arr[0] {
                try expectEqual(first["type"], .string("icon"))
                try expectEqual(first["name"], .string("main"))
            } else {
                try expectTrue(false, "assets[0] should be .object")
            }
        } else {
            try expectTrue(false, "assets passthrough should be .array")
        }
    }

    s.test("v3 PNG ccv3 chunk preferred over chara when both present") {
        let basePNG = makeTinyPNG()
        let v3JSON = #"{"spec":"chara_card_v3","spec_version":"3.0","data":{"name":"FromCcv3"}}"#
        let v2JSON = #"{"spec":"chara_card_v2","spec_version":"2.0","data":{"name":"FromChara"}}"#
        let v3b64 = Data(v3JSON.utf8).base64EncodedString()
        let v2b64 = Data(v2JSON.utf8).base64EncodedString()
        let withCcv3 = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "ccv3", text: v3b64)
        )
        let withBoth = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: withCcv3, keyword: "chara", text: v2b64)
        )
        let result = try CharacterCardImporter.importPNGData(withBoth)
        try expectEqual(result.character.name, "FromCcv3", "ccv3 chunk should win")
    }

    s.test("v3 PNG falls back to chara chunk when ccv3 absent (v2-reader backfill)") {
        // Per the v3 spec: applications MAY backfill the v2 chara chunk from
        // v3 cards for v2-reader compatibility. So a card with only the
        // chara chunk that *contains* a v3-shaped envelope is legitimate.
        let basePNG = makeTinyPNG()
        let v3JSON = #"{"spec":"chara_card_v3","spec_version":"3.0","data":{"name":"BackfillCard","nickname":"Cap"}}"#
        let b64 = Data(v3JSON.utf8).base64EncodedString()
        let png = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "chara", text: b64)
        )
        let c = try CharacterCardImporter.importPNGData(png).character
        try expectEqual(c.name, "BackfillCard")
        try expectEqual(c.nickname, "Cap")
    }

    // MARK: Phase 9 §5.2c — Legacy v1-squash detection helper

    s.test("containsLegacyExamplePrefix detects the squash separator") {
        try expectTrue(CharacterCardImporter.containsLegacyExamplePrefix(
            "An archivist.\n\nExample dialogue:\nUser: hi\nArchivist: hello"
        ))
    }

    s.test("containsLegacyExamplePrefix is false on plain prose") {
        try expectTrue(!CharacterCardImporter.containsLegacyExamplePrefix(
            "An archivist who keeps to themselves."
        ))
    }

    s.test("containsLegacyExamplePrefix requires the literal blank-line + colon shape") {
        // Authors writing "Example dialogue:" inside a paragraph (no leading
        // blank line) shouldn't false-positive — the marker is the
        // \n\nExample dialogue:\n separator that pre-Phase-9 imports
        // produced, not loose mention of the phrase.
        try expectTrue(!CharacterCardImporter.containsLegacyExamplePrefix(
            "She often opens with 'Example dialogue: speak plainly'"
        ))
    }

    s.test("importer tolerates whitespace inside the base64 text") {
        let basePNG = makeTinyPNG()
        let raw = Data(canonicalV2JSON.utf8).base64EncodedString()
        // Real ST cards sometimes wrap the base64 to 76 chars per line; mimic
        // that by stuffing newlines through the payload.
        var wrapped = ""
        for (i, ch) in raw.enumerated() {
            if i > 0 && i % 60 == 0 { wrapped.append("\n") }
            wrapped.append(ch)
        }
        let cardPNG = try expectNotNil(
            PNGTextChunks.injectTextChunk(into: basePNG, keyword: "chara", text: wrapped)
        )
        let result = try CharacterCardImporter.importPNGData(cardPNG)
        try expectEqual(result.character.name, "Nyx")
    }

    return s
}

// MARK: - Fixtures

/// Tiny opaque-teal PNG used as a base for tEXt chunk injection. The image
/// content is irrelevant — what matters is that AppKit emits a syntactically
/// valid PNG whose IEND we can splice ahead of.
private func makeTinyPNG() -> Data {
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
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: 4, height: 4).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

/// Canonical v2 card payload covering every field we map: name, all the
/// freeform text blocks, alternate greetings, system prompt, tags, creator,
/// and a two-entry character_book with one constant + secondary-keys row to
/// exercise the world-info mapping flags.
private let canonicalV2JSON = #"""
{
    "spec": "chara_card_v2",
    "spec_version": "2.0",
    "data": {
        "name": "Nyx",
        "description": "Half-elven ranger.",
        "personality": "Stoic, dry humor.",
        "scenario": "Lost in the borderlands.",
        "first_mes": "*She lowers her bow.* \"You're not who I expected.\"",
        "alternate_greetings": ["*She nocks an arrow.* \"Stop right there.\""],
        "system_prompt": "Always respond in third person.",
        "post_history_instructions": "Stay in character.",
        "tags": ["fantasy", "ranger"],
        "creator": "anon",
        "character_version": "1.0",
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
                    "priority": 3
                }
            ]
        }
    }
}
"""#
