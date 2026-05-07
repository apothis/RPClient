import Foundation

/// Phase 9 §5.4.a — side-call shape for AI-assist field generation.
/// Per `V2_PHASE9_AI_ASSIST_RESEARCH.md` §3.3 (Mode 1 candidate triad)
/// and §10 (Mode 1 transport: free-form prose via /api/v1/generate +
/// thinking pre-fill). The pattern mirrors the existing
/// [`DirectorPicker`](../DirectorPicker.swift) — build a prompt body,
/// route it through `template.assemble` for the active chat template
/// (so Qwen3's empty `<think></think>` pre-fill lands), invoke
/// `KoboldGenerating.generate`, parse the result + apply refusal
/// detection, deliver the candidate.
///
/// This file ships the build/parse split — the network-side
/// orchestration (template assembly, watchdog, kobold invocation) lives
/// in `CardSuggestionsController`. Splitting build/parse keeps the
/// pure-data-flow unit-testable without spinning up a stub
/// `KoboldGenerating`.

public struct CardCandidate: Sendable, Equatable {
    public let style: CardCandidateStyle
    public let text: String
    public let refusal: RefusalDetection
    public let exemplarId: String

    public init(
        style: CardCandidateStyle,
        text: String,
        refusal: RefusalDetection,
        exemplarId: String
    ) {
        self.style = style
        self.text = text
        self.refusal = refusal
        self.exemplarId = exemplarId
    }
}

struct CardGenRequest: Sendable, Equatable {
    let field: CardField
    let style: CardCandidateStyle
    let prompt: String
    let preset: SamplerPreset
    let exemplarId: String
    /// Used by the refusal detector's length-ratio heuristic. Estimated
    /// from the per-field word-count target × ~5 chars/word.
    let expectedLengthChars: Int
}

enum CardGenSideCall {

    /// Translate the per-field × per-style configuration into a
    /// concrete request. Output is byte-stable for byte-stable input
    /// per the `Phase9dPromptBuilderTests` determinism contract.
    static func buildRequest(
        for field: CardField,
        style: CardCandidateStyle,
        draft: CardDraftSnapshot,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) -> CardGenRequest {
        let built = CardFieldGenerator.buildPrompt(
            for: field, style: style, draft: draft, registry: registry
        )
        var preset = SamplerPreset.balanced
        preset.temperature = built.temperature
        preset.maxLength = built.maxTokens

        let wordCount = registry.fields[field.rawValue]?.wordCount ?? 30
        let expectedChars = wordCount * 5

        return CardGenRequest(
            field: field,
            style: style,
            prompt: built.prompt,
            preset: preset,
            exemplarId: built.exemplarId,
            expectedLengthChars: expectedChars
        )
    }

    /// Convert the model's raw output into a parsed candidate. Strips
    /// the `<think>` trace if a thinking-mode model emitted one
    /// despite the empty pre-fill, trims whitespace, and applies the
    /// refusal detector.
    static func parseResponse(
        raw: String,
        request: CardGenRequest
    ) -> CardCandidate {
        let cleaned = Markdown.stripThinking(raw)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let refusal = CardGenRefusalDetector.detect(
            candidate: cleaned,
            expectedLengthChars: request.expectedLengthChars
        )
        return CardCandidate(
            style: request.style,
            text: cleaned,
            refusal: refusal,
            exemplarId: request.exemplarId
        )
    }
}
