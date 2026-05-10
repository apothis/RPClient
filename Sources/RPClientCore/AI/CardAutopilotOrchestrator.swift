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
        let hint: String?
        var runningDraft: CardDraftSnapshot
        var collected: [CardFieldProposal] = []
        var callsUsed: Int = 0
        var tokensUsed: Int = 0
        var passIndex: Int = 0
        /// JSON parse retries used by the *current* pass. Resets to 0
        /// each time the pass advances. Bounded at `maxParseRetries`;
        /// when exhausted the orchestrator falls back to a plaintext
        /// parser before aborting.
        var parseRetries: Int = 0
    }
    private var inFlight: RunContext?

    /// Maximum JSON-parse retries per pass before the plaintext fallback
    /// kicks in. Live failure mode: Qwen3.6 occasionally drops the JSON
    /// envelope and emits newline-separated values.
    private static let maxParseRetries = 2

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
        hint: String? = nil,
        budget: CardAutopilotBudget = .default
    ) {
        let ctx = RunContext(id: UUID(), budget: budget, hint: hint, runningDraft: draft)
        inFlight = ctx
        let hintLog = (hint?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? " hint=\"\(hint!.prefix(60))…\"" : ""
        DebugLog.shared.write(
            "cardgen: mode3 start tags=\(draft.tags.joined(separator: ","))\(hintLog) maxCalls=\(budget.maxCalls) maxTokens=\(budget.maxTokens)"
        )
        // Show what the orchestrator believes is already filled in
        // the source draft so the edit-and-redo path is debuggable —
        // a "fully populated" card that triggers many passes points
        // straight at a snapshot extractor gap or an unsaved field.
        let prefilled = CardField.allCases
            .filter { (draft.fields[$0]?.isEmpty == false) }
            .map(\.rawValue)
        let absent = CardField.allCases
            .filter { (draft.fields[$0]?.isEmpty ?? true) }
            .map(\.rawValue)
        DebugLog.shared.write(
            "cardgen: mode3 input-snapshot prefilled=[\(prefilled.joined(separator: ","))] empty=[\(absent.joined(separator: ","))]"
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
        let skipped = pass.allFields.filter { !targets.contains($0) }

        // Always log the pass-decision details so edit-and-redo
        // behaviour is auditable: which fields the orchestrator
        // thinks are already filled (skipped) vs empty (will fire).
        DebugLog.shared.write(
            "cardgen: mode3 pass=\(pass.logTag) decision skipped=[\(skipped.map(\.rawValue).joined(separator: ","))] willFire=[\(targets.map(\.rawValue).joined(separator: ","))]"
        )

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
            registry: registry,
            authorDirection: ctx.hint
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
        dispatchPass(pass: pass, request: request, runId: ctx.id)
    }

    /// Fires the chat-completions call for a pass and routes the
    /// response back through `handlePassResult`. Extracted so the parse-
    /// failure retry path can re-fire the same request without
    /// re-running budget gates or re-counting calls.
    private func dispatchPass(
        pass: CardAutopilotPass,
        request: CardMultiFieldRequest,
        runId: UUID
    ) {
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
                // Retry the same pass up to `maxParseRetries` times
                // before falling back. Live failure mode: Qwen3.6
                // sometimes ignores json_schema on first try and emits
                // raw values; a second attempt usually returns proper
                // JSON. Retries don't count against the budget — the
                // 2-retry cap is the cost ceiling.
                if ctx.parseRetries < Self.maxParseRetries {
                    var next = ctx
                    next.parseRetries += 1
                    inFlight = next
                    DebugLog.shared.write(
                        "cardgen: mode3 ⟳ pass=\(pass.logTag) JSON parse failed (retry \(next.parseRetries)/\(Self.maxParseRetries)) — \(msg) in \(String(format: "%.1f", dt))s"
                    )
                    dispatchPass(pass: pass, request: request, runId: runId)
                    return
                }
                // Retries exhausted — try the plaintext fallback parser.
                DebugLog.shared.write(
                    "cardgen: mode3 ⤷ pass=\(pass.logTag) plaintext fallback after \(Self.maxParseRetries) JSON retries"
                )
                let plain = CardMultiFieldGenerator.parseResponseAsPlaintext(rawContent: raw, request: request)
                switch plain {
                case .success(let proposals):
                    DebugLog.shared.write(
                        "cardgen: mode3 ✓ pass=\(pass.logTag) plaintext fallback recovered \(proposals.count) fields"
                    )
                    advanceWithProposals(ctx: ctx, pass: pass, proposals: proposals, dt: dt)
                case .failure(let plainErr):
                    let combined = "json: \(msg) | plaintext: \(plainErr.description)"
                    DebugLog.shared.write(
                        "cardgen: mode3 ✗ pass=\(pass.logTag) parse \(combined) in \(String(format: "%.1f", dt))s"
                    )
                    inFlight = nil
                    setState(.aborted(
                        .passFailure(pass: pass, message: combined),
                        partialProposals: ctx.collected
                    ))
                }

            case .success(let proposals):
                advanceWithProposals(ctx: ctx, pass: pass, proposals: proposals, dt: dt)
            }
        }
    }

    /// Shared success path for JSON-parse and plaintext-fallback parses.
    /// Merges proposals into the running draft, advances the pass index,
    /// resets the parse-retry counter, and fires the next pass.
    private func advanceWithProposals(
        ctx: RunContext,
        pass: CardAutopilotPass,
        proposals: [CardFieldProposal],
        dt: TimeInterval
    ) {
        var next = ctx
        next.collected.append(contentsOf: proposals)
        var fields = next.runningDraft.fields
        for p in proposals {
            fields[p.field] = p.text
        }
        next.runningDraft = CardDraftSnapshot(
            tags: next.runningDraft.tags,
            fields: fields
        )
        next.passIndex += 1
        next.parseRetries = 0
        inFlight = next

        let refusalCount = proposals.filter(\.refusal.isRefusal).count
        let totalChars = proposals.reduce(0) { $0 + $1.text.count }
        DebugLog.shared.write(
            "cardgen: mode3 ✓ pass=\(pass.logTag) → \(proposals.count) proposals (\(totalChars)c, \(refusalCount) refusals) in \(String(format: "%.1f", dt))s"
        )
        runNextPass()
    }

    private func setState(_ new: State) {
        state = new
        onStateChange?(new)
    }
}
