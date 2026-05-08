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

    s.test("all exemplars include the seven shipped archetypes") {
        let ids = Set(CardGenExemplars.all.map(\.id))
        try expectEqual(ids, [
            "mira", "monstergirl", "modern",
            "spacer", "biopunk", "companion", "domestic",
        ])
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
        // The previous fixture used `sci-fi` as a non-archetype tag, but
        // the spacer/biopunk additions made it ambiguous. Use modern's
        // own archetype-specific tags instead.
        let pick = CardGenExemplars.select(forTags: ["nsfw", "modern", "urban"])
        try expectEqual(pick.id, "modern")
    }

    s.test("hard-sci-fi tag set resolves to spacer") {
        let pick = CardGenExemplars.select(forTags: ["sci-fi", "starship", "spacer"])
        try expectEqual(pick.id, "spacer")
    }

    s.test("biopunk tag set resolves to biopunk") {
        let pick = CardGenExemplars.select(forTags: ["sci-fi", "biopunk", "wetware"])
        try expectEqual(pick.id, "biopunk")
    }

    s.test("escort/companion tag set resolves to companion") {
        let pick = CardGenExemplars.select(forTags: ["nsfw", "adult", "escort"])
        try expectEqual(pick.id, "companion")
    }

    s.test("girlfriend / domestic tag set resolves to domestic") {
        let pick = CardGenExemplars.select(forTags: ["nsfw", "girlfriend", "domestic", "sweet"])
        try expectEqual(pick.id, "domestic")
    }

    s.test("ambiguous companion-vs-domestic resolves to Mira (tie-break baseline)") {
        // ["nsfw", "human", "modern", "femme"] hits companion + domestic
        // equally — the author hasn't disambiguated. Tie → Mira per
        // research-doc contract.
        let pick = CardGenExemplars.select(forTags: ["nsfw", "human", "modern", "femme"])
        try expectEqual(pick.id, "mira")
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
        // Construct a tag set with one tag truly unique to monstergirl
        // and one truly unique to modern (subtracted against EVERY other
        // exemplar, not just the named three — the §5.4.c follow-up
        // expanded the set to seven and `explicit` / `modern` are no
        // longer monstergirl/modern-exclusive). Both score exactly 1;
        // tie → Mira.
        let target: Set<String> = CardGenExemplars.monstergirl.tags
        let othersExcludingMonstergirl = CardGenExemplars.all
            .filter { $0.id != "monstergirl" }
            .reduce(Set<String>()) { acc, ex in acc.union(ex.tags) }
        let monsterOnly = target.subtracting(othersExcludingMonstergirl)
        let modernTarget: Set<String> = CardGenExemplars.modern.tags
        let othersExcludingModern = CardGenExemplars.all
            .filter { $0.id != "modern" }
            .reduce(Set<String>()) { acc, ex in acc.union(ex.tags) }
        let modernOnly = modernTarget.subtracting(othersExcludingModern)
        guard let monsterTag = monsterOnly.sorted().first,
              let modernTag = modernOnly.sorted().first else {
            try expectTrue(false, "tag-set design assumes monstergirl and modern each have at least one tag unique across all seven exemplars")
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
