import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — `CardGenExemplars` few-shot exemplar set + tag-overlap
/// selector. Per `V2_PHASE9_AI_ASSIST_RESEARCH.md` §4.1: three archetypes
/// (Mira / monstergirl / modern); selection is highest tag-set overlap;
/// ties resolve to Mira (the safest SFW-leaning baseline). Cold-start
/// (empty tags) also resolves to Mira.
///
/// The exemplar set is prompt-only — distinct from `CardCreatorPlaceholders`,
/// which is UI-only. They're allowed to overlap (Mira's content is shared
/// across both) but the selector lives in this layer.
func phase9dExemplarsTests() -> TestSuite {
    let s = TestSuite("Phase9dExemplars")

    // MARK: - Set membership

    s.test("all exemplars include mira / monstergirl / modern") {
        let ids = Set(CardGenExemplars.all.map(\.id))
        try expectEqual(ids, ["mira", "monstergirl", "modern"])
    }

    s.test("each exemplar populates every §4.4 graph field") {
        // The few-shot block iterates these field names and pulls each
        // exemplar's value. Missing entries would produce gaps in the
        // anchor; the selector contract is "every field is populated".
        let required: [String] = [
            "name", "description", "personality", "scenario",
            "firstMessage", "messageExample", "systemPrompt",
            "details_age", "details_pronouns", "details_species",
            "details_orientation", "details_appearance", "details_mood",
            "intimacy_build", "intimacy_anatomy", "intimacy_markings",
            "intimacy_sensitivities", "intimacy_scent",
            "intimacy_turn_ons", "intimacy_kinks", "intimacy_limits",
        ]
        for ex in CardGenExemplars.all {
            for field in required {
                let v = ex.fields[field] ?? ""
                try expectFalse(v.isEmpty, "\(ex.id): missing or empty field \(field)")
            }
        }
    }

    s.test("each exemplar's tag-set is non-empty") {
        for ex in CardGenExemplars.all {
            try expectFalse(ex.tags.isEmpty, "\(ex.id): tag-set is empty")
        }
    }

    // MARK: - Tag-overlap selector

    s.test("empty target tags resolves to Mira (cold-start fallback)") {
        let pick = CardGenExemplars.select(forTags: [])
        try expectEqual(pick.id, "mira")
    }

    s.test("tags entirely matching monstergirl resolve to monstergirl") {
        let pick = CardGenExemplars.select(forTags: ["nsfw", "fantasy", "monstergirl"])
        try expectEqual(pick.id, "monstergirl")
    }

    s.test("tags entirely matching modern resolve to modern") {
        let pick = CardGenExemplars.select(forTags: ["nsfw", "modern", "sci-fi"])
        try expectEqual(pick.id, "modern")
    }

    s.test("partial overlap picks the highest-scoring archetype") {
        // "monstergirl" tag alone is a strong monstergirl signal; "fantasy"
        // is shared but the archetype-specific tag carries the call.
        let pick = CardGenExemplars.select(forTags: ["fantasy", "monstergirl"])
        try expectEqual(pick.id, "monstergirl")
    }

    s.test("no overlap with any archetype falls back to Mira") {
        // Tags that no archetype has: invented "yarn-craft" + "lighthouse".
        let pick = CardGenExemplars.select(forTags: ["yarn-craft", "lighthouse-keeper"])
        try expectEqual(pick.id, "mira")
    }

    s.test("exact tie between archetypes resolves to Mira") {
        // Construct a tag set with one tag from monstergirl and one from
        // modern, no Mira-specific tags. Both should score 1; tie resolves
        // to Mira.
        let monsterOnly = CardGenExemplars.monstergirl.tags
            .subtracting(CardGenExemplars.modern.tags)
            .subtracting(CardGenExemplars.mira.tags)
        let modernOnly = CardGenExemplars.modern.tags
            .subtracting(CardGenExemplars.monstergirl.tags)
            .subtracting(CardGenExemplars.mira.tags)
        guard let monsterTag = monsterOnly.first, let modernTag = modernOnly.first else {
            try expectTrue(false, "tag-set design assumes monstergirl and modern each have at least one unique tag")
            return
        }
        let pick = CardGenExemplars.select(forTags: [monsterTag, modernTag])
        // Tie → Mira fallback per the research-doc contract.
        try expectEqual(pick.id, "mira")
    }

    s.test("case-insensitive tag matching") {
        // Author tag input is freely-typed; matching is case-insensitive
        // so "Monstergirl" and "monstergirl" score identically.
        let lower = CardGenExemplars.select(forTags: ["monstergirl"])
        let upper = CardGenExemplars.select(forTags: ["Monstergirl"])
        try expectEqual(lower.id, upper.id)
    }

    s.test("selection is deterministic (same input → same output)") {
        // Byte-stable selection matters for KV-cache reuse on the prompt
        // prefix — if the selector returns different exemplars for the
        // same tag set on different invocations, the prefix invalidates.
        let a = CardGenExemplars.select(forTags: ["nsfw", "fantasy"])
        let b = CardGenExemplars.select(forTags: ["nsfw", "fantasy"])
        let c = CardGenExemplars.select(forTags: ["nsfw", "fantasy"])
        try expectEqual(a.id, b.id)
        try expectEqual(b.id, c.id)
    }

    // MARK: - Diagnostic-log surface (research §4.1: log selected exemplar)

    s.test("selector exposes the score for diagnostic logging") {
        // The selector must be inspectable for the `cardgen: exemplar=...`
        // log line — return both the chosen exemplar AND its score so
        // diagnostic logging can record "exemplar=monstergirl score=2".
        let detail = CardGenExemplars.selectWithScore(forTags: ["nsfw", "fantasy", "monstergirl"])
        try expectEqual(detail.exemplar.id, "monstergirl")
        try expectGreaterThan(detail.score, 0)
    }

    return s
}
