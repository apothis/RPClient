import Foundation

struct QwenTemplate: PromptTemplate {
    var id: String { "qwen" }
    var name: String { "Qwen 3" }
    var stopSequences: [String] { ["<|im_end|>", "<|im_start|>user"] }

    /// When false (default), every assistant turn opens with an empty
    /// `<think></think>` pre-fill — Qwen3's non-thinking-mode pattern, which
    /// suppresses the reasoning trace. When true, the pre-fill is omitted so
    /// the model produces its own `<think>…</think>` block before the reply.
    /// Stripping the trace from the persisted text is the streamer's job
    /// (see `ThinkBlockFilter`); the template only chooses the prefix shape.
    var thinkingEnabled: Bool = false

    private var assistantHeader: String {
        thinkingEnabled
            ? "<|im_start|>assistant\n"
            : "<|im_start|>assistant\n<think>\n\n</think>\n\n"
    }

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
        var systemParts: [String] = []
        if let m = memoryBlock, !m.isEmpty { systemParts.append(m) }
        if !worldInfoHits.isEmpty { systemParts.append(worldInfoHits.joined(separator: "\n\n")) }
        if !sceneSummaries.isEmpty {
            systemParts.append(PromptBuilder.SceneSummaryFormatter.renderBlock(sceneSummaries))
        }
        if let s = summary, !s.isEmpty { systemParts.append(s) }

        var out = ""
        if !systemParts.isEmpty {
            out += "<|im_start|>system\n"
            out += systemParts.joined(separator: "\n\n")
            out += "<|im_end|>\n"
        }

        let anText: String? = {
            guard let n = authorsNote, !n.text.isEmpty else { return nil }
            return n.text
        }()
        let anDepth = authorsNote?.depth ?? 0
        let lastUserIndex: Int? = {
            for i in stride(from: turns.count - 1, through: 0, by: -1) where turns[i].role == .user {
                return i
            }
            return nil
        }()

        let lastIdx = turns.count - 1
        for (idx, turn) in turns.enumerated() {
            let isContinuationTail = continuation && idx == lastIdx && turn.role == .assistant
            switch turn.role {
            case .user:
                out += "<|im_start|>user\n"
                var body = turn.text
                // See GemmaTemplate for the rationale on this ordering — the
                // user's actual ask lands after the reference blocks so it's
                // the freshest signal before the assistant scaffolding.
                if idx == lastUserIndex, let rm = relevantMemories, !rm.isEmpty {
                    body = rm + "\n\n" + body
                }
                if idx == lastUserIndex, let eb = entitiesBlock, !eb.isEmpty {
                    body = eb + "\n\n" + body
                }
                if idx == lastUserIndex, let digest = tailMemoryDigest, !digest.isEmpty {
                    body = body + "\n\n" + digest
                }
                if let an = anText {
                    let turnsFromEnd = turns.count - 1 - idx
                    if turnsFromEnd == anDepth {
                        body = body + "\n\n" + an
                    }
                }
                // Anchor goes last on the final user turn — see MEMORY_AUDIT §4.1-C.
                if idx == lastUserIndex, let anchor = currentSceneAnchor, !anchor.isEmpty {
                    body = body + "\n\n" + anchor
                }
                out += body
                out += "<|im_end|>\n"
            case .assistant:
                out += assistantHeader
                out += turn.text
                if !isContinuationTail {
                    out += "<|im_end|>\n"
                }
            }
        }
        if !continuation {
            out += assistantHeader
        }
        return out
    }
}
