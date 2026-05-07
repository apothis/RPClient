import Foundation
@testable import RPClientCore

/// Phase 9 §5.3c.2 — `CardDetails` / `CardIntimacy` structs + fence
/// render/parse + bidirectional sync with description.
func phase9cStructuredDetailsTests() -> TestSuite {
    let s = TestSuite("Phase9cStructuredDetails")

    // MARK: - CardDetails / CardIntimacy round-trip through JSONValue

    s.test("CardDetails round-trips through JSONValue") {
        let d = CardDetails(
            age: "28",
            pronouns: "she/her",
            species: "Human",
            orientation: "bisexual",
            appearance: "tall, lean, copper braid",
            mood: "wry, grounded"
        )
        let v = d.toJSONValue()
        let back = try expectNotNil(CardDetails.fromJSONValue(v))
        try expectEqual(back, d)
    }

    s.test("CardDetails toJSONValue omits empty fields") {
        let d = CardDetails(age: "28", pronouns: "", species: "", orientation: "", appearance: "", mood: "")
        let v = d.toJSONValue()
        if case .object(let obj) = v {
            try expectEqual(obj.keys.count, 1)
            try expectEqual(obj["age"], .string("28"))
        } else {
            try expectTrue(false, "expected .object, got \(v)")
        }
    }

    s.test("CardDetails fromJSONValue tolerates missing keys") {
        let v: JSONValue = .object(["age": .string("30")])
        let d = try expectNotNil(CardDetails.fromJSONValue(v))
        try expectEqual(d.age, "30")
        try expectEqual(d.pronouns, "")
        try expectEqual(d.appearance, "")
    }

    s.test("CardIntimacy round-trips through JSONValue") {
        let i = CardIntimacy(
            build: "lean, runner's frame",
            anatomy: "small chest, freckled",
            markings: "dragon tattoo, faded scar",
            sensitivities: "scalp, nape",
            scent: "cedar, leather",
            turnOns: "praise, slow build",
            kinks: "collars, edging",
            limits: "no family roles"
        )
        let v = i.toJSONValue()
        let back = try expectNotNil(CardIntimacy.fromJSONValue(v))
        try expectEqual(back, i)
    }

    s.test("CardIntimacy.fromJSONValue migrates legacy 'body' key into 'anatomy'") {
        // Pre-§5.3c.2-split shape: a single `body` field. After the split,
        // legacy on-disk records still need to populate the form. Read
        // body into anatomy when anatomy itself is missing.
        let v: JSONValue = .object([
            "body": .string("small chest, freckled shoulders"),
            "limits": .string("no family roles"),
        ])
        let i = try expectNotNil(CardIntimacy.fromJSONValue(v))
        try expectEqual(i.anatomy, "small chest, freckled shoulders")
        try expectEqual(i.build, "")
        try expectEqual(i.markings, "")
        try expectEqual(i.limits, "no family roles")
    }

    s.test("CardIntimacy.fromJSONValue prefers 'anatomy' when both legacy 'body' and new 'anatomy' present") {
        let v: JSONValue = .object([
            "body": .string("legacy"),
            "anatomy": .string("new"),
        ])
        let i = try expectNotNil(CardIntimacy.fromJSONValue(v))
        try expectEqual(i.anatomy, "new")
    }

    s.test("CardDetails.isEmpty returns true when every field is blank") {
        let d = CardDetails(age: "", pronouns: "", species: "", orientation: "", appearance: "", mood: "")
        try expectTrue(d.isEmpty)
    }

    s.test("CardDetails.isEmpty returns false when any field is set") {
        let d = CardDetails(age: "28", pronouns: "", species: "", orientation: "", appearance: "", mood: "")
        try expectTrue(!d.isEmpty)
    }

    // MARK: - Fence rendering

    s.test("render produces inline form for single-line values") {
        let d = CardDetails(
            age: "28",
            pronouns: "she/her",
            species: "Human",
            orientation: "bisexual",
            appearance: "tall, lean, copper braid",
            mood: "wry, grounded"
        )
        let rendered = CardStructuredFence.render(d)
        try expectTrue(rendered.hasPrefix("[character_details]\n"))
        try expectTrue(rendered.hasSuffix("\n[/character_details]"))
        try expectTrue(rendered.contains("age: 28"))
        try expectTrue(rendered.contains("pronouns: she/her"))
        try expectTrue(rendered.contains("appearance: tall, lean, copper braid"))
    }

    s.test("render uses indented block for multi-line values") {
        let i = CardIntimacy(
            anatomy: "small chest\nfaint freckles\nsensitive at the nape",
            turnOns: "praise, slow build"
        )
        let rendered = CardStructuredFence.render(i)
        // Multi-line `anatomy` should use the indented-continuation form.
        try expectTrue(rendered.contains("anatomy:\n  small chest\n  faint freckles\n  sensitive at the nape"))
        // Single-line `turn_ons` stays inline.
        try expectTrue(rendered.contains("turn_ons: praise, slow build"))
    }

    s.test("render returns empty string when struct isEmpty") {
        let d = CardDetails(age: "", pronouns: "", species: "", orientation: "", appearance: "", mood: "")
        try expectEqual(CardStructuredFence.render(d), "")
    }

    s.test("render with intimacy uses [character_intimacy] fence") {
        let i = CardIntimacy(anatomy: "x")
        let rendered = CardStructuredFence.render(i)
        try expectTrue(rendered.hasPrefix("[character_intimacy]\n"))
        try expectTrue(rendered.hasSuffix("\n[/character_intimacy]"))
    }

    s.test("render writes build/anatomy/markings post-split — never legacy body") {
        let i = CardIntimacy(
            build: "lean",
            anatomy: "freckled",
            markings: "tattoo"
        )
        let rendered = CardStructuredFence.render(i)
        try expectTrue(rendered.contains("build: lean"))
        try expectTrue(rendered.contains("anatomy: freckled"))
        try expectTrue(rendered.contains("markings: tattoo"))
        try expectTrue(!rendered.contains("body:"), "body key is post-split-deprecated")
    }

    // MARK: - Fence parsing

    s.test("parse details fence with inline values") {
        let text = """
        [character_details]
        age: 28
        pronouns: she/her
        species: Human
        appearance: tall, lean
        [/character_details]
        """
        let d = try expectNotNil(CardStructuredFence.parseDetails(in: text))
        try expectEqual(d.age, "28")
        try expectEqual(d.pronouns, "she/her")
        try expectEqual(d.species, "Human")
        try expectEqual(d.appearance, "tall, lean")
        try expectEqual(d.mood, "")
    }

    s.test("parse intimacy fence with multi-line indented anatomy") {
        let text = """
        [character_intimacy]
        anatomy:
          small chest
          faint freckles
          sensitive at the nape
        turn_ons: praise, slow build
        [/character_intimacy]
        """
        let i = try expectNotNil(CardStructuredFence.parseIntimacy(in: text))
        try expectEqual(i.anatomy, "small chest\nfaint freckles\nsensitive at the nape")
        try expectEqual(i.turnOns, "praise, slow build")
    }

    s.test("parse migrates legacy body key in fence into anatomy") {
        // Pre-split fences carried `body: ...` directly. After §5.3c.2's
        // split, the parser maps it to `anatomy` so existing description
        // blocks repopulate the form correctly.
        let text = """
        [character_intimacy]
        body:
          freckled, with a faint dragon tattoo
        turn_ons: praise
        [/character_intimacy]
        """
        let i = try expectNotNil(CardStructuredFence.parseIntimacy(in: text))
        try expectEqual(i.anatomy, "freckled, with a faint dragon tattoo")
        try expectEqual(i.turnOns, "praise")
    }

    s.test("parse returns nil when no fence present") {
        let text = "just a description, no fences here"
        try expectTrue(CardStructuredFence.parseDetails(in: text) == nil)
        try expectTrue(CardStructuredFence.parseIntimacy(in: text) == nil)
    }

    s.test("parse tolerates extra whitespace in key/value separators") {
        let text = """
        [character_details]
        age:    28
        pronouns:she/her
        [/character_details]
        """
        let d = try expectNotNil(CardStructuredFence.parseDetails(in: text))
        try expectEqual(d.age, "28")
        try expectEqual(d.pronouns, "she/her")
    }

    s.test("parse ignores unknown keys gracefully") {
        let text = """
        [character_details]
        age: 28
        unknown_key: stuff that shouldn't crash
        species: Human
        [/character_details]
        """
        let d = try expectNotNil(CardStructuredFence.parseDetails(in: text))
        try expectEqual(d.age, "28")
        try expectEqual(d.species, "Human")
    }

    s.test("render → parse round-trips full data") {
        let d = CardDetails(
            age: "28",
            pronouns: "she/her",
            species: "Human",
            orientation: "bisexual",
            appearance: "tall, lean,\ncopper braid down her back",
            mood: "wry,\ngrounded,\neasily provoked"
        )
        let rendered = CardStructuredFence.render(d)
        let parsed = try expectNotNil(CardStructuredFence.parseDetails(in: rendered))
        try expectEqual(parsed, d)
    }

    s.test("parse picks the first fence when description contains the marker text twice") {
        let text = """
        [character_details]
        age: 28
        [/character_details]

        Earlier the user wrote: she said "[character_details] is the marker".
        """
        let d = try expectNotNil(CardStructuredFence.parseDetails(in: text))
        try expectEqual(d.age, "28")
    }

    // MARK: - mergeIntoDescription

    s.test("mergeIntoDescription prepends fences when description has none") {
        let d = CardDetails(age: "28", pronouns: "she/her")
        let i = CardIntimacy(turnOns: "praise")
        let original = "An archivist who keeps to themselves."
        let merged = CardStructuredFence.mergeIntoDescription(original, details: d, intimacy: i)
        try expectTrue(merged.hasPrefix("[character_details]"))
        try expectTrue(merged.contains("age: 28"))
        try expectTrue(merged.contains("[character_intimacy]"))
        try expectTrue(merged.contains("turn_ons: praise"))
        try expectTrue(merged.contains("An archivist who keeps to themselves."))
    }

    s.test("mergeIntoDescription replaces existing details fence") {
        let d = CardDetails(age: "30", pronouns: "they/them")
        let original = """
        [character_details]
        age: 28
        pronouns: she/her
        [/character_details]

        Some prose follows.
        """
        let merged = CardStructuredFence.mergeIntoDescription(original, details: d, intimacy: nil)
        try expectTrue(merged.contains("age: 30"))
        try expectTrue(merged.contains("pronouns: they/them"))
        try expectTrue(!merged.contains("age: 28"))
        try expectTrue(merged.contains("Some prose follows."))
    }

    s.test("mergeIntoDescription removes an existing fence when new struct is empty") {
        let original = """
        [character_details]
        age: 28
        [/character_details]

        Some prose.
        """
        let merged = CardStructuredFence.mergeIntoDescription(
            original,
            details: CardDetails(),
            intimacy: nil
        )
        try expectTrue(!merged.contains("[character_details]"))
        try expectTrue(merged.contains("Some prose."))
    }

    s.test("mergeIntoDescription leaves description untouched when both nil and no existing fences") {
        let original = "An archivist."
        let merged = CardStructuredFence.mergeIntoDescription(original, details: nil, intimacy: nil)
        try expectEqual(merged, original)
    }

    s.test("mergeIntoDescription preserves both fences when both present and renews them") {
        let d = CardDetails(age: "28")
        let i = CardIntimacy(anatomy: "soft")
        let original = """
        [character_details]
        age: old-stale
        [/character_details]

        [character_intimacy]
        anatomy: old-stale
        [/character_intimacy]

        Prose body.
        """
        let merged = CardStructuredFence.mergeIntoDescription(original, details: d, intimacy: i)
        try expectTrue(merged.contains("age: 28"))
        try expectTrue(merged.contains("anatomy: soft"))
        try expectTrue(!merged.contains("old-stale"))
        try expectTrue(merged.contains("Prose body."))
    }

    return s
}
