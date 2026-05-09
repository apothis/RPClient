import Foundation
@testable import RPClientCore

// Bug observed 2026-05-09: starting a chat with Emily produced an
// entity stub (name + type=character + pinnedByUser=true) but with
// ZERO facts — even though Emily's card had a populated
// [character_details] fence (sex/age/appearance/mood) AND
// [character_intimacy] fence (build/anatomy/markings/etc).
// `ensureCharacterEntity` only created the name/type stub; it
// never read the structured card data.
//
// Fix: `ensureCharacterEntity` seeds facts from
// `Character.extensions["rpclient/details"]` and
// `["rpclient/intimacy"]` (or the description-fence fallback) on
// FIRST creation. Existing chats with empty stubs (the Emily case)
// also get backfilled — but only when the entity has zero facts
// (so user-curated entities are never overwritten).
func characterEntitySeedTests() -> TestSuite {
    let s = TestSuite("CharacterEntitySeed")

    // Build a character with structured details + intimacy in BOTH
    // the extensions blob and the description fence (mirrors what
    // CardCreator.commit() produces — the spec-compliant on-disk
    // shape that round-trips through other v2/v3 readers).
    @MainActor
    func makeEmily() -> Character {
        var c = Character(
            id: UUID(),
            name: "Emily",
            description: "Emily is a {{char}} prostitute.",
            personality: "Submissive.",
            firstMessage: "Hey {{user}}.",
            systemPrompt: "Portray {{char}} as petite."
        )
        var details = CardDetails()
        details.sex = "Female"
        details.age = "20"
        details.appearance = "Petite, tiny waist, delicate shoulders."
        details.mood = "Desperate, eager."
        details.applyTo(&c)
        var intimacy = CardIntimacy()
        intimacy.build = "Petite frame."
        intimacy.kinks = "Watersports, rough handling."
        intimacy.applyTo(&c)
        // Mirror into description fence too (CardCreator does this on save).
        c.description = CardStructuredFence.mergeIntoDescription(
            c.description, details: details, intimacy: intimacy
        )
        return c
    }

    s.test("ensureCharacterEntity seeds facts from card details + intimacy") {
        let emily = makeEmily()
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.ensureCharacterEntity(emily)

        try expectEqual(chat.entities.count, 1)
        let ent = chat.entities[0]
        try expectEqual(ent.name, "Emily")
        try expectEqual(ent.type, .character)
        try expectTrue(ent.pinnedByUser)
        // Should have at least one fact per non-empty CardDetails +
        // CardIntimacy field. Counting exactly 6 here (sex, age,
        // appearance, mood from details; build, kinks from intimacy).
        try expectEqual(ent.facts.count, 6, "expected 6 facts (4 details + 2 intimacy), got \(ent.facts.count)")

        let factTexts = Set(ent.facts.map(\.text))
        try expectTrue(factTexts.contains("Sex: Female"))
        try expectTrue(factTexts.contains("Age: 20"))
        try expectTrue(factTexts.contains("Appearance: Petite, tiny waist, delicate shoulders."))
        try expectTrue(factTexts.contains("Mood: Desperate, eager."))
        try expectTrue(factTexts.contains("Build: Petite frame."))
        try expectTrue(factTexts.contains("Kinks: Watersports, rough handling."))
    }

    s.test("ensureCharacterEntity is idempotent (second call doesn't duplicate facts)") {
        let emily = makeEmily()
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.ensureCharacterEntity(emily)
        let firstCount = chat.entities[0].facts.count
        chat.ensureCharacterEntity(emily)
        // Second call: entity already exists with facts → no-op.
        try expectEqual(chat.entities.count, 1)
        try expectEqual(chat.entities[0].facts.count, firstCount)
    }

    s.test("ensureCharacterEntity backfills an existing empty stub (Emily case)") {
        // Simulate the on-disk Emily chat: entity exists for the
        // bound character but has zero facts because it was created
        // before structured-card seeding was wired. Backfill should
        // populate the facts in-place.
        let emily = makeEmily()
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        // Pre-seed the empty stub the way old ensureCharacterEntity did.
        chat.entities = [Entity(name: emily.name, type: .character, pinnedByUser: true)]
        try expectEqual(chat.entities[0].facts.count, 0)

        chat.ensureCharacterEntity(emily)
        try expectGreaterThan(chat.entities[0].facts.count, 0)
        try expectEqual(chat.entities.count, 1, "should still be exactly one entity")
    }

    s.test("ensureCharacterEntity does NOT overwrite an existing user-curated entity") {
        // If the user already curated facts on the matched entity,
        // backfill must not run — that's user data we'd be erasing.
        let emily = makeEmily()
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        var existing = Entity(name: emily.name, type: .character, pinnedByUser: true)
        existing.facts = [Fact(text: "user-curated fact A"), Fact(text: "user-curated fact B")]
        chat.entities = [existing]

        chat.ensureCharacterEntity(emily)
        try expectEqual(chat.entities.count, 1)
        try expectEqual(chat.entities[0].facts.count, 2)
        try expectEqual(Set(chat.entities[0].facts.map(\.text)),
                        ["user-curated fact A", "user-curated fact B"])
    }

    s.test("ensureCharacterEntity with no structured data still creates the stub (no facts)") {
        // Cards without [character_details] / [character_intimacy] —
        // legacy v1 cards or freshly-imported cards from other tools —
        // should still produce the entity stub so voice routing works.
        // Just no facts to seed.
        let plain = Character(
            id: UUID(),
            name: "PlainBob",
            description: "Just a guy. No structured fields."
        )
        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.ensureCharacterEntity(plain)
        try expectEqual(chat.entities.count, 1)
        try expectEqual(chat.entities[0].name, "PlainBob")
        try expectEqual(chat.entities[0].facts.count, 0)
    }

    s.test("ensureCharacterEntity reads from extensions when description fence absent") {
        // Spec-compliant case: structured data lives in extensions
        // ONLY (no fence in description). Should still work.
        var c = Character(
            id: UUID(),
            name: "Anya",
            description: "Plain prose, no fence."
        )
        var details = CardDetails()
        details.sex = "Female"
        details.age = "36"
        details.applyTo(&c)
        // Don't merge into description — extensions only.

        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.ensureCharacterEntity(c)
        try expectEqual(chat.entities.count, 1)
        let factTexts = Set(chat.entities[0].facts.map(\.text))
        try expectTrue(factTexts.contains("Sex: Female"))
        try expectTrue(factTexts.contains("Age: 36"))
    }

    s.test("ensureCharacterEntity falls back to description fence when extensions absent") {
        // Some cards (legacy or imports) carry the fence in
        // description without the extensions blob. Parser should
        // pick up either source.
        var c = Character(
            id: UUID(),
            name: "Mira",
            description: ""
        )
        let details = CardDetails(sex: "Female", age: "28", appearance: "Tall, lean.")
        c.description = CardStructuredFence.mergeIntoDescription(
            c.description, details: details, intimacy: nil
        )
        // Don't apply to extensions.

        var chat = Chat(id: UUID(), title: "test", templateId: "qwen")
        chat.ensureCharacterEntity(c)
        try expectEqual(chat.entities.count, 1)
        let factTexts = Set(chat.entities[0].facts.map(\.text))
        try expectTrue(factTexts.contains("Sex: Female"))
        try expectTrue(factTexts.contains("Age: 28"))
        try expectTrue(factTexts.contains("Appearance: Tall, lean."))
    }

    return s
}
