import Foundation

/// Phase 9 §5.4.b — state machine for the multi-field fill UX
/// ("Fill missing fields" / "Fill this section" per §4.7). Wraps
/// `CardMultiFieldGenerator` + a `ChatCompletionsClient`; surfaces
/// state for the UI surface to render.
///
/// Threading: `@MainActor`-isolated — same posture as
/// `CardSuggestionsController`. The chat-completions callback fires
/// off the main thread; the orchestrator hops back via
/// `DispatchQueue.main.async` before mutating state.
///
/// Cancellation: per V2_PHASE9_AI_ASSIST_RESEARCH §7.5 — `cancel()`
/// reverts to `.idle`; in-flight server work isn't cancelled at the
/// network layer (the protocol doesn't surface a cancel handle), but
/// arriving responses are dropped via the generation-id guard.
@MainActor
final class CardMultiFieldOrchestrator {

    enum State: Equatable {
        case idle
        case fetching(targetCount: Int)
        case ready([CardFieldProposal])
        case failed(message: String)
    }

    private let generator: ChatCompletionsClient
    private let registry: CardGenPromptsRegistry

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private struct GenerationContext {
        let id: UUID
        let request: CardMultiFieldRequest
    }
    private var inFlight: GenerationContext?

    init(
        generator: ChatCompletionsClient,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) {
        self.generator = generator
        self.registry = registry
    }

    // MARK: - Public API

    /// Fire a multi-field fill against the given target fields. The
    /// caller is responsible for picking which fields to target (e.g.
    /// "all empty multi-line fields" for the "Fill missing fields"
    /// button or "all empty fields on this tab" for "Fill this
    /// section"). Empty `fields` is a no-op.
    func fill(
        fields: [CardField],
        draft: CardDraftSnapshot,
        authorDirection: String? = nil
    ) {
        guard !fields.isEmpty else { return }
        let request = CardMultiFieldGenerator.buildRequest(
            for: fields, draft: draft, registry: registry, authorDirection: authorDirection
        )
        let ctx = GenerationContext(id: UUID(), request: request)
        inFlight = ctx
        setState(.fetching(targetCount: fields.count))

        let targetsStr = fields.map(\.rawValue).joined(separator: ",")
        DebugLog.shared.write(
            "cardgen: mode2 fill \(fields.count) fields ← exemplar=\(request.exemplarId), targets=\(targetsStr)"
        )
        let started = Date()

        generator.chatCompletions(
            systemMessage: request.systemMessage,
            userMessage: request.userMessage,
            responseSchema: request.schemaJSON,
            schemaName: request.schemaName,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handleCompletion(
                    contextId: ctx.id,
                    started: started,
                    result: result
                )
            }
        }
    }

    func cancel() {
        inFlight = nil
        setState(.idle)
    }

    func reset() { cancel() }

    // MARK: - Internals

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }

    private func handleCompletion(
        contextId: UUID,
        started: Date,
        result: Result<String, Error>
    ) {
        guard let ctx = inFlight, ctx.id == contextId else {
            DebugLog.shared.write("cardgen: mode2 dropped (stale generation)")
            return
        }
        let dt = Date().timeIntervalSince(started)

        switch result {
        case .failure(let e):
            DebugLog.shared.write(
                "cardgen: mode2 ✗ \(e) in \(String(format: "%.1f", dt))s"
            )
            inFlight = nil
            setState(.failed(message: "\(e)"))

        case .success(let raw):
            let parsed = CardMultiFieldGenerator.parseResponse(
                rawContent: raw, request: ctx.request
            )
            switch parsed {
            case .failure(let parseErr):
                DebugLog.shared.write(
                    "cardgen: mode2 ✗ parse \(parseErr) in \(String(format: "%.1f", dt))s"
                )
                inFlight = nil
                setState(.failed(message: parseErr.description))

            case .success(let proposals):
                let refusalCount = proposals.filter(\.refusal.isRefusal).count
                let totalChars = proposals.reduce(0) { $0 + $1.text.count }
                DebugLog.shared.write(
                    "cardgen: mode2 → \(proposals.count) proposals (\(totalChars)c, \(refusalCount) refusals) in \(String(format: "%.1f", dt))s"
                )
                inFlight = nil
                setState(.ready(proposals))
            }
        }
    }
}
