import Foundation
@testable import RPClientCore

// Bug: cards use `{{char}}` / `{{user}}` placeholders (SillyTavern
// chara_card_v2 standard) which the chat runtime is supposed to
// substitute before sending to the model. RPClient was sending
// them through verbatim — Emily was hallucinated as "Mia" because
// the model had no anchor for what `{{char}}` referred to.
//
// Tests pin the substitution semantics at every layer that touches
// card content destined for the model:
//   - systemPrompt, description, personality, scenario,
//     postHistoryInstructions (prompt-assembly time, every send)
//   - firstMessage, alternateGreetings (chat-seed time, once)
//
// Substitution is case-insensitive (`{{Char}}`, `{{CHAR}}` all
// resolve) — defensive against cards from other tools that don't
// stick to the lowercase canonical form.
func placeholderSubstitutionTests() -> TestSuite {
    let s = TestSuite("PlaceholderSubstitution")

    s.test("replaces {{char}} with the character name") {
        let out = PlaceholderSubstitution.apply(
            "Portray {{char}} as a ranger.",
            characterName: "Emily",
            userName: "Sam"
        )
        try expectEqual(out, "Portray Emily as a ranger.")
    }

    s.test("replaces {{user}} with the user name") {
        let out = PlaceholderSubstitution.apply(
            "{{user}} arrives at the gate.",
            characterName: "Emily",
            userName: "Sam"
        )
        try expectEqual(out, "Sam arrives at the gate.")
    }

    s.test("replaces both, multiple times") {
        let out = PlaceholderSubstitution.apply(
            "{{char}} greets {{user}}. {{char}} smiles. {{user}} smiles back.",
            characterName: "Emily",
            userName: "Sam"
        )
        try expectEqual(out, "Emily greets Sam. Emily smiles. Sam smiles back.")
    }

    s.test("is case-insensitive on the placeholder name") {
        // Defensive against cards from other tools that use {{Char}}
        // or {{CHAR}}; canonical is lowercase but be tolerant.
        let out = PlaceholderSubstitution.apply(
            "{{Char}} and {{USER}} and {{char}} and {{user}}.",
            characterName: "Emily",
            userName: "Sam"
        )
        try expectEqual(out, "Emily and Sam and Emily and Sam.")
    }

    s.test("empty userName falls back to 'User'") {
        // Persona-less chats with no Settings.userName set —
        // emitting an empty string for {{user}} would produce
        // grammatically broken sentences. 'User' is the SillyTavern
        // fallback too.
        let out = PlaceholderSubstitution.apply(
            "{{user}} hires {{char}}.",
            characterName: "Emily",
            userName: ""
        )
        try expectEqual(out, "User hires Emily.")
    }

    s.test("text without placeholders is returned unchanged") {
        let raw = "No placeholders here. Just regular prose."
        let out = PlaceholderSubstitution.apply(raw, characterName: "Emily", userName: "Sam")
        try expectEqual(out, raw)
    }

    s.test("text without character name still substitutes {{user}}") {
        // Sanity: passing a blank character name shouldn't blow up
        // OR substitute {{char}} with an empty string (which would
        // break grammar). Instead we leave {{char}} untouched when
        // no character is available — the model at least has the
        // raw token to fall back to.
        let out = PlaceholderSubstitution.apply(
            "{{char}} greets {{user}}.",
            characterName: "",
            userName: "Sam"
        )
        try expectEqual(out, "{{char}} greets Sam.")
    }

    // MARK: - Integration: PromptBuilder.composeMemoryBlock substitutes

    s.test("PromptBuilder.composeMemoryBlock substitutes {{char}} in description/personality/scenario") {
        let c = Character(
            id: UUID(),
            name: "Emily",
            description: "{{char}} is a 20-year-old prostitute.",
            personality: "{{char}} is fragile.",
            scenario: "{{user}} meets {{char}} at a bar.",
            firstMessage: "Hey {{user}}",
            systemPrompt: "Portray {{char}} as petite. Don't break character."
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        let block = PromptBuilder.composeMemoryBlock(chat: chat, character: c, userName: "Sam") ?? ""
        try expectFalse(block.contains("{{char}}"), "{{char}} should be substituted in memory block")
        try expectFalse(block.contains("{{user}}"), "{{user}} should be substituted in memory block")
        try expectTrue(block.contains("Emily is a 20-year-old prostitute"))
        try expectTrue(block.contains("Sam meets Emily"))
        try expectTrue(block.contains("Portray Emily as petite"))
    }

    s.test("PromptBuilder.composeMemoryBlock substitutes {{user}} with empty userName fallback") {
        let c = Character(
            id: UUID(),
            name: "Emily",
            description: "{{user}} loves {{char}}.",
            scenario: "scenario"
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        // Empty userName — should still substitute (fallback to "User")
        // not leave the literal placeholder.
        let block = PromptBuilder.composeMemoryBlock(chat: chat, character: c, userName: "") ?? ""
        try expectFalse(block.contains("{{user}}"))
        try expectTrue(block.contains("User loves Emily"))
    }

    s.test("PromptBuilder.build substitutes {{char}} / {{user}} in turn text (existing chats)") {
        // Regression for the Emily "Mia" bug: the seeded greeting was
        // persisted with literal `{{char}}` before substitution shipped.
        // SillyTavern convention is "placeholder is source of truth on
        // disk; substitute at every render" — so the chat path must
        // substitute in chat-history turn text too, not just in card
        // fields read live.
        let c = Character(
            id: UUID(),
            name: "Emily",
            description: "Test desc",
            firstMessage: "irrelevant for this test"
        )
        var chat = Chat(id: UUID(), title: "x", templateId: "qwen")
        chat.characterId = c.id
        var greeting = Turn(role: .assistant, text: "Hey there, {{user}}, I am {{char}}.")
        chat.turns = [greeting]
        chat.activePath = [greeting.id]

        let result = PromptBuilder.build(chat: chat, character: c, persona: Persona(name: "Sam"))
        try expectFalse(result.prompt.contains("{{char}}"), "{{char}} should be substituted in turn text")
        try expectFalse(result.prompt.contains("{{user}}"), "{{user}} should be substituted in turn text")
        try expectTrue(result.prompt.contains("Hey there, Sam, I am Emily."))
    }

    s.test("PromptBuilder.effectiveAuthorsNote substitutes in postHistoryInstructions") {
        let c = Character(
            id: UUID(),
            name: "Emily",
            postHistoryInstructions: "Remember {{char}} is talking to {{user}}."
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.characterId = c.id
        // Empty user-set authorsNote → falls back to PHI.
        let an = PromptBuilder.effectiveAuthorsNote(chat: chat, character: c, userName: "Sam")
        let unwrapped = try expectNotNil(an)
        try expectEqual(unwrapped.text, "Remember Emily is talking to Sam.")
    }

    return s
}
