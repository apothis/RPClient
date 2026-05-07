import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — `CardFieldGenerator.buildPrompt(...)` byte-
/// deterministic prompt builder + `CardGenPromptsLoader` registry.
/// Source of truth: `V2_PHASE9_AI_ASSIST_RESEARCH.md` §3.2 (prefix-
/// stable layout) + §4.3 (candidate triad) + §11 (registry schema).
func phase9dPromptBuilderTests() -> TestSuite {
    let s = TestSuite("Phase9dPromptBuilder")

    let bundled = CardGenPromptsLoader.bundled

    // MARK: - Registry coverage + shape

    s.test("bundled registry parses cleanly + version is 1") {
        try expectEqual(bundled.version, 1)
        try expectFalse(bundled.systemPrompt.isEmpty)
    }

    s.test("registry has every CardCandidateStyle in candidateDefaults") {
        for style in CardCandidateStyle.allCases {
            let entry = try expectNotNil(bundled.candidateDefaults[style.rawValue])
            try expectGreaterThan(entry.temperature, 0)
            try expectGreaterThan(entry.maxTokens, 0)
            try expectFalse(entry.instruction.isEmpty, "\(style) has empty instruction template")
        }
    }

    s.test("registry has FieldPrompt for every CardField") {
        for field in CardField.allCases {
            try expectNotNil(bundled.fields[field.rawValue])
            let entry = bundled.fields[field.rawValue]!
            try expectFalse(entry.humanName.isEmpty, "\(field.rawValue) has empty humanName")
            try expectGreaterThan(entry.wordCount, 0)
        }
    }

    s.test("system prompt mentions the {{user}} / {{char}} convention") {
        // The bundled exemplar set uses {{user}} / {{char}}; the
        // system prompt must signal this to the model. Otherwise the
        // model invents a player-name and the cards stop round-
        // tripping.
        try expectTrue(bundled.systemPrompt.contains("{{user}}"))
        try expectTrue(bundled.systemPrompt.contains("{{char}}"))
    }

    s.test("system prompt grants explicit-content license") {
        // Per research §5 — the canonical "Explicit content is allowed"
        // phrasing must appear so models with NSFW training comply
        // without escalation or jailbreak prompting.
        let lower = bundled.systemPrompt.lowercased()
        try expectTrue(lower.contains("explicit content"), "system prompt missing NSFW license phrase")
    }

    // MARK: - Determinism (KV-cache invariant)

    s.test("buildPrompt is byte-deterministic for the same input") {
        let draft = CardDraftSnapshot(
            tags: ["fantasy", "monstergirl", "nsfw"],
            fields: [.name: "Vexara", .description: "A Lamia matriarch."]
        )
        let a = CardFieldGenerator.buildPrompt(for: .personality, style: .literal, draft: draft)
        let b = CardFieldGenerator.buildPrompt(for: .personality, style: .literal, draft: draft)
        let c = CardFieldGenerator.buildPrompt(for: .personality, style: .literal, draft: draft)
        try expectEqual(a.prompt, b.prompt)
        try expectEqual(b.prompt, c.prompt)
        try expectEqual(a.temperature, b.temperature)
        try expectEqual(a.maxTokens, b.maxTokens)
    }

    s.test("buildPrompt is invariant to tag input ordering") {
        // KV-cache reuse depends on byte-stable prefix; if user types
        // ['nsfw', 'fantasy'] vs ['fantasy', 'nsfw'], the prompt must
        // be identical or every reorder invalidates the cache.
        let a = CardFieldGenerator.buildPrompt(
            for: .description, style: .creative,
            draft: CardDraftSnapshot(tags: ["nsfw", "fantasy", "monstergirl"], fields: [.name: "Vexara"])
        )
        let b = CardFieldGenerator.buildPrompt(
            for: .description, style: .creative,
            draft: CardDraftSnapshot(tags: ["monstergirl", "fantasy", "nsfw"], fields: [.name: "Vexara"])
        )
        try expectEqual(a.prompt, b.prompt)
    }

    // MARK: - Block presence + structure

    s.test("prompt contains the system prompt block verbatim") {
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: .empty
        )
        try expectTrue(r.prompt.contains(bundled.systemPrompt))
    }

    s.test("prompt contains an EXAMPLE CHARACTER section") {
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: .empty
        )
        try expectTrue(r.prompt.contains("EXAMPLE CHARACTER"))
    }

    s.test("exemplar block contains the chosen exemplar's name") {
        // Empty draft → mira fallback. Mira's name should appear in the
        // exemplar block so the model sees a concrete anchor.
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: .empty
        )
        try expectTrue(r.prompt.contains("Mira"), "expected Mira in exemplar block, prompt was: \(r.prompt.prefix(500))")
    }

    s.test("monstergirl-tagged draft picks Vexara exemplar") {
        let draft = CardDraftSnapshot(
            tags: ["fantasy", "monstergirl", "nsfw"], fields: [:]
        )
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .creative, draft: draft
        )
        try expectEqual(r.exemplarId, "monstergirl")
        try expectTrue(r.prompt.contains("Vexara"))
    }

    s.test("modern-tagged draft picks Alex Rivers exemplar") {
        let draft = CardDraftSnapshot(
            tags: ["modern", "urban", "journalist"], fields: [:]
        )
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .creative, draft: draft
        )
        try expectEqual(r.exemplarId, "modern")
        try expectTrue(r.prompt.contains("Alex Rivers"))
    }

    // MARK: - Upstream-fields block

    s.test("upstream block omitted when no upstream fields are populated") {
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: .empty
        )
        try expectFalse(r.prompt.contains("TARGET CHARACTER"),
            "empty draft should not produce a TARGET CHARACTER section")
    }

    s.test("upstream block includes the populated upstream fields") {
        let draft = CardDraftSnapshot(
            tags: ["fantasy"],
            fields: [.name: "Mira"]
        )
        // description's upstreams: [.name, .tags]
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: draft
        )
        try expectTrue(r.prompt.contains("TARGET CHARACTER"))
        try expectTrue(r.prompt.contains("name: Mira"))
        try expectTrue(r.prompt.contains("tags: fantasy"))
    }

    s.test("upstream block excludes fields NOT in the dep graph") {
        // description's upstreams are [.name, .tags] — NOT systemPrompt.
        // Even though the draft has a populated systemPrompt, the
        // upstream block for `description` must not include it.
        let draft = CardDraftSnapshot(
            tags: ["fantasy"],
            fields: [
                .name: "Mira",
                .systemPrompt: "You are Mira. Stay in character.",
            ]
        )
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: draft
        )
        try expectTrue(r.prompt.contains("name: Mira"))
        try expectFalse(r.prompt.contains("You are Mira. Stay in character."),
            "system_prompt is not an upstream of description; should not appear")
    }

    s.test("upstream block excludes empty-string field values") {
        let draft = CardDraftSnapshot(
            tags: ["fantasy"],
            fields: [.name: "Mira", .description: ""]
        )
        // For 'personality' (upstream: name + description + tags),
        // the empty description should not produce a 'description: '
        // bare-key line.
        let r = CardFieldGenerator.buildPrompt(
            for: .personality, style: .literal, draft: draft
        )
        try expectTrue(r.prompt.contains("name: Mira"))
        try expectFalse(r.prompt.contains("description: \n"),
            "empty description should be skipped, not emitted as bare-key line")
        try expectFalse(r.prompt.contains("description: TASK"),
            "empty description must not collide with TASK section")
    }

    s.test("upstream block collapses multi-line values to single line") {
        let multi = "Mira runs the dawn patrol.\nLives above the inn.\nAdvise: don't.\n"
        let draft = CardDraftSnapshot(
            tags: ["fantasy"],
            fields: [.name: "Mira", .description: multi]
        )
        let r = CardFieldGenerator.buildPrompt(
            for: .personality, style: .literal, draft: draft
        )
        // The description value should appear as a one-line entry in
        // the upstream block; embedded newlines would corrupt the
        // block's per-line structure.
        try expectFalse(r.prompt.contains("Mira runs the dawn patrol.\nLives above the inn"),
            "multi-line value should be collapsed; got the raw newline shape")
        try expectTrue(r.prompt.contains("Mira runs the dawn patrol. Lives above the inn."))
    }

    s.test("intimacy_limits prompt has no upstream block (cold-start field)") {
        let draft = CardDraftSnapshot(
            tags: ["nsfw", "fantasy"],
            fields: [.name: "Mira", .description: "...", .personality: "..."]
        )
        let r = CardFieldGenerator.buildPrompt(
            for: .intimacyLimits, style: .literal, draft: draft
        )
        // intimacy_limits has zero upstreams per the dep graph; even
        // though the draft has tags + name + description + personality,
        // none of them should land in the upstream block for this field.
        try expectFalse(r.prompt.contains("TARGET CHARACTER"))
    }

    // MARK: - Candidate-style differentiation

    s.test("candidate-styles produce different per-call instructions") {
        let draft = CardDraftSnapshot(tags: ["fantasy"], fields: [.name: "Mira"])
        let lit = CardFieldGenerator.buildPrompt(for: .description, style: .literal, draft: draft)
        let cre = CardFieldGenerator.buildPrompt(for: .description, style: .creative, draft: draft)
        let ter = CardFieldGenerator.buildPrompt(for: .description, style: .terse, draft: draft)

        try expectTrue(lit.prompt != cre.prompt)
        try expectTrue(cre.prompt != ter.prompt)
        try expectTrue(lit.prompt != ter.prompt)
    }

    s.test("creative has higher temperature than literal") {
        let draft = CardDraftSnapshot(tags: ["fantasy"], fields: [:])
        let lit = CardFieldGenerator.buildPrompt(for: .description, style: .literal, draft: draft)
        let cre = CardFieldGenerator.buildPrompt(for: .description, style: .creative, draft: draft)
        try expectGreaterThan(cre.temperature, lit.temperature)
    }

    s.test("terse has lower max-tokens than literal/creative") {
        let draft = CardDraftSnapshot(tags: ["fantasy"], fields: [:])
        let lit = CardFieldGenerator.buildPrompt(for: .description, style: .literal, draft: draft)
        let ter = CardFieldGenerator.buildPrompt(for: .description, style: .terse, draft: draft)
        try expectLessThan(ter.maxTokens, lit.maxTokens)
    }

    // MARK: - Field-name + word-count substitution

    s.test("instruction template substitutes {humanName} and {wordCount}") {
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal, draft: .empty
        )
        // The bundled `description` field has humanName containing
        // "description (background, role, current circumstances)" and
        // wordCount 60. Both should show up in the rendered TASK block.
        try expectFalse(r.prompt.contains("{humanName}"), "literal placeholder leaked into prompt")
        try expectFalse(r.prompt.contains("{wordCount}"), "literal placeholder leaked into prompt")
        try expectTrue(r.prompt.contains("description"))
        try expectTrue(r.prompt.contains("60"))
    }

    s.test("different fields produce different per-call instructions") {
        let desc = CardFieldGenerator.buildPrompt(for: .description, style: .literal, draft: .empty)
        let pers = CardFieldGenerator.buildPrompt(for: .personality, style: .literal, draft: .empty)
        // Same exemplar (mira fallback), same system block, same style;
        // only field-specific instruction differs. So prompts diverge
        // only in the TASK section's field name + word-count.
        try expectTrue(desc.prompt != pers.prompt)
    }

    // MARK: - Diagnostic-log surface

    s.test("PromptBuildResult exposes exemplarId for cardgen: log lines") {
        let r = CardFieldGenerator.buildPrompt(
            for: .description, style: .literal,
            draft: CardDraftSnapshot(tags: ["fantasy", "monstergirl"], fields: [:])
        )
        try expectEqual(r.exemplarId, "monstergirl")
    }

    return s
}
