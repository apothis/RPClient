import Foundation

/// Phase 9 §5.4.a — AppKit ↔ AI-backend wiring helpers. Keeps the
/// per-tab view controllers light: each tab just calls
/// `makeController(field:draft:)` and binds it to the field's
/// suggestions strip.
///
/// Pulls the resolved server (per-window picker → active chat's
/// server → defaultServerId per `KoboldClientRegistry.cardCreatorClient`)
/// and the active chat's chat template (or Qwen as a sensible default
/// when no chat is current). Side-call always uses
/// `qwenThinking: false` — the empty `<think></think>` pre-fill is
/// what suppresses the Qwen3 thinking trap on the text-completion
/// endpoint per V2_PHASE9_AI_ASSIST_RESEARCH §2 (Probe 4 confirmed
/// this is real and load-bearing).
enum CardCreatorAIWiring {

    /// Build a fully-wired controller for the given field. Caller
    /// owns the controller (typically: a view-controller property
    /// keyed by field name) and binds it to the strip via
    /// `strip.controller = ...`.
    @MainActor
    static func makeController(
        field: CardField,
        draft: CharacterDraft
    ) -> CardSuggestionsController {
        let app = AppState.shared
        let chat = app.currentChat
        let kobold = app.registry.cardCreatorClient(chatOverride: chat?.serverId)
        let templateId = chat?.templateId ?? QwenTemplate().id
        let template = Templates.byId(templateId, qwenThinking: false)

        return CardSuggestionsController(
            field: field,
            generator: kobold,
            templateAssemble: { body in
                let turns = [Turn(role: .user, text: body)]
                return template.assemble(
                    memoryBlock: nil, summary: nil, worldInfoHits: [],
                    authorsNote: nil, turns: turns
                )
            },
            // Reasonable default for KoboldCPP-shaped local servers.
            // Phase 10 will probe `/api/extra/true_max_context_length`
            // and feed the actual value here.
            effectiveCtx: 16384,
            stopSequences: template.stopSequences
        )
    }

    /// Bind a multi-line field's suggestions strip to the registry's
    /// controller for that field. Hoisted out of the per-tab
    /// `attachStrip` helpers so each tab is one line of glue.
    @MainActor
    static func attachStrip(
        to fieldView: MultilineFieldView,
        field: CardField,
        aiRegistry: CardCreatorAIRegistry,
        draft: CharacterDraft
    ) {
        guard let strip = fieldView.suggestionsStrip else { return }
        let controller = aiRegistry.controller(for: field)
        strip.controller = controller
        strip.onRequestGenerate = { [weak draft] in
            guard let draft else { return }
            let snapshot = CardDraftSnapshotBuilder.snapshot(of: draft)
            controller.generate(draft: snapshot)
        }
    }

    /// Phase 9 §5.4.b — single-shot generation for list-shaped fields
    /// (alternate greetings, group-only greetings). Fires ONE
    /// candidate (no triad), parses, calls completion with the text
    /// or nil on failure.
    ///
    /// Used by `GreetingListEditor.onGenerate` — clicking the
    /// Generate button appends one new entry.
    @MainActor
    static func generateOnce(
        field: CardField,
        style: CardCandidateStyle = .literal,
        draft: CharacterDraft,
        completion: @escaping (String?) -> Void
    ) {
        let app = AppState.shared
        let chat = app.currentChat
        let kobold = app.registry.cardCreatorClient(chatOverride: chat?.serverId)
        let templateId = chat?.templateId ?? QwenTemplate().id
        let template = Templates.byId(templateId, qwenThinking: false)

        let snapshot = CardDraftSnapshotBuilder.snapshot(of: draft)
        let request = CardGenSideCall.buildRequest(for: field, style: style, draft: snapshot)
        let body = request.prompt
        let assembled = template.assemble(
            memoryBlock: nil, summary: nil, worldInfoHits: [],
            authorsNote: nil,
            turns: [Turn(role: .user, text: body)]
        )

        DebugLog.shared.write("cardgen: generateOnce \(field.rawValue) [\(style.rawValue)] ← exemplar=\(request.exemplarId)")
        let started = Date()

        kobold.generate(
            prompt: assembled,
            stopSequences: template.stopSequences,
            preset: request.preset,
            maxContextLength: 16384
        ) { result in
            DispatchQueue.main.async {
                let dt = Date().timeIntervalSince(started)
                switch result {
                case .failure(let e):
                    DebugLog.shared.write("cardgen: generateOnce \(field.rawValue) ✗ \(e) in \(String(format: "%.1f", dt))s")
                    completion(nil)
                case .success(let raw):
                    let candidate = CardGenSideCall.parseResponse(raw: raw, request: request)
                    if candidate.refusal.isRefusal {
                        DebugLog.shared.write("cardgen: generateOnce \(field.rawValue) ⚠ refusal in \(String(format: "%.1f", dt))s")
                    } else {
                        DebugLog.shared.write("cardgen: generateOnce \(field.rawValue) → \(candidate.text.count)c in \(String(format: "%.1f", dt))s")
                    }
                    completion(candidate.text.isEmpty ? nil : candidate.text)
                }
            }
        }
    }
}
