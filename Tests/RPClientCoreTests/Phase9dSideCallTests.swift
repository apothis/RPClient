import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — `CardGenSideCall.buildRequest(...)` /
/// `parseResponse(...)` build/parse split. The network-orchestration
/// piece (template assembly, watchdog, kobold invocation) lives in
/// `CardSuggestionsController`; this slice tests the pure-data
/// transformations.
func phase9dSideCallTests() -> TestSuite {
    let s = TestSuite("Phase9dSideCall")

    let draft = CardDraftSnapshot(
        tags: ["fantasy", "monstergirl", "nsfw"],
        fields: [.name: "Vexara"]
    )

    // MARK: - buildRequest — sampler params

    s.test("buildRequest copies temperature from the candidate style") {
        let lit = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let cre = CardGenSideCall.buildRequest(for: .description, style: .creative, draft: draft)
        try expectGreaterThan(cre.preset.temperature, lit.preset.temperature)
    }

    s.test("buildRequest copies maxLength from the candidate style") {
        let lit = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let ter = CardGenSideCall.buildRequest(for: .description, style: .terse, draft: draft)
        try expectLessThan(ter.preset.maxLength, lit.preset.maxLength)
    }

    s.test("buildRequest preserves SamplerPreset.balanced's other knobs") {
        let r = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        // Top-p / top-k / rep-pen come from the balanced preset; only
        // temperature + maxLength get overridden per the candidate
        // style. This guards against accidentally constructing a fresh
        // preset with default values.
        try expectEqual(r.preset.topP, SamplerPreset.balanced.topP)
        try expectEqual(r.preset.topK, SamplerPreset.balanced.topK)
        try expectEqual(r.preset.repPen, SamplerPreset.balanced.repPen)
    }

    // MARK: - buildRequest — exemplar attribution

    s.test("buildRequest carries the exemplarId for diagnostic logging") {
        let r = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        try expectEqual(r.exemplarId, "monstergirl")
    }

    // MARK: - buildRequest — length expectation

    s.test("expectedLengthChars scales with the field's word-count target") {
        // description targets ~60 words (per CardGenPrompts.json),
        // intimacy_scent targets ~20 words. The longer-target field
        // should have a higher expectedLengthChars.
        let desc = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let scent = CardGenSideCall.buildRequest(for: .intimacyScent, style: .literal, draft: draft)
        try expectGreaterThan(desc.expectedLengthChars, scent.expectedLengthChars)
    }

    s.test("expectedLengthChars is non-zero for every CardField") {
        for field in CardField.allCases {
            let r = CardGenSideCall.buildRequest(for: field, style: .literal, draft: draft)
            try expectGreaterThan(r.expectedLengthChars, 0)
        }
    }

    // MARK: - parseResponse — clean output

    s.test("parseResponse strips a thinking trace from the raw output") {
        let raw = "<think>\nLet me think about this carefully.\n</think>\n\nVexara is a four-hundred-fifty-year-old Lamia matriarch."
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectFalse(candidate.text.contains("<think>"))
        try expectFalse(candidate.text.contains("Let me think"))
        try expectTrue(candidate.text.contains("Vexara"))
    }

    s.test("parseResponse trims surrounding whitespace") {
        let raw = "\n\n   Vexara is a Lamia matriarch.   \n\n"
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectEqual(candidate.text, "Vexara is a Lamia matriarch.")
    }

    // MARK: - parseResponse — refusal attribution

    s.test("parseResponse flags a Llama-style refusal") {
        let raw = "I cannot fulfill this request as it goes against my guidelines."
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectTrue(candidate.refusal.isRefusal)
        try expectEqual(candidate.refusal.pattern, .llamaStyle)
    }

    s.test("parseResponse flags a Qwen-style refusal") {
        let raw = "As an AI language model, I cannot generate explicit content."
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectTrue(candidate.refusal.isRefusal)
        try expectEqual(candidate.refusal.pattern, .qwenStyle)
    }

    s.test("parseResponse does NOT flag in-character prose") {
        let raw = """
            Vexara coiled languidly in the firelight. Her tail flicked once,
            and she watched the traveler's hands carefully — not their face,
            their hands. Travelers lied with their faces all the time. With
            their hands they were always honest.
            """
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectFalse(candidate.refusal.isRefusal)
    }

    s.test("parseResponse on truly empty output returns empty + non-refusal") {
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let candidate = CardGenSideCall.parseResponse(raw: "", request: req)
        try expectEqual(candidate.text, "")
        try expectFalse(candidate.refusal.isRefusal)
    }

    // MARK: - End-to-end attribution

    s.test("parsed candidate's style matches the request") {
        let raw = "Some text."
        let req = CardGenSideCall.buildRequest(for: .description, style: .creative, draft: draft)
        let c = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectEqual(c.style, .creative)
    }

    s.test("parsed candidate carries the exemplarId from the request") {
        let raw = "Some text."
        let req = CardGenSideCall.buildRequest(for: .description, style: .literal, draft: draft)
        let c = CardGenSideCall.parseResponse(raw: raw, request: req)
        try expectEqual(c.exemplarId, "monstergirl")
    }

    return s
}
