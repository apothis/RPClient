import Foundation

/// Token-count cache keyed on text hash. Avoids re-tokenizing unchanged content.
final class TokenCounter {
    static let shared = TokenCounter()
    private var cache: [Int: Int] = [:]
    private let lock = NSLock()

    func count(_ text: String, kobold: KoboldClient, completion: @escaping (Int) -> Void) {
        if text.isEmpty { completion(0); return }
        let key = text.hashValue
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            completion(cached)
            return
        }
        lock.unlock()
        kobold.tokenCount(text: text) { [weak self] result in
            let n = (try? result.get()) ?? 0
            self?.lock.lock()
            self?.cache[key] = n
            self?.lock.unlock()
            completion(n)
        }
    }
}

struct BudgetUsage: Equatable {
    var memory: Int
    var summary: Int
    var authorsNote: Int
    var worldInfo: Int
    var retrieval: Int
    var turnsTotal: Int
    var templateOverhead: Int
    var replyReserve: Int
    var ctx: Int

    var prompt: Int { memory + summary + authorsNote + worldInfo + retrieval + turnsTotal + templateOverhead }
    var used: Int { prompt + replyReserve }
    var fillRatio: Double { ctx > 0 ? min(1.0, Double(used) / Double(ctx)) : 0 }
    var promptRatio: Double { ctx > 0 ? min(1.0, Double(prompt) / Double(ctx)) : 0 }

    static let zero = BudgetUsage(
        memory: 0, summary: 0, authorsNote: 0, worldInfo: 0, retrieval: 0,
        turnsTotal: 0, templateOverhead: 0, replyReserve: 0, ctx: 0
    )
}

struct PromptAssembly {
    let prompt: String
    let stops: [String]
    let usage: BudgetUsage
    /// Number of leading turns dropped to fit the budget.
    let truncatedTurns: Int
}

enum TokenBudget {
    /// Per-turn template overhead estimate (start/end markers).
    private static let perTurnOverhead = 6
    /// Fixed template overhead (system prefix etc.).
    private static let fixedOverhead = 8

    static func assemble(
        chat: Chat,
        effectiveCtx: Int,
        replyReserve: Int,
        character: Character? = nil,
        persona: Persona? = nil,
        relevantMemories: String? = nil,
        continuation: Bool = false,
        userName: String = "",
        qwenThinking: Bool = false,
        speakerId: UUID? = nil,
        cast: [Character] = [],
        overrides: ChatPathOverrides = ChatPathOverrides(),
        systemPromptAddendum: String = "",
        kobold: KoboldClient,
        completion: @escaping (PromptAssembly) -> Void
    ) {
        // Phase 8 §4.2c — multi-cast assembly inputs. Triggered when the
        // chat has more than one cast member AND a speakerId was resolved
        // by the caller (AppState picks via SpeakerPicker before the
        // assistant turn is appended). `character` is still the active
        // speaker's full card; `cast` provides the rest for cohabitant
        // briefs + name-prefix history. Solo / free-form chats pass
        // through unchanged.
        let isMultiCast = chat.cast.count > 1 && speakerId != nil
        let cohabitants: [Character] = isMultiCast ? cast.filter { $0.id != speakerId } : []
        let activeSpeakerName: String? = {
            guard isMultiCast, let sid = speakerId else { return nil }
            return cast.first(where: { $0.id == sid })?.name ?? character?.name
        }()
        // Phase 10 §10.c — per-EXACT-model `groupNudgeStyle` override.
        // Same X→X detection as `PromptBuilder.build`; centralised here
        // for the production path so `TokenBudget.assemble` doesn't
        // diverge from the test path.
        let nudgeStyle = overrides.groupNudgeStyle ?? .standard
        let xToX: Bool = {
            guard isMultiCast, let sid = speakerId else { return false }
            return chat.turns.reversed().first(where: { $0.role == .assistant })?.speakerId == sid
        }()
        let nudge: String? = activeSpeakerName.map {
            PromptBuilder.groupNudge(activeSpeakerName: $0, style: nudgeStyle, xToX: xToX)
        }

        // Memory block composition (system_prompt + userName line + card
        // biographical prefix + chat.memory) lives in
        // `PromptBuilder.composeMemoryBlock` so the test path and production
        // path see the same shape. Lives above the cache boundary — these
        // pieces change rarely so the prefill prefix stays reusable.
        let effectiveMemory: String = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: character,
            userName: userName,
            cohabitants: cohabitants,
            systemPromptAddendum: systemPromptAddendum
        ) ?? ""
        // User-side persona block (4f). Per-template placement: Gemma folds
        // it into the first user turn, Qwen into the system block.
        let personaBlock = PromptBuilder.renderPersonaBlock(persona)
        let group = DispatchGroup()
        let counter = TokenCounter.shared

