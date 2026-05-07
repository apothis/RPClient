import Foundation

/// Phase 9 §5.4.a — byte-deterministic prompt builder for AI-assist
/// generation. Per `V2_PHASE9_AI_ASSIST_RESEARCH.md` §3.2, every
/// card-gen prompt has the layout:
///
///     [stable system prompt]
///     [stable few-shot exemplar block — selected by tag-overlap]
///     [stable upstream-fields block — only the fields the §4.4
///      dep graph lists as upstream for the target field]
///     [per-call instruction — field name + word-count + candidate-
///      style differentiator]
///
/// Determinism is load-bearing. Same inputs must produce a byte-
/// identical prompt — KoboldCPP's KV cache reuses any prefix that
/// matches the previous generation, and a non-deterministic builder
/// silently invalidates that reuse on every call. Tests guard this.

public enum CardCandidateStyle: String, CaseIterable, Sendable, Codable {
    case literal
    case creative
    case terse
}

/// Frozen snapshot of the draft state at the moment of generation.
/// Keeps the prompt builder pure — the underlying `CharacterDraft`
/// has UI state we don't want leaking into prompt-equality tests.
public struct CardDraftSnapshot: Sendable, Equatable {
    public let tags: [String]
    public let fields: [CardField: String]

    public init(tags: [String], fields: [CardField: String]) {
        self.tags = tags
        self.fields = fields
    }

    /// Convenience for a fresh draft with nothing populated.
    public static let empty = CardDraftSnapshot(tags: [], fields: [:])
}

public struct PromptBuildResult: Sendable, Equatable {
    public let prompt: String
    public let temperature: Double
    public let maxTokens: Int
    public let exemplarId: String
}

public enum CardFieldGenerator {

    public static func buildPrompt(
        for field: CardField,
        style: CardCandidateStyle,
        draft: CardDraftSnapshot,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) -> PromptBuildResult {
        let exemplar = CardGenExemplars.select(forTags: draft.tags)
        let candidate = resolveCandidate(field: field, style: style, registry: registry)
        let fieldPrompt = registry.fields[field.rawValue]
        let humanName = fieldPrompt?.humanName ?? field.rawValue
        let wordCount = fieldPrompt?.wordCount ?? 30

        let systemBlock = registry.systemPrompt
        let exemplarBlock = renderExemplarBlock(exemplar: exemplar)
        let upstreamBlock = renderUpstreamBlock(field: field, draft: draft)
        let instruction = candidate.instruction
            .replacingOccurrences(of: "{humanName}", with: humanName)
            .replacingOccurrences(of: "{wordCount}", with: "\(wordCount)")

        // Joined with double newlines so each block is visually
        // distinct in the model's input. The exact joining is part of
        // the byte-stable contract; the test suite asserts equality on
        // full strings.
        let prompt = [
            "SYSTEM:\n\(systemBlock)",
            "EXAMPLE CHARACTER (anchor format and register):\n\(exemplarBlock)",
            upstreamBlock.isEmpty ? nil : "TARGET CHARACTER (current draft):\n\(upstreamBlock)",
            "TASK:\n\(instruction)",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        return PromptBuildResult(
            prompt: prompt,
            temperature: candidate.temperature,
            maxTokens: candidate.maxTokens,
            exemplarId: exemplar.id
        )
    }

    // MARK: - Internals

    static func resolveCandidate(
        field: CardField,
        style: CardCandidateStyle,
        registry: CardGenPromptsRegistry
    ) -> CandidatePrompt {
        // Per-field override beats the registry default.
        if let override = registry.fields[field.rawValue]?.candidates?[style.rawValue] {
            return override
        }
        // Default must exist — registry parse-time validation ensures it.
        // Fallback to a conservative shape if (somehow) a style is missing.
        return registry.candidateDefaults[style.rawValue]
            ?? CandidatePrompt(temperature: 0.5, maxTokens: 512, instruction: "Write the {humanName}. {wordCount} words.")
    }

    static func renderExemplarBlock(exemplar: CardGenExemplar) -> String {
        // Stable ordering: iterate CardField.allCases so the block is
        // byte-identical for a given exemplar across runs. Skip fields
        // the exemplar doesn't carry (defensive — current archetypes
        // populate every field).
        var lines: [String] = []
        for field in CardField.allCases {
            guard let value = exemplar.fields[field.rawValue], !value.isEmpty else { continue }
            lines.append("  \(field.rawValue): \(escapedSingleLine(value))")
        }
        return lines.joined(separator: "\n")
    }

    static func renderUpstreamBlock(field: CardField, draft: CardDraftSnapshot) -> String {
        // Only fields the dep graph lists as upstream for the target;
        // tags are special-cased.
        let upstreams = CardFieldDependencies.upstreams(for: field)
        var lines: [String] = []

        // Tags first — they carry strong genre signals and the dep
        // graph treats them as universal upstream for narrative
        // fields. Sorted for byte-stability.
        if upstreams.contains(.tags), !draft.tags.isEmpty {
            let sortedTags = draft.tags.map { $0.lowercased() }.sorted()
            lines.append("  tags: \(sortedTags.joined(separator: ", "))")
        }

        // Then field upstreams in CardField.allCases order — also
        // byte-stable. Skip empty values so the model isn't told
        // "personality: " (which it might interpret as 'be empty').
        for caseField in CardField.allCases {
            guard upstreams.contains(.field(caseField)),
                  let value = draft.fields[caseField],
                  !value.isEmpty
            else { continue }
            lines.append("  \(caseField.rawValue): \(escapedSingleLine(value))")
        }

        return lines.joined(separator: "\n")
    }

    /// Collapse newlines + trim so multi-line upstream values render
    /// on one line in the upstream block. The model can still infer
    /// structure from the field name; visual line-by-line parity with
    /// the exemplar block matters more than preserving paragraph
    /// breaks inside individual upstream values.
    private static func escapedSingleLine(_ value: String) -> String {
        let collapsed = value
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
        return collapsed.trimmingCharacters(in: .whitespaces)
    }
}
