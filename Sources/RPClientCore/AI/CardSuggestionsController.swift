import Foundation

/// Phase 9 §5.4.a — strip state machine for the §4.1 Suggestions UI.
/// Wraps `CardGenSideCall` and `KoboldGenerating` to drive the
/// per-field three-candidate triad (literal → creative → terse) per
/// research §3.3, with state surfaced for the strip view to render.
///
/// Threading: main-thread-only by convention (matches the rest of
/// the AppKit-adjacent surfaces in this module). The
/// `KoboldGenerating` callback fires on its own queue (KoboldClient's
/// URLSession delegate queue); the controller hops back to main
/// before mutating state.
///
/// Cancellation semantics: `cancel()` stops accepting new candidates
/// and reverts to `.idle`. In-flight server work isn't cancelled at
/// the network layer (KoboldGenerating doesn't surface a cancel
/// handle in the protocol); arriving responses are dropped via the
/// generation-id guard. Per `V2_PHASE9_AI_ASSIST_RESEARCH.md` §7.5
/// this is acceptable — the user gets a fresh strip, the discarded
/// in-flight call wastes one set of tokens at most.
final class CardSuggestionsController {

    enum State: Equatable {
        case idle
        case generating(emitted: Int, total: Int)
        case ready([CardCandidate])
        case stale([CardCandidate])
        case failed(message: String)
    }

    /// Order of the candidate triad. Per research §4.3 — Literal first
    /// (cheap, low-risk anchor), Creative second (warm cache), Terse
    /// third (warm cache, length-capped).
    private static let triad: [CardCandidateStyle] = [.literal, .creative, .terse]

    let field: CardField
    private let generator: KoboldGenerating
    private let templateAssemble: (String) -> String
    private let effectiveCtx: Int
    private let stopSequences: [String]
    private let registry: CardGenPromptsRegistry

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    /// Tracks the currently-running triad. UUID-tagged so cancel/
    /// refresh can invalidate stale completions arriving after a
    /// state change.
    private struct GenerationContext {
        let id: UUID
        let draft: CardDraftSnapshot
        var candidates: [CardCandidate]
    }
    private var inFlight: GenerationContext?

    init(
        field: CardField,
        generator: KoboldGenerating,
        templateAssemble: @escaping (String) -> String,
        effectiveCtx: Int,
        stopSequences: [String] = [],
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) {
        self.field = field
        self.generator = generator
        self.templateAssemble = templateAssemble
        self.effectiveCtx = effectiveCtx
        self.stopSequences = stopSequences
        self.registry = registry
    }

    // MARK: - Public API

    func generate(draft: CardDraftSnapshot) {
        let ctx = GenerationContext(id: UUID(), draft: draft, candidates: [])
        inFlight = ctx
        setState(.generating(emitted: 0, total: Self.triad.count))
        fireNext(contextId: ctx.id)
    }

    func refresh(draft: CardDraftSnapshot) {
        // Cancel + generate fresh. Same observable shape as Generate;
        // the explicit name documents author intent in the diagnostic
        // log.
        cancel()
        generate(draft: draft)
    }

    /// Mark the current candidates stale. No-op if not currently in
    /// `.ready` — `.idle`, `.generating`, `.failed` don't have a
    /// candidate set to preserve.
    func markStale() {
        if case .ready(let candidates) = state {
            setState(.stale(candidates))
        }
    }

    /// Drop in-flight work; revert to `.idle`. Future arrivals from
    /// the abandoned generation are filtered by `inFlight.id`
    /// mismatch.
    func cancel() {
        inFlight = nil
        setState(.idle)
    }

    /// Reset to the initial state. Same as cancel for now; preserved
    /// as a separate verb so a future "discard cached candidates"
    /// path has a hook.
    func reset() {
        cancel()
    }

    // MARK: - Internals

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    private func fireNext(contextId: UUID) {
        guard let ctx = inFlight, ctx.id == contextId else { return }

        let nextIdx = ctx.candidates.count
        if nextIdx >= Self.triad.count {
            setState(.ready(ctx.candidates))
            inFlight = nil
            return
        }

        let style = Self.triad[nextIdx]
        let request = CardGenSideCall.buildRequest(
            for: field, style: style, draft: ctx.draft, registry: registry
        )
        let assembled = templateAssemble(request.prompt)

        DebugLog.shared.write(
            "cardgen: gen \(field.rawValue) [\(style.rawValue)] ← exemplar=\(request.exemplarId)"
        )
        let started = Date()

        generator.generate(
            prompt: assembled,
            stopSequences: stopSequences,
            preset: request.preset,
            maxContextLength: effectiveCtx
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleCompletion(
                    contextId: contextId,
                    request: request,
                    started: started,
                    result: result
                )
            }
        }
    }

    private func handleCompletion(
        contextId: UUID,
        request: CardGenRequest,
        started: Date,
        result: Result<String, Error>
    ) {
        // Discard arrivals after a cancel/refresh.
        guard var ctx = inFlight, ctx.id == contextId else {
            DebugLog.shared.write(
                "cardgen: gen \(field.rawValue) [\(request.style.rawValue)] dropped (stale generation)"
            )
            return
        }

        let dt = Date().timeIntervalSince(started)

        switch result {
        case .failure(let e):
            DebugLog.shared.write(
                "cardgen: gen \(request.field.rawValue) [\(request.style.rawValue)] ✗ \(e)"
            )
            inFlight = nil
            setState(.failed(message: "\(e)"))

        case .success(let raw):
            let candidate = CardGenSideCall.parseResponse(raw: raw, request: request)
            let snippet = String(candidate.text.prefix(80))
                .replacingOccurrences(of: "\n", with: " ")
            if candidate.refusal.isRefusal {
                DebugLog.shared.write(
                    "cardgen: gen \(request.field.rawValue) [\(request.style.rawValue)] ⚠ refusal in \(String(format: "%.1f", dt))s | \(snippet)"
                )
            } else {
                DebugLog.shared.write(
                    "cardgen: gen \(request.field.rawValue) [\(request.style.rawValue)] → \(candidate.text.count)c in \(String(format: "%.1f", dt))s"
                )
            }
            ctx.candidates.append(candidate)
            inFlight = ctx
            setState(.generating(emitted: ctx.candidates.count, total: Self.triad.count))
            fireNext(contextId: contextId)
        }
    }
}
