import AppKit
import Foundation
@testable import RPClientCore

func characterPersonaTests() -> TestSuite {
    let s = TestSuite("CharacterPersona")

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

    // MARK: Persona

    s.test("Persona round-trip preserves all fields") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let p = Persona(
            id: UUID(),
            name: "Kira",
            description: "A jaded ex-detective with a soft spot for stray cats.",
            created: stamp
        )
        let data = try encoder.encode(p)
        let decoded = try decoder.decode(Persona.self, from: data)
        try expectEqual(decoded, p)
    }

    s.test("Persona decode tolerates missing fields") {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Anonymous"
        }
        """
        let p = try decoder.decode(Persona.self, from: Data(json.utf8))
        try expectEqual(p.name, "Anonymous")
        try expectEqual(p.description, "")
    }

    // MARK: Character

    s.test("Character round-trip preserves all fields including charBook") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let entry = WorldInfoEntry(
            name: "Castle",
            keys: ["castle", "keep"],
            content: "An old stone keep on the cliff.",
            tokenCap: 200
        )
        let c = Character(
            id: UUID(),
            name: "Nyx",
            description: "Half-elven ranger.",
            personality: "Stoic, dry humor.",
            scenario: "Lost in the borderlands.",
            firstMessage: "*She lowers her bow.* \"You're not who I expected.\"",
            alternateGreetings: ["*She nocks an arrow.* \"Stop right there.\""],
            systemPrompt: "Always respond in third person.",
            postHistoryInstructions: "Stay in character.",
            tags: ["fantasy", "ranger"],
            creator: "anon",
            characterVersion: "1.0",
            charBook: [entry],
            created: stamp
        )
        let data = try encoder.encode(c)
        let decoded = try decoder.decode(Character.self, from: data)
        try expectEqual(decoded, c)
    }

    s.test("Character decode tolerates missing optional fields") {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "name": "Bare",
            "description": "minimal"
        }
        """
        let c = try decoder.decode(Character.self, from: Data(json.utf8))
        try expectEqual(c.name, "Bare")
        try expectEqual(c.description, "minimal")
        try expectEqual(c.personality, "")
        try expectEqual(c.scenario, "")
        try expectEqual(c.firstMessage, "")
        try expectTrue(c.alternateGreetings.isEmpty)
        try expectNil(c.systemPrompt)
        try expectNil(c.postHistoryInstructions)
        try expectTrue(c.tags.isEmpty)
        try expectNil(c.creator)
        try expectNil(c.characterVersion)
        try expectTrue(c.charBook.isEmpty)
    }

    // MARK: Chat migration

    s.test("Chat decode without characterId/personaId leaves both nil") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Pre-Phase-3",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced"
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectNil(chat.characterId)
        try expectNil(chat.personaId)
    }

    s.test("Chat round-trip preserves characterId and personaId") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let charId = UUID()
        let perId = UUID()
        var chat = Chat(title: "Phase-3 chat")
        chat.created = stamp
        chat.modified = stamp
        chat.characterId = charId
        chat.personaId = perId
        let data = try encoder.encode(chat)
        let decoded = try decoder.decode(Chat.self, from: data)
        try expectEqual(decoded.characterId, charId)
        try expectEqual(decoded.personaId, perId)
    }

    // MARK: Avatar normalization

    s.test("normalizeAvatarData returns input unchanged when already small") {
        let small = makePNG(side: 256)
        let normalized = try expectNotNil(Storage.normalizeAvatarData(small))
        // Same bytes back — no re-encode for inputs already within the cap.
        try expectEqual(normalized.count, small.count)
    }

    s.test("normalizeAvatarData scales oversized inputs down to the cap") {
        let big = makePNG(side: 1024)
        let normalized = try expectNotNil(Storage.normalizeAvatarData(big))
        let img = try expectNotNil(NSImage(data: normalized))
        // Longest side ≤ 512 (Storage.avatarMaxDimension). NSImage's `.size`
        // is in points but we drew at 1:1 from a bitmap rep so the math is
        // exact.
        try expectTrue(max(img.size.width, img.size.height) <= Storage.avatarMaxDimension,
                       "expected longest side ≤ 512, got \(img.size)")
    }

    s.test("normalizeAvatarData rejects non-image bytes") {
        let bytes = Data("not a png".utf8)
        try expectNil(Storage.normalizeAvatarData(bytes))
    }

    // MARK: - newChat seeding (Phase 3 §4.4 step 4c)

    s.test("makeGreetingTurn returns nil for empty firstMessage") {
        let card = Character(name: "Marin", firstMessage: "")
        try expectNil(AppState.makeGreetingTurn(character: card))
    }

    s.test("makeGreetingTurn returns nil for whitespace-only firstMessage") {
        let card = Character(name: "Marin", firstMessage: "  \n  ")
        try expectNil(AppState.makeGreetingTurn(character: card))
    }

    s.test("makeGreetingTurn seeds an assistant turn with firstMessage as the active variant") {
        let card = Character(name: "Marin", firstMessage: "Welcome aboard.")
        let turn = try expectNotNil(AppState.makeGreetingTurn(character: card))
        try expectEqual(turn.role, .assistant)
        try expectEqual(turn.text, "Welcome aboard.")
        try expectEqual(turn.variants.count, 1)
        try expectEqual(turn.variants[0].text, "Welcome aboard.")
        try expectEqual(turn.activeVariant, 0)
    }

    s.test("makeGreetingTurn appends alternateGreetings as variants on the same turn") {
        let card = Character(
            name: "Marin",
            firstMessage: "Welcome aboard.",
            alternateGreetings: ["At the rail, glass raised.", "In her cabin, charts spread."]
        )
        let turn = try expectNotNil(AppState.makeGreetingTurn(character: card))
        try expectEqual(turn.variants.count, 3)
        try expectEqual(turn.variants[0].text, "Welcome aboard.")
        try expectEqual(turn.variants[1].text, "At the rail, glass raised.")
        try expectEqual(turn.variants[2].text, "In her cabin, charts spread.")
        // Active stays at 0 — the canonical greeting is what the user lands on.
        try expectEqual(turn.activeVariant, 0)
        // Mirror invariant: text == variants[active].text.
        try expectEqual(turn.text, turn.variants[turn.activeVariant].text)
    }

    s.test("makeGreetingTurn skips empty / whitespace-only alternateGreetings") {
        let card = Character(
            name: "Marin",
            firstMessage: "Welcome aboard.",
            alternateGreetings: ["Real alt.", "", "   \n  ", "Another real alt."]
        )
        let turn = try expectNotNil(AppState.makeGreetingTurn(character: card))
        try expectEqual(turn.variants.count, 3) // primary + 2 real alts
        try expectEqual(turn.variants[1].text, "Real alt.")
        try expectEqual(turn.variants[2].text, "Another real alt.")
    }

    return s
}

/// Build a solid-color square PNG of the given side length. Keeps the test
/// suite from depending on a fixture file when all we need is "an image of
/// known dimensions."
private func makePNG(side: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