        var memTok = 0, sumTok = 0, sceneTok = 0, anTok = 0, wiTok = 0, retrTok = 0, digestTok = 0
        var entitiesTok = 0, anchorTok = 0, personaTok = 0
        var turnTok: [UUID: Int] = [:]
        let lock = NSLock()

        let tailDigest = PromptBuilder.tailMemoryDigest(chat: chat, continuation: continuation)
        let entitiesBlock = PromptBuilder.entitiesBlock(chat: chat)
        let anchor = PromptBuilder.currentSceneAnchor(chat: chat, continuation: continuation)

        if !effectiveMemory.isEmpty {
            group.enter()
            counter.count(effectiveMemory, kobold: kobold) { n in memTok = n; group.leave() }
        }
        if let pb = personaBlock, !pb.isEmpty {
            group.enter()
            counter.count(pb, kobold: kobold) { n in personaTok = n; group.leave() }
        }
        if let eb = entitiesBlock, !eb.isEmpty {
            group.enter()
            counter.count(eb, kobold: kobold) { n in entitiesTok = n; group.leave() }
        }
        if let d = tailDigest, !d.isEmpty {
            group.enter()
            counter.count(d, kobold: kobold) { n in digestTok = n; group.leave() }
        }
        if let a = anchor, !a.isEmpty {
            group.enter()
            counter.count(a, kobold: kobold) { n in anchorTok = n; group.leave() }
        }
        if !chat.summary.isEmpty {
            group.enter()
            counter.count(chat.summary, kobold: kobold) { n in sumTok = n; group.leave() }
        }
        // Count the rendered scene block as a single chunk — this matches what
        // actually gets injected and accounts for new framing + staleness
        // compression so token math doesn't double-count what the model sees.
        let renderedScenes = PromptBuilder.renderableScenes(chat: chat, speakerId: speakerId)
        let sceneText: String = renderedScenes.isEmpty
            ? ""
            : PromptBuilder.SceneSummaryFormatter.renderBlock(renderedScenes)
        if !sceneText.isEmpty {
            group.enter()
            counter.count(sceneText, kobold: kobold) { n in sceneTok = n; group.leave() }
        }
        // Falls back to character.postHistoryInstructions when the user
        // hasn't typed an author's note. See PromptBuilder.effectiveAuthorsNote.
        // userName is forwarded so {{char}} / {{user}} substitution can run
        // on the PHI fallback path (the user-typed authorsNote text is NOT
        // substituted — it's expected to be literal).
        let effectiveAN = PromptBuilder.effectiveAuthorsNote(chat: chat, character: character, userName: userName)
        if let an = effectiveAN, !an.text.isEmpty {
            group.enter()
            counter.count(an.text, kobold: kobold) { n in anTok = n; group.leave() }
        }
        // Count only what the prompt-builder actually injects (selective hits,
        // each truncated to the entry's tokenCap). Counting the full union
        // of entry bodies would over-report — the model only ever sees the
        // matched subset.
        let wiHits = PromptBuilder.worldInfoHits(chat: chat)
        let wiText = wiHits.joined(separator: "\n\n")
        if !wiText.isEmpty {
            group.enter()
            counter.count(wiText, kobold: kobold) { n in wiTok = n; group.leave() }
        }
        if let rm = relevantMemories, !rm.isEmpty {
            group.enter()
            counter.count(rm, kobold: kobold) { n in retrTok = n; group.leave() }
        }
        let verbatim: [Turn] = {
            let raw = PromptBuilder.verbatimTurns(chat)
            // Phase 8 §4.2c — name-prefix + reasoning-strip history when
            // multi-cast. Solo path returns raw turns unchanged. Done
            // before token-counting so the per-turn token estimates
            // include the inflation from `Sarah: ` prefixes.
            let formatted: [Turn]
            if isMultiCast, let sid = speakerId {
                formatted = PromptBuilder.formatHistoryForSpeaker(turns: raw, activeSpeakerId: sid, cast: cast)
            } else {
                formatted = raw
            }
            // {{char}} / {{user}} substitution on every turn's text —
            // covers existing chats whose seeded greeting was persisted
            // with raw placeholders (Emily "Mia" hallucination
            // regression). Token counting below sees the substituted
            // form so the budget is accurate.
            let charName = character?.name ?? ""
            return formatted.map { t in
                var copy = t
                copy.text = PlaceholderSubstitution.apply(
                    t.text, characterName: charName, userName: userName
                )
                return copy
            }
        }()
        for turn in verbatim where !turn.text.isEmpty {
            group.enter()
            counter.count(turn.text, kobold: kobold) { n in
                lock.lock(); turnTok[turn.id] = n; lock.unlock()
                group.leave()
            }
        }

