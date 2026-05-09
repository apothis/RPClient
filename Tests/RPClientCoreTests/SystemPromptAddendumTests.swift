import Foundation
@testable import RPClientCore

// User asked for two things layered into every chat:
//   1. Slightly longer replies (~4 paragraphs)
//   2. More detailed / anatomically accurate intimate descriptions
//      (age + body-type specific) when the scene calls for it
//
// Both belong on a `Settings.systemPromptAddendum` — global style
// guidance that rides alongside (NOT replacing) the character's
// `systemPrompt`. PromptBuilder.composeMemoryBlock layers it AFTER
// the character.systemPrompt and BEFORE the "user's name" line so
// the role (character) leads, then the meta-instructions about how
// to play it follow, then the user-context lines.
//
// Tests pin the layering + the empty-addendum no-op so a user who
// clears the field gets a clean prompt back.
func systemPromptAddendumTests() -> TestSuite {
    let s = TestSuite("SystemPromptAddendum")

    s.test("composeMemoryBlock emits the addendum after character.systemPrompt") {
        let c = Character(
            id: UUID(),
            name: "Mira",
            description: "ranger",
            systemPrompt: "You are Mira. Stay in third person past tense."
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: c,
            userName: "Sam",
            systemPromptAddendum: "Aim for roughly four paragraphs per reply."
        ) ?? ""
        // Both the character.systemPrompt and the addendum should be
        // present, and the character text should come FIRST.
        let charIdx = block.range(of: "You are Mira")!.lowerBound
        let addIdx = block.range(of: "Aim for roughly four paragraphs")!.lowerBound
        try expectTrue(charIdx < addIdx, "character.systemPrompt must come before the addendum")
        // And both should come before the "user's name" line.
        let userIdx = block.range(of: "user's name is Sam")!.lowerBound
        try expectTrue(addIdx < userIdx)
    }

    s.test("composeMemoryBlock with empty addendum is a no-op") {
        let c = Character(
            id: UUID(), name: "Mira",
            description: "ranger",
            systemPrompt: "You are Mira."
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let withEmpty = PromptBuilder.composeMemoryBlock(
            chat: chat, character: c, userName: "Sam", systemPromptAddendum: ""
        ) ?? ""
        let withDefault = PromptBuilder.composeMemoryBlock(
            chat: chat, character: c, userName: "Sam"
        ) ?? ""
        try expectEqual(withEmpty, withDefault)
    }

    s.test("composeMemoryBlock with whitespace-only addendum is a no-op") {
        // Defensive — user clears the field by typing spaces.
        let c = Character(id: UUID(), name: "Mira", description: "x")
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat, character: c, userName: "Sam",
            systemPromptAddendum: "   \n\n  \t  "
        ) ?? ""
        try expectFalse(block.contains("\t"), "whitespace-only addendum should not land in the block")
    }

    s.test("addendum lands even when character has no systemPrompt") {
        // Free-form chats / cards without an explicit systemPrompt
        // still benefit from the addendum (it's user-side style
        // guidance, character-independent).
        let c = Character(id: UUID(), name: "Mira", description: "x")
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat, character: c, userName: "Sam",
            systemPromptAddendum: "Be detailed."
        ) ?? ""
        try expectTrue(block.contains("Be detailed."))
    }

    s.test("addendum lands on free-form chats with no character") {
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat, character: nil, userName: "Sam",
            systemPromptAddendum: "Aim for four paragraphs."
        ) ?? ""
        try expectTrue(block.contains("Aim for four paragraphs."))
    }

    s.test("addendum substitutes {{user}} placeholders") {
        // The addendum is global style guidance but may reference
        // {{user}} (e.g. "Address {{user}} by name"). Substitute
        // through the same path as other system-block content so
        // the model sees the resolved name.
        let c = Character(id: UUID(), name: "Mira", description: "x")
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat, character: c, userName: "Sam",
            systemPromptAddendum: "Address {{user}} by their name when natural."
        ) ?? ""
        try expectFalse(block.contains("{{user}}"))
        try expectTrue(block.contains("Address Sam by their name"))
    }

    s.test("Settings.default carries useful addendum text out of the box") {
        // A fresh install should ship with the user's two requested
        // defaults baked in: ~4 paragraphs + NSFW anatomical detail.
        // Concrete substring checks pin the contract — if the wording
        // changes, this test fails loud and forces a deliberate edit.
        let s = Settings.default
        let lower = s.systemPromptAddendum.lowercased()
        try expectTrue(lower.contains("four paragraph"),
                       "default addendum should mention four-paragraph target")
        try expectTrue(lower.contains("anatomic"),
                       "default addendum should mention anatomical accuracy")
    }

    s.test("Settings round-trip preserves the addendum") {
        var s = Settings.default
        s.systemPromptAddendum = "Custom user guidance here."
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(s)
        let decoded = try decoder.decode(Settings.self, from: data)
        try expectEqual(decoded.systemPromptAddendum, "Custom user guidance here.")
    }

    s.test("Settings decode of legacy payload (no addendum key) gets the default") {
        // Migration safety: existing on-disk settings.json files
        // don't have the new key. Decode should fall back to
        // Settings.default's value, not crash, not produce an empty
        // string.
        let json = "{\"servers\":[{\"id\":\"\(UUID().uuidString)\",\"name\":\"Default\",\"baseURL\":\"http://localhost:5001\"}],\"defaultServerId\":\"00000000-0000-0000-0000-000000000000\"}"
        // The defaultServerId here doesn't match any server but the
        // decoder migrates that — see init(from:). Point of this test
        // is just that the addendum key absence doesn't blow up.
        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Settings.self, from: Data(json.utf8))
        try expectEqual(decoded.systemPromptAddendum, Settings.default.systemPromptAddendum)
    }

    return s
}
