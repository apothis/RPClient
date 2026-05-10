import Foundation

/// Side-call that produces a 1–2 sentence "place this snippet in the story"
/// blurb for a single chunk. Following Anthropic's *Contextual Retrieval*
/// recipe — the blurb is glued to the chunk text before embedding so
/// chunks that look textually similar but represent different scenes can
/// be discriminated by their context. We feed the model the layered
/// summaries (pinned memory + scene summaries + rolling summary) as
/// background instead of the whole chat — much cheaper per chunk and
/// already a well-formed compressed view of the story state.
///
/// The output is deliberately short (≤ ~120 tokens) and factual. It
/// describes characters, location/setting, and what's happening in the
/// snippet — orthogonal to the snippet's content, so even small
/// off-the-shelf models produce something useful.
enum ContextBlurber {
    enum BlurberError: Error {
        case generationFailed(Error)
    }

    private static let instruction = """
    You are placing a snippet from a roleplay session into context for retrieval indexing.

    Write 1–2 short, factual sentences describing this snippet's place in the story — who is involved, where they are, and what is happening. Do not summarise the dialogue itself; describe the setting and situation only. Do not editorialise. Output the description and nothing else — no preamble, no quotes, no labels.
    """

    /// Generate a context blurb for a single chunk. Background is assembled
    /// from the layered summaries on the chat at call time.
    static func run(
        chunk: Chunk,
        chat: Chat,
        kobold: KoboldGenerating,
        effectiveCtx: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let background = buildBackground(chat: chat)
        let body: String = {
            var parts: [String] = []
            if !background.isEmpty {
                parts.append("--- BACKGROUND (story so far) ---\n\n\(background)")
            }
            parts.append("--- SNIPPET (turns \(chunk.firstTurnIdx)–\(chunk.lastTurnIdx)) ---\n\n\(chunk.text)")
            return parts.joined(separator: "\n\n")
        }()

        let template = Templates.byId(chat.templateId)
        let combined = instruction + "\n\n" + body
        let prompt = template.assemble(
            memoryBlock: nil, summary: nil, worldInfoHits: [],
            authorsNote: nil, turns: [Turn(role: .user, text: combined)]
        )

        var preset = SamplerPreset.balanced
        // Tight output budget — blurbs that sprawl defeat the point.
        preset.maxLength = 160
        preset.temperature = 0.3
        preset.topP = 0.9

        let started = Date()
        DebugLog.shared.write("contextblurb: chunk=\(chunk.id) bgChars=\(background.count) bodyChars=\(body.count)")
        kobold.generate(
            prompt: prompt,
            stopSequences: template.stopSequences,
            preset: preset,
            maxContextLength: effectiveCtx
        ) { result in
            let dt = Date().timeIntervalSince(started)
            switch result {
            case .failure(let e):
                DebugLog.shared.write("contextblurb: FAILED after \(String(format: "%.1fs", dt)) — \(e)")
                completion(.failure(BlurberError.generationFailed(e)))
            case .success(let text):
                let cleaned = Markdown.stripThinking(text)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                DebugLog.shared.write("contextblurb: ok in \(String(format: "%.1fs", dt)) → \(cleaned.count)c")
                completion(.success(cleaned))
            }
        }
    }

    /// Compose the background context: pinned memory + scene summaries +
    /// rolling summary. Same layered view PromptBuilder uses, joined plain
    /// without the prompt-time framing headers.
    private static func buildBackground(chat: Chat) -> String {
        var parts: [String] = []
        let memory = chat.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memory.isEmpty { parts.append(memory) }
        for (i, scene) in chat.sceneSummaries.enumerated() {
            let body = scene.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            // Phase 7 §3.2 — resolve positions against the current active
            // path. Off-branch scenes (UUID set but doesn't resolve)
            // render without the "turns N–M" suffix rather than being
            // dropped — this is debug context, useful even when stale.
            let header: String
            if let first = scene.firstTurnPosition(in: chat),
               let last = scene.lastTurnPosition(in: chat) {
                header = "Earlier arc \(i + 1) (turns \(first)–\(last)):"
            } else {
                header = "Earlier arc \(i + 1):"
            }
            parts.append("\(header) \(body)")
        }
        let summary = chat.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !summary.isEmpty {
            parts.append("Most recent summary: \(summary)")
        }
        return parts.joined(separator: "\n\n")
    }
}
