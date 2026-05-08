import Foundation

/// Phase 9 §5.4.c — Mode 3 ("Generate full card") orchestration. Walks
/// the §4.8 dependency graph in 6 ordered passes, each a single
/// `response_format: json_schema` call against `/v1/chat/completions`.
/// Per-pass field selection skips fields the author already populated;
/// each pass's accepted proposals merge into the running draft so the
/// next pass sees them as upstream context (and KoboldCPP's KV cache
/// reuses the system+exemplar prefix across passes).
///
/// Cost ceilings are hard: 10 side-calls and 16k tokens by default.
/// Exceeding either aborts with the partial proposals preserved so the
/// review surface can still commit what came back. Diagnostic logging
/// uses the `cardgen: mode3` prefix per V2_PHASE9_CARD_CREATOR §4.8.

/// Ordered passes for full-card autopilot. The natural authoring order
/// is preserved so each pass's field set only depends on prior passes.
public enum CardAutopilotPass: Int, CaseIterable, Sendable, Equatable {
    case identity
    case personaVoice
    case bodyIntimacy
    case disposition
    case system
    case notes

    /// Every field this pass *can* populate. Filtering against the
    /// current draft happens via `targets(in:)`.
    public var allFields: [CardField] {
        switch self {
        case .identity:
            return [
                .name,
                .nickname,
                .detailsSex,
                .detailsAge,
                .detailsPronouns,
                .detailsSpecies,
                .detailsOrientation,
            ]
        case .personaVoice:
            return [
                .description,
                .personality,
                .scenario,
                .firstMessage,
                .messageExample,
                .alternateGreetings,
            ]
        case .bodyIntimacy:
            return [
                .detailsAppearance,
                .detailsMood,
                .intimacyBuild,
                .intimacyAnatomy,
                .intimacyMarkings,
                .intimacySensitivities,
                .intimacyScent,
            ]
        case .disposition:
            // intimacyLimits intentionally excluded — bundled-default,
            // not generated, per V2_PHASE9_AI_ASSIST_RESEARCH §3.5.
            return [.intimacyTurnOns, .intimacyKinks]
        case .system:
            return [.systemPrompt, .postHistoryInstructions]
        case .notes:
            return [.creatorNotes, .depthPrompt]
        }
    }

    /// Fields this pass should target given the current draft state.
    /// A field is a target only if it's currently empty — pre-filled
    /// content is treated as authored intent and preserved.
    public func targets(in draft: CardDraftSnapshot) -> [CardField] {
        allFields.filter { (draft.fields[$0]?.isEmpty ?? true) }
    }

    /// Short tag for diagnostic logs.
    var logTag: String {
        switch self {
        case .identity: return "identity"
        case .personaVoice: return "personaVoice"
        case .bodyIntimacy: return "bodyIntimacy"
        case .disposition: return "disposition"
        case .system: return "system"
        case .notes: return "notes"
        }
    }
}

public struct CardAutopilotBudget: Sendable, Equatable {
    public let maxCalls: Int
    public let maxTokens: Int

    public init(maxCalls: Int, maxTokens: Int) {
        self.maxCalls = maxCalls
        self.maxTokens = maxTokens
    }

    /// Defaults from V2_PHASE9_CARD_CREATOR §4.8 cost ceilings.
    public static let `default` = CardAutopilotBudget(maxCalls: 10, maxTokens: 16_000)
}

public enum CardAutopilotAbortReason: Equatable, Sendable {
    case callsExceeded
    case tokensExceeded
    case userCancelled
    case passFailure(pass: CardAutopilotPass, message: String)
}

@MainActor
final class CardAutopilotOrchestrator {

    enum State: Equatable {
        case idle
        case running(
            currentPass: CardAutopilotPass,
            completedPasses: Int,
            totalPasses: Int,
            callsUsed: Int,
            tokensUsed: Int
        )
        case completed(proposals: [CardFieldProposal])
        case aborted(CardAutopilotAbortReason, partialProposals: [CardFieldProposal])
    }

    private let generator: ChatCompletionsClient
    private let registry: CardGenPromptsRegistry

    private(set) var state: State = .idle
    var onStateChange: ((State) -> Void)?

    private struct RunContext {
        let id: UUID
        let budget: CardAutopilotBudget
        var runningDraft: CardDraftSnapshot
        var collected: [CardFieldProposal] = []
        var callsUsed: Int = 0
        var tokensUsed: Int = 0
        var passIndex: Int = 0
    }
    private var inFlight: RunContext?

    init(
        generator: ChatCompletionsClient,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) {
        self.generator = generator
        self.registry = registry
    }

    // MARK: - Public API

    func generate(
        draft: CardDraftSnapshot,
        budget: CardAutopilotBudget = .default
    ) {
        let ctx = RunContext(id: UUID(), budget: budget, runningDraft: draft)
        inFlight = ctx
        DebugLog.shared.write(
            "cardgen: mode3 start tags=\(draft.tags.joined(separator: ",")) maxCalls=\(budget.maxCalls) maxTokens=\(budget.maxTokens)"
        )
        runNextPass()
    }

    func cancel() {
        guard inFlight != nil else { return }
        DebugLog.shared.write("cardgen: mode3 cancelled by user")
        inFlight = nil
        setState(.idle)
    }

    func reset() { cancel() }

    // MARK: - Pass driver