        group.notify(queue: .main) {
            var turns = verbatim
            func tokens(of turn: Turn) -> Int {
                (turnTok[turn.id] ?? 0) + perTurnOverhead
            }
            var turnsTotal = turns.reduce(0) { $0 + tokens(of: $1) }

            let nonTurns = memTok + entitiesTok + sumTok + sceneTok + anTok + wiTok + retrTok + digestTok + anchorTok + personaTok + fixedOverhead
            // Drop oldest pair (user + assistant) while exceeding budget. Always keep
            // the trailing pending pair so the user's just-sent message survives.
            while nonTurns + turnsTotal + replyReserve > effectiveCtx, turns.count > 2 {
                let dropped = turns.removeFirst()
                turnsTotal -= tokens(of: dropped)
            }

            let truncatedCount = verbatim.count - turns.count

            let template = Templates.byId(chat.templateId, qwenThinking: qwenThinking)
            let prompt = template.assemble(
                memoryBlock: effectiveMemory.isEmpty ? nil : effectiveMemory,
                personaBlock: personaBlock,
                entitiesBlock: entitiesBlock,
                sceneSummaries: renderedScenes,
                summary: chat.summary.isEmpty ? nil : chat.summary,
                worldInfoHits: wiHits,
                authorsNote: effectiveAN,
                relevantMemories: relevantMemories,
                tailMemoryDigest: tailDigest,
                currentSceneAnchor: anchor,
                groupNudge: nudge,
                turns: turns,
                continuation: continuation
            )

            let usage = BudgetUsage(
                memory: memTok + digestTok + entitiesTok + personaTok,
                summary: sumTok + sceneTok,
                authorsNote: anTok,
                worldInfo: wiTok,
                retrieval: retrTok,
                turnsTotal: turnsTotal,
                templateOverhead: fixedOverhead,
                replyReserve: replyReserve,
                ctx: effectiveCtx
            )

            // Phase 10 §10.c — augment template stops with per-model
            // overrides. `stopSequenceAugmentation` is appended verbatim
            // (caller / Settings UI sets these explicitly); the
            // .stopAugment / .strongStop nudge styles auto-add per-
            // cohabitant role-prefix stops on top.
            var stops = template.stopSequences
            stops += overrides.stopSequenceAugmentation ?? []
            if isMultiCast && (nudgeStyle == .stopAugment || nudgeStyle == .strongStop) {
                for c in cohabitants {
                    stops.append("\n\(c.name):")
                    stops.append("\(c.name):")
                }
            }
            completion(PromptAssembly(
                prompt: prompt,
                stops: stops,
                usage: usage,
                truncatedTurns: truncatedCount
            ))
        }
    }
}
