import Foundation

struct SummaryResult {
    let summary: String
    let summarizedThrough: Int
}

enum SummarizerError: Error {
    case nothingToSummarize
    case generationFailed(Error)
}

enum Summarizer {
    private static let summarizeInstruction = """
    Summarize the following roleplay exchange into a concise paragraph preserving names, \
    decisions, locations, items, and relationship state. Keep it factual. \
    Output only the summary, no preamble.
    """

    private static let mergeInstruction = """
    Combine these two summaries into one cohesive summary, deduplicating overlapping facts \
    and keeping the latest state. Output only the merged summary, no preamble.
    """

    /// Summarize the oldest unsummarized turns up to roughly 25% of the effective ctx,
    /// merging with any existing summary. Calls `kobold.generate` once or twice.
    static func run(
        chat: Chat,
        kobold: KoboldClient,
        effectiveCtx: Int,
        completion: @escaping (Result<SummaryResult, Error>) -> Void
    ) {
        let target = max(256, Int(Double(effectiveCtx) * 0.25))
        let startIdx = chat.summarizedThrough
        guard startIdx < chat.turns.count else {
            completion(.failure(SummarizerError.nothingToSummarize)); return
        }

        // Count tokens for each candidate turn so we can pick the right slice.
        let counter = TokenCounter.shared
        let group = DispatchGroup()
        var counts: [Int: Int] = [:]
        let lock = NSLock()
        for i in startIdx..<chat.turns.count {
            group.enter()
            counter.count(chat.turns[i].text, kobold: kobold) { n in
                lock.lock(); counts[i] = n; lock.unlock()
                group.leave()
            }
        }
        group.notify(queue: .main) {
            // Walk forward filling the target. Always leave at least 4 trailing turns
            // for the user to see verbatim history.
            var endIdx = startIdx
            var acc = 0
            for i in startIdx..<chat.turns.count {
                let next = acc + (counts[i] ?? 0)
                if next > target && endIdx > startIdx { break }
                acc = next
                endIdx = i + 1
            }
            let trailingFloor = max(startIdx, chat.turns.count - 4)
            if endIdx > trailingFloor { endIdx = trailingFloor }
            guard endIdx > startIdx else {
                completion(.failure(SummarizerError.nothingToSummarize)); return
            }

            let body = (startIdx..<endIdx).map { i -> String in
                let t = chat.turns[i]
                let role = t.role == .user ? "User" : "Assistant"
                return "\(role): \(t.text)"
            }.joined(separator: "\n\n")

            generateText(
                instruction: summarizeInstruction,
                body: body,
                chat: chat,
                kobold: kobold,
                effectiveCtx: effectiveCtx
            ) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let firstSummary):
                    let trimmed = firstSummary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if chat.summary.isEmpty {
                        completion(.success(SummaryResult(
                            summary: trimmed, summarizedThrough: endIdx)))
                    } else {
                        let mergeBody = """
                        Existing summary:
                        \(chat.summary)

                        New summary:
                        \(trimmed)
                        """
                        generateText(
                            instruction: mergeInstruction,
                            body: mergeBody,
                            chat: chat,
                            kobold: kobold,
                            effectiveCtx: effectiveCtx
                        ) { merged in
                            switch merged {
                            case .failure(let e):
                                completion(.failure(e))
                            case .success(let m):
                                let mt = m.trimmingCharacters(in: .whitespacesAndNewlines)
                                completion(.success(SummaryResult(
                                    summary: mt, summarizedThrough: endIdx)))
                            }
                        }
                    }
                }
            }
        }
    }

    private static func generateText(
        instruction: String,
        body: String,
        chat: Chat,
        kobold: KoboldClient,
        effectiveCtx: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        let template = Templates.byId(chat.templateId)
        let combined = instruction + "\n\n" + body
        let promptTurns = [Turn(role: .user, text: combined)]
        let prompt = template.assemble(
            memoryBlock: nil, summary: nil, worldInfoHits: [],
            authorsNote: nil, turns: promptTurns
        )

        var preset = SamplerPreset.balanced
        // Cap output to keep side-calls fast even on slow (~2 tok/s) thinking models.
        // 350 tok at 2 tok/s ≈ 3 min worst case; below that it's reasonable.
        preset.maxLength = min(350, max(200, chat.summaryTokenCap))
        preset.temperature = 0.4
        preset.topP = 0.9

        DebugLog.shared.write("summarizer: starting side-call (instruction=\(instruction.prefix(40))…, body=\(body.count)c, max_length=\(preset.maxLength))")
        let started = Date()
        kobold.generate(
            prompt: prompt,
            stopSequences: template.stopSequences,
            preset: preset,
            maxContextLength: effectiveCtx
        ) { result in
            let dt = Date().timeIntervalSince(started)
            switch result {
            case .failure(let e):
                DebugLog.shared.write("summarizer: generation FAILED after \(String(format: "%.1fs", dt)) — \(e)")
                completion(.failure(SummarizerError.generationFailed(e)))
            case .success(let text):
                let cleaned = Markdown.stripThinking(text)
                DebugLog.shared.write("""
                    summarizer: generation finished in \(String(format: "%.1fs", dt))
                      raw      (\(text.count)c): \(escapeForLog(text.prefix(400)))
                      stripped (\(cleaned.count)c): \(escapeForLog(cleaned.prefix(400)))
                    """)
                completion(.success(cleaned))
            }
        }
    }

    private static func escapeForLog<S: StringProtocol>(_ s: S) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
    }
}
