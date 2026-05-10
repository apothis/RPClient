import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — refusal detector for AI-assist generation.
/// Source of truth: `V2_PHASE9_AI_ASSIST_RESEARCH.md` §8.3 (regex set
/// across Qwen / Llama / Mistral / generic) + §8.4 (uncensored-model
/// softening).
///
/// Posture per research §8.1: precision-biased — a flagged candidate
/// still shows in the strip with a yellow chip and the author can hit
/// Use anyway. False-positive cost is one extra click; false-negative
/// cost is shipping a refusal into a card field. The asymmetry
/// justifies the bias toward false-positives.
func phase9dRefusalDetectorTests() -> TestSuite {
    let s = TestSuite("Phase9dRefusalDetector")

    // MARK: - True positives — Qwen-style refusals

    s.test("Qwen-style: 'As an AI language model, I cannot' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "As an AI language model, I cannot generate explicit content of this nature.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
        try expectEqual(r.pattern, .qwenStyle)
    }

    s.test("Qwen-style: 'As a language model' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "As a language model, I'm not able to provide that.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    s.test("Qwen-style: 'I cannot help with' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I cannot help with this request.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    // MARK: - True positives — Llama-style refusals

    s.test("Llama-style: 'I cannot fulfill this request' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I cannot fulfill this request as it goes against my guidelines.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
        try expectEqual(r.pattern, .llamaStyle)
    }

    s.test("Llama-style: 'I can't fulfill your request' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I can't fulfill your request to generate that content.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    // MARK: - True positives — Mistral-style refusals

    s.test("Mistral-style: 'I'm uncomfortable' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I'm uncomfortable generating this content; let's try a different approach.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
        try expectEqual(r.pattern, .mistralStyle)
    }

    s.test("Mistral-style: 'I'm not going to' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I'm not going to write that for you.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    // MARK: - True positives — generic apology lead

    s.test("Generic apology: 'I'm sorry, I cannot' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I'm sorry, I cannot generate that kind of content.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    s.test("Generic apology: 'I am unable' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "I am unable to assist with this request.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    // MARK: - True positives — sanitization markers

    s.test("Sanitization marker: '[Content removed]' detected anywhere") {
        let r = CardGenRefusalDetector.detect(
            candidate: "Vexara coiled around the bed. [Content removed] She smiled.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
        try expectEqual(r.pattern, .sanitizationMarker)
    }

    s.test("Sanitization marker: '[Sanitized]' detected") {
        let r = CardGenRefusalDetector.detect(
            candidate: "[Sanitized] — output filtered by the safety layer.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
    }

    // MARK: - True positives — length-ratio heuristic

    s.test("Length-ratio: short output containing 'sorry' is a refusal") {
        // 30 chars vs expected 400 → 7.5%, below the 25% threshold,
        // and contains "sorry" — flagged.
        let r = CardGenRefusalDetector.detect(
            candidate: "Sorry, I can't do that today.",
            expectedLengthChars: 400
        )
        try expectTrue(r.isRefusal)
        try expectEqual(r.pattern, .lengthRatioApology)
    }

    // MARK: - False positives — in-character apologies should NOT trigger

    s.test("False-positive bait: 'I'm sorry, did you say something?' (in-character question)") {
        // Apology word + question shape; not a refusal. Flagged by the
        // generic-apology regex which is precision-biased — but per
        // research §8.1 we accept the false-positive cost. THIS test
        // verifies the BUG: the existing regex would falsely flag this
        // as the leading "I'm sorry" matches. We keep it flagged but
        // note the limitation.
        //
        // *** Documenting the false-positive expectation. ***
        // The test asserts the documented behavior, not ideal behavior;
        // change the test if/when we add context-aware detection.
        let r = CardGenRefusalDetector.detect(
            candidate: "I'm sorry, did you say something? I wasn't paying attention.",
            expectedLengthChars: 80
        )
        // This currently DOES flag — the precision-bias trade-off.
        try expectTrue(r.isRefusal, "documented limitation: in-character 'I'm sorry' is a known false positive")
    }

    s.test("Long output containing 'sorry' mid-paragraph is NOT a refusal") {
        // Length is well above the 25% threshold and the apology word
        // doesn't lead the output → not flagged.
        let candidate = """
            Vexara coiled languidly around the rock. The sun was warm on her
            scales, and she had nowhere to be. \"I'm sorry,\" she said with
            no real apology in her voice, \"but you'll have to wait.\" Her
            tail flicked once. The visitor sat down to wait.
            """
        let r = CardGenRefusalDetector.detect(
            candidate: candidate,
            expectedLengthChars: 400
        )
        try expectFalse(r.isRefusal, "in-character 'sorry' mid-prose should not trigger length-ratio")
    }

    s.test("Normal in-character output is not a refusal") {
        let candidate = """
            Mira tucked the envelope into her satchel and looked the stranger
            over. \"Address?\" she said. The word landed flat between them,
            without curiosity, the way she always greeted clients she hadn't
            decided whether to take seriously yet.
            """
        let r = CardGenRefusalDetector.detect(
            candidate: candidate,
            expectedLengthChars: 400
        )
        try expectFalse(r.isRefusal)
        try expectNil(r.pattern)
    }

    s.test("Empty output is not a refusal — empty has no shape to match") {
        // Truncation / cancellation produces empty output; that's its
        // own UX state, not a refusal. The detector returns false and
        // lets the caller render a different chip.
        let r = CardGenRefusalDetector.detect(
            candidate: "",
            expectedLengthChars: 400
        )
        try expectFalse(r.isRefusal)
    }

    // MARK: - Uncensored-model softening (research §8.4)

    s.test("isLikelyUncensored: 'uncensored' substring matches") {
        try expectTrue(CardGenRefusalDetector.isLikelyUncensored(modelName: "Qwen3.6-35B-Uncensored-HauhauCS-Aggressive-Q4_K_M"))
    }

    s.test("isLikelyUncensored: 'abliterated' substring matches") {
        try expectTrue(CardGenRefusalDetector.isLikelyUncensored(modelName: "llama-3-70b-abliterated-q5"))
    }

    s.test("isLikelyUncensored: 'dolphin' substring matches") {
        try expectTrue(CardGenRefusalDetector.isLikelyUncensored(modelName: "dolphin-2.9-llama3-8b"))
    }

    s.test("isLikelyUncensored: 'noromaid' substring matches") {
        try expectTrue(CardGenRefusalDetector.isLikelyUncensored(modelName: "Noromaid-v0.4-Mixtral-Instruct-8x7b-Zloss"))
    }

    s.test("isLikelyUncensored: case-insensitive") {
        try expectTrue(CardGenRefusalDetector.isLikelyUncensored(modelName: "AIROBOROS-70B"))
    }

    s.test("isLikelyUncensored: vanilla model returns false") {
        try expectFalse(CardGenRefusalDetector.isLikelyUncensored(modelName: "Llama-3-70B-Instruct-Q4_K_M"))
    }

    s.test("isLikelyUncensored: empty string returns false (graceful)") {
        try expectFalse(CardGenRefusalDetector.isLikelyUncensored(modelName: ""))
    }

    return s
}
