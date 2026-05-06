import Foundation

/// Phase 8 §4.4 — async LLM-router speaker picker for `.director` mode.
/// Asks a small/fast model "given this conversation tail, who should
/// speak next?" and returns the matched cast member's id (nil on any
/// failure so the caller can fall back to the sync `SpeakerPicker`).
///
/// The synchronous `SpeakerPicker.next(in:)` returns nil for `.director`
/// because it can't make the side-call. AppState's send path detects
/// `.director` and calls this async picker before stamping the assistant
/// turn's `speakerId`. Network / parse failures degrade silently to
/// round-robin so the user's send isn't blocked by a flaky router.
///
/// The router defaults to the summarizer-role server (Settings'
/// summarizerServerId / .summarizerModelId), since that's already the
/// "small fast model" lane in the user's setup. Caller passes the
/// resolved client; this type doesn't reach into AppState so it stays
/// testable with a stub.
enum DirectorPicker {
    /// Tail-of-history budget for the router prompt. Six turns covers
    /// roughly the last user turn + a couple of speakers' replies — enough
    /// for the model to see who's been talking and what they were on
    /// about, without burning a long-context side-call on every send.
    private static let tailTurns = 6

    /// Hard cap on the response token count. Tight: the response is one
    /// name. Generous overhead for models that wrap the name in a short
    /// sentence ("I think Sarah should reply"). 64 is enough for verbose
    /// templates without burning budget on essays.
    private static let maxLengthTokens = 64

    /// Hard cap on side-call wall time. Falls back to round-robin past
    /// this — the router's whole job is to be invisible. Five seconds is
    /// a generous budget for a small model on the user's typical hardware
    /// (Qwen3 2B at 30+ tok/s clears a one-name reply in <1s); slow
    /// models hit the cap and the user's send doesn't stall.
    private static let timeoutSeconds: TimeInterval = 5.0

    /// Ask the LLM to pick the next speaker. Completion runs on the
    /// kobold client's callback queue — caller is responsible for
    /// dispatching back to main if it needs to mutate UI state.
    ///
    /// `cast` is the resolved `[Character]` for `chat.cast` — the picker
    /// needs name + id; AppState.assembleAndStream resolves the same
    /// list for the prompt-assembly path.
    static func next(
        chat: Chat,
        cast: [Character],
        kobold: KoboldGenerating,
        effectiveCtx: Int,
        completion: @escaping (UUID?) -> Void
    ) {
        guard !cast.isEmpty else { completion(nil); return }

        // Phase 8 §4.4 fix — wrap the director prompt in the template
        // scaffold so Qwen3's empty `<think></think>` pre-fill suppresses
        // the thinking trace. Sending the raw instruction string straight
        // to `kobold.generate` lets the model burn the whole maxLength
        // budget inside an unsolicited `<think>` block before ever
        // producing a name. Same pattern as Summarizer.generateText —
        // single user turn through `template.assemble`, which inserts
        // the assistant scaffold + thinking pre-fill at the end.
        let template = Templates.byId(chat.templateId)
        let body = buildPromptBody(chat: chat, cast: cast)
        let promptTurns = [Turn(role: .user, text: body)]
        let prompt = template.assemble(
            memoryBlock: nil, summary: nil, worldInfoHits: [],
            authorsNote: nil, turns: promptTurns
        )
        var preset = SamplerPreset.balanced
        preset.maxLength = maxLengthTokens
        preset.temperature = 0.3
        preset.topP = 0.9

        DebugLog.shared.write("director: starting side-call (cast=\(cast.count), tail=\(min(tailTurns, chat.activeTurns.count)))")
        let started = Date()

        // Timeout watchdog — if generate doesn't fire its completion
        // within `timeoutSeconds`, return nil so the caller doesn't
        // block forever on a stuck side-call. Use an atomic-ish flag so
        // a late completion + the watchdog don't double-fire.
        let lock = NSLock()
        var fired = false
        func deliver(_ id: UUID?, reason: String) {
            lock.lock()
            let alreadyFired = fired
            fired = true
            lock.unlock()
            if alreadyFired { return }
            let dt = Date().timeIntervalSince(started)
            DebugLog.shared.write("director: \(reason) in \(String(format: "%.1fs", dt)) → \(id?.uuidString ?? "nil (fallback)")")
            completion(id)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds) {
            deliver(nil, reason: "timeout")
        }

        kobold.generate(
            prompt: prompt,
            stopSequences: template.stopSequences,
            preset: preset,
            maxContextLength: effectiveCtx
        ) { result in
            switch result {
            case .failure(let e):
                DebugLog.shared.write("director: generate FAILED — \(e)")
                deliver(nil, reason: "error")
            case .success(let raw):
                let cleaned = Markdown.stripThinking(raw)
                if let pick = parsePick(response: cleaned, cast: cast) {
                    deliver(pick, reason: "ok")
                } else {
                    DebugLog.shared.write("director: no cast match in response: \(cleaned.prefix(80))")
                    deliver(nil, reason: "unparseable")
                }
            }
        }
    }

    /// Parse a raw LLM response into a cast-member id. Strategy: trim,
    /// lowercase, then for each cast member look for their lowercased
    /// name as a word-bounded substring. If multiple match (e.g.
    /// "Anna asked Sarah to speak"), the **later** position wins — that
    /// reads as "X asked Y to speak", and Y is the actual pick.
    /// Returns nil when nothing matches.
    static func parsePick(response: String, cast: [Character]) -> UUID? {
        let lower = response.lowercased()
        var best: (range: Range<String.Index>, id: UUID)?
        for member in cast {
            let name = member.name.lowercased()
            guard !name.isEmpty else { continue }
            // Find the LAST occurrence — `range(of:options:.backwards)`
            // walks from the end, returning the rightmost match.
            if let r = lower.range(of: name, options: .backwards) {
                if best == nil || r.lowerBound > best!.range.lowerBound {
                    best = (r, member.id)
                }
            }
        }
        return best?.id
    }

    /// Compose the router prompt body. Wrapped in a single user turn by
    /// `next(...)` and routed through `template.assemble` so the chat
    /// template's assistant scaffold (Qwen3 empty `<think></think>`
    /// pre-fill, etc) lands at the end. Format mirrors SillyTavern's
    /// group-nudge shape — short instruction + recent dialogue + cast
    /// list — kept minimal so the model's response is short and
    /// parseable. The output instruction asks for one name only; in
    /// practice models elaborate, which is why `parsePick` does
    /// substring matching rather than strict equality.
    static func buildPromptBody(chat: Chat, cast: [Character]) -> String {
        let names = cast.map(\.name).joined(separator: ", ")
        let tail = chat.activeTurns.suffix(tailTurns).map { t -> String in
            let role = t.role == .user ? "User" : (
                t.speakerId.flatMap { sid in cast.first(where: { $0.id == sid })?.name } ?? "Assistant"
            )
            return "\(role): \(t.text)"
        }.joined(separator: "\n\n")

        return """
        You are a director picking the next speaker in a group roleplay.

        The cast: \(names)

        Recent dialogue:
        \(tail)

        Who should speak next? Respond with one name from the cast list above. Just the name, no explanation.
        """
    }
}
