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

    s.test("v1 cards are rejected with unsupportedSpec") {
        let v1 = #"""
        {
            "name": "Old Card",
            "description": "v1 shape, no spec, no data block"
        }
        """#
        do {
            _ = try CharacterCardImporter.importJSONData(Data(v1.utf8))
            try expectTrue(false, "expected throw")
        } catch CharacterCardImporter.ImportError.unsupportedSpec(let s) {
            try expectEqual(s, "chara_card_v1")
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
