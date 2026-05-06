import Foundation

protocol PromptTemplate {
    var id: String { get }
    var name: String { get }
    var stopSequences: [String] { get }
    func assemble(
        memoryBlock: String?,
        personaBlock: String?,
        entitiesBlock: String?,
        sceneSummaries: [SceneSummary],
        summary: String?,
        worldInfoHits: [String],
        authorsNote: AuthorsNote?,
        relevantMemories: String?,
        tailMemoryDigest: String?,
        currentSceneAnchor: String?,
        groupNudge: String?,
        turns: [Turn],
        continuation: Bool
    ) -> String
}

extension PromptTemplate {
    /// Convenience overload — minimal: no entities, scenes, retrieval, AN, or tail digest.
    func assemble(
        memoryBlock: String?,
        summary: String?,
        worldInfoHits: [String],
        authorsNote: AuthorsNote?,
        turns: [Turn]
    ) -> String {
        assemble(
            memoryBlock: memoryBlock,
            personaBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: summary,
            worldInfoHits: worldInfoHits,
            authorsNote: authorsNote,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            groupNudge: nil,
            turns: turns,
            continuation: false
        )
    }

    /// Convenience overload — same signature as the full one minus
    /// `personaBlock` (added in 4f) and `groupNudge` (added in Phase 8
    /// §4.2b). Forwards `nil` so existing tests that don't care about
    /// persona / multi-cast keep working without touching every callsite.
    func assemble(
        memoryBlock: String?,
        entitiesBlock: String?,
        sceneSummaries: [SceneSummary],
        summary: String?,
        worldInfoHits: [String],
        authorsNote: AuthorsNote?,
        relevantMemories: String?,
        tailMemoryDigest: String?,
        currentSceneAnchor: String?,
        turns: [Turn],
        continuation: Bool
    ) -> String {
        assemble(
            memoryBlock: memoryBlock,
            personaBlock: nil,
            entitiesBlock: entitiesBlock,
            sceneSummaries: sceneSummaries,
            summary: summary,
            worldInfoHits: worldInfoHits,
            authorsNote: authorsNote,
            relevantMemories: relevantMemories,
            tailMemoryDigest: tailMemoryDigest,
            currentSceneAnchor: currentSceneAnchor,
            groupNudge: nil,
            turns: turns,
            continuation: continuation
        )
    }

    /// Convenience overload — defaults continuation, entities, scenes, and tail digest empty.
    func assemble(
        memoryBlock: String?,
        summary: String?,
        worldInfoHits: [String],
        authorsNote: AuthorsNote?,
        relevantMemories: String?,
        turns: [Turn]
    ) -> String {
        assemble(
            memoryBlock: memoryBlock,
            personaBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: summary,
            worldInfoHits: worldInfoHits,
            authorsNote: authorsNote,
            relevantMemories: relevantMemories,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            groupNudge: nil,
            turns: turns,
            continuation: false
        )
    }
}

enum Templates {
    static let all: [PromptTemplate] = [GemmaTemplate(), QwenTemplate()]

    /// Default lookup — used by side-call paths (Summarizer, FactExtractor,
    /// ContextBlurber). These don't want Qwen3 reasoning anyway, so the
    /// thinking-off variant is always correct here.
    static func byId(_ id: String) -> PromptTemplate {
        byId(id, qwenThinking: false)
    }

    /// Lookup with a Qwen3 thinking-mode opt-in. Honoured only by
    /// `QwenTemplate`; ignored by other templates. Driven by
    /// `Settings.qwenThinkingEnabled` for the user-facing prompt path.
    static func byId(_ id: String, qwenThinking: Bool) -> PromptTemplate {
        switch id {
        case QwenTemplate().id:
            return QwenTemplate(thinkingEnabled: qwenThinking)
        case GemmaTemplate().id:
            return GemmaTemplate()
        default:
            return GemmaTemplate()
        }
    }

    /// Best-effort guess at the right template for a given model-name string
    /// (e.g. the result of `/api/v1/model`). Lowercased substring match in
    /// rough specificity order — falls back to nil when unrecognised so the
    /// caller can keep its current default. Used by AppState when creating
    /// new chats so the default template tracks whatever model KoboldCpp is
    /// actually serving.
    static func detect(forModelName name: String) -> String? {
        let lower = name.lowercased()
        if lower.contains("qwen") { return QwenTemplate().id }
        if lower.contains("gemma") { return GemmaTemplate().id }
        return nil
    }
}