    private func runNextPass() {
        guard var ctx = inFlight else { return }

        // All passes done?
        if ctx.passIndex >= CardAutopilotPass.allCases.count {
            DebugLog.shared.write(
                "cardgen: mode3 ✓ done — \(ctx.collected.count) proposals across \(ctx.callsUsed) calls (\(ctx.tokensUsed) max-token budget)"
            )
            inFlight = nil
            setState(.completed(proposals: ctx.collected))
            return
        }

        let pass = CardAutopilotPass.allCases[ctx.passIndex]
        let targets = pass.targets(in: ctx.runningDraft)

        // Skip-empty-pass: nothing left to fill in this pass.
        if targets.isEmpty {
            DebugLog.shared.write("cardgen: mode3 skip pass=\(pass.logTag) (all fields pre-filled)")
            ctx.passIndex += 1
            inFlight = ctx
            runNextPass()
            return
        }

        let request = CardMultiFieldGenerator.buildRequest(
            for: targets,
            draft: ctx.runningDraft,
            registry: registry
        )

        // Pre-flight budget check. Calls counter is incremented optimistically;
        // if we'd exceed either ceiling we abort before firing.
        let nextCalls = ctx.callsUsed + 1
        let nextTokens = ctx.tokensUsed + request.maxTokens
        if nextCalls > ctx.budget.maxCalls {
            DebugLog.shared.write(
                "cardgen: mode3 ✗ abort pass=\(pass.logTag) reason=callsExceeded (\(nextCalls) > \(ctx.budget.maxCalls))"
            )
            inFlight = nil
            setState(.aborted(.callsExceeded, partialProposals: ctx.collected))
            return
        }
        if nextTokens > ctx.budget.maxTokens {
            DebugLog.shared.write(
                "cardgen: mode3 ✗ abort pass=\(pass.logTag) reason=tokensExceeded (\(nextTokens) > \(ctx.budget.maxTokens))"
            )
            inFlight = nil
            setState(.aborted(.tokensExceeded, partialProposals: ctx.collected))
            return
        }

        ctx.callsUsed = nextCalls
        ctx.tokensUsed = nextTokens
        inFlight = ctx

        setState(.running(
            currentPass: pass,
            completedPasses: ctx.passIndex,
            totalPasses: CardAutopilotPass.allCases.count,
            callsUsed: ctx.callsUsed,
            tokensUsed: ctx.tokensUsed
        ))

        let targetsStr = targets.map(\.rawValue).joined(separator: ",")
        DebugLog.shared.write(
            "cardgen: mode3 → pass=\(pass.logTag) targets=\(targetsStr) exemplar=\(request.exemplarId)"
        )
        let started = Date()
        let runId = ctx.id

        generator.chatCompletions(
            systemMessage: request.systemMessage,
            userMessage: request.userMessage,
            responseSchema: request.schemaJSON,
            schemaName: request.schemaName,
            temperature: request.temperature,
            maxTokens: request.maxTokens
        ) { [weak self] result in
            DispatchQueue.main.async {
                self?.handlePassResult(
                    runId: runId,
                    pass: pass,
                    request: request,
                    started: started,
                    result: result
                )
            }
        }
    }

    private func handlePassResult(
        runId: UUID,
        pass: CardAutopilotPass,
        request: CardMultiFieldRequest,
        started: Date,
        result: Result<String, Error>
    ) {
        // Cancellation guard: if cancel() ran or a different generation
        // is in flight, drop the response.
        guard let ctx = inFlight, ctx.id == runId else {
            DebugLog.shared.write("cardgen: mode3 dropped (stale run)")
            return
        }
        let dt = Date().timeIntervalSince(started)

        switch result {
        case .failure(let e):
            let msg = "\(e)"
            DebugLog.shared.write(
                "cardgen: mode3 ✗ pass=\(pass.logTag) http \(msg) in \(String(format: "%.1f", dt))s"
            )
            inFlight = nil
            setState(.aborted(
                .passFailure(pass: pass, message: msg),
                partialProposals: ctx.collected
            ))

        case .success(let raw):
            let parsed = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: request)
            switch parsed {
            case .failure(let parseErr):
                let msg = parseErr.description
                DebugLog.shared.write(
                    "cardgen: mode3 ✗ pass=\(pass.logTag) parse \(msg) in \(String(format: "%.1f", dt))s"
                )
                inFlight = nil
                setState(.aborted(
                    .passFailure(pass: pass, message: msg),
                    partialProposals: ctx.collected
                ))

            case .success(let proposals):
                var next = ctx
                next.collected.append(contentsOf: proposals)
                // Merge proposals into running draft for next-pass upstream.
                var fields = next.runningDraft.fields
                for p in proposals {
                    fields[p.field] = p.text
                }
                next.runningDraft = CardDraftSnapshot(
                    tags: next.runningDraft.tags,
                    fields: fields
                )
                next.passIndex += 1
                inFlight = next

                let refusalCount = proposals.filter(\.refusal.isRefusal).count
                let totalChars = proposals.reduce(0) { $0 + $1.text.count }
                DebugLog.shared.write(
                    "cardgen: mode3 ✓ pass=\(pass.logTag) → \(proposals.count) proposals (\(totalChars)c, \(refusalCount) refusals) in \(String(format: "%.1f", dt))s"
                )
                runNextPass()
            }
        }
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }
}
