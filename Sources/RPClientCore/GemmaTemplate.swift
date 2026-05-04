import Foundation

struct GemmaTemplate: PromptTemplate {
    var id: String { "gemma" }
    var name: String { "Gemma" }
    var stopSequences: [String] { ["<end_of_turn>", "<start_of_turn>"] }

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
        var preamble: [String] = []
        if let m = memoryBlock, !m.isEmpty { preamble.append(m) }
        if !worldInfoHits.isEmpty { preamble.append(worldInfoHits.joined(separator: "\n\n")) }
        if !sceneSummaries.isEmpty {
            preamble.append(PromptBuilder.SceneSummaryFormatter.renderBlock(sceneSummaries))
        }
        if let s = summary, !s.isEmpty { preamble.append(s) }
        let preambleText = preamble.joined(separator: "\n\n")

        let anText: String? = {
            guard let n = authorsNote, !n.text.isEmpty else { return nil }
            return n.text
        }()
        let anDepth = authorsNote?.depth ?? 0

        var out = ""
        let userTurns = turns.enumerated().filter { $0.element.role == .user }
        let firstUserIndex = userTurns.first?.offset
        // Index of the *last* user turn — where retrieval results land
        // (kept as close to the assistant generation marker as possible to
        // minimize prompt-cache invalidation; see MEMORY_RESEARCH.md §9.10).
        let lastUserIndex = userTurns.last?.offset

        let lastIdx = turns.count - 1
        for (idx, turn) in turns.enumerated() {
            let isContinuationTail = continuation && idx == lastIdx && turn.role == .assistant
            switch turn.role {
            case .user:
                out += "<start_of_turn>user\n"
                var body = turn.text
                // Retrieval and entities sit BEFORE the user's actual message
                // so the model's last impression on this turn is the user's
                // real ask, not dialog-shaped reference snippets that it
                // would otherwise try to continue from. Preamble (memory,
                // scenes, summary) lands above retrieval on the first user
                // turn for the same reason — frame, then ask.
                if idx == lastUserIndex, let rm = relevantMemories, !rm.isEmpty {
                    body = rm + "\n\n" + body
                }
                if idx == lastUserIndex, let eb = entitiesBlock, !eb.isEmpty {
                    body = eb + "\n\n" + body
                }
                if idx == firstUserIndex, !preambleText.isEmpty {
                    body = preambleText + "\n\n" + body
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
                // Anchor goes last on the final user turn — closest possible
                // position to the assistant generation marker so the "now"
                // signal beats out the vivid prose density of stale scene
                // summaries higher in the prompt. See MEMORY_AUDIT §4.1-C.
                if idx == lastUserIndex, let anchor = currentSceneAnchor, !anchor.isEmpty {
                    body = body + "\n\n" + anchor
                }
                out += body
                out += "<end_of_turn>\n"
            case .assistant:
                out += "<start_of_turn>model\n"
                out += turn.text
                if !isContinuationTail {
                    out += "<end_of_turn>\n"
                }
            }
        }
        // In continuation mode the final assistant turn is left open so the
        // model resumes mid-reply instead of starting a new one.
        if !continuation {
            out += "<start_of_turn>model\n"
        }
        return out
    }
}
