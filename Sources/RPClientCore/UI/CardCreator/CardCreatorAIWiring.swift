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
}
