import AppKit
import Foundation

enum AppNotification {
    static let chatListChanged = Notification.Name("RPClient.chatListChanged")
    static let currentChatChanged = Notification.Name("RPClient.currentChatChanged")
    static let chatUpdated = Notification.Name("RPClient.chatUpdated")
    static let streamTokenAppended = Notification.Name("RPClient.streamTokenAppended")
    static let streamFinished = Notification.Name("RPClient.streamFinished")
    static let statusChanged = Notification.Name("RPClient.statusChanged")
    /// Posted on the *transition* edges of `AppState.serverReachable` —
    /// reachable → unreachable, or back. UI uses this to fire one-shot
    /// alerts (banner / NSAlert) without spamming on every status tick.
    static let serverReachableChanged = Notification.Name("RPClient.serverReachableChanged")
    static let fontChanged = Notification.Name("RPClient.fontChanged")
    /// Fires on the transition edges of `AppState.isThinking` — model has
    /// just entered a `<think>` block, or just left one. The UI binds the
    /// "Thinking…" placeholder on the active assistant turn to this.
    static let thinkingStateChanged = Notification.Name("RPClient.thinkingStateChanged")
}

final class AppState {
    static let shared = AppState()

    private(set) var settings: Settings
    private(set) var chats: [Chat]
    private(set) var currentChatId: UUID?
    private(set) var isStreaming: Bool = false
    private(set) var isSummarizing: Bool = false
    private(set) var lastSummarizerError: String?
    private(set) var isExtracting: Bool = false
    private(set) var lastExtractError: String?

    // Status info
    /// True when the most recent server probe succeeded. Flipped to false the
    /// first time `fetchModel` fails (timeout / refused / unreachable) and back
    /// to true on the next successful probe. The transition fires
    /// `serverReachableChanged` so UI can surface a banner. A periodic health
    /// check runs every 30s when no exclusive side-call is in flight.
    private(set) var serverReachable: Bool = true
    /// Last error message from a failed server probe — surfaced in the status
    /// bar tooltip so the user knows whether it's a timeout vs. refused etc.
    private(set) var lastServerError: String?
    private var healthCheckTimer: Timer?
    private(set) var modelName: String = "—"
    /// Template id matching the currently-loaded model, derived from
    /// `modelName` via `Templates.detect(forModelName:)`. New chats pick this
    /// up automatically so a Qwen-loaded server doesn't keep handing out
    /// gemma-templated chats. Nil when the model name doesn't match a
    /// known family — caller falls back to `settings.defaultTemplateId`.
    private(set) var detectedTemplateId: String?
    /// Best-effort name of the loaded embedding model on the server (or nil if
    /// none / probe hasn't completed). Surfaced in the status bar so the user
    /// can see at a glance that retrieval has a backing model.
    private(set) var embeddingModel: String?
    /// Vector dimension reported by a probe embedding call. Acts as a sanity
    /// signal that `/v1/embeddings` is wired up and responding.
    private(set) var embeddingDim: Int?
    private(set) var maxContext: Int = 4096
    private(set) var lastTokensPerSec: Double = 0
    private(set) var lastUsage: BudgetUsage = .zero
    /// Number of leading turns that would be dropped from the prompt at current
    /// budget. Surfaces in the chat view so the user can see what was cut.
    private(set) var lastTruncatedCount: Int = 0

    // Cache + perf telemetry (§9.10 — see MEMORY_RESEARCH.md)
    private(set) var lastTTFT: TimeInterval?
    private(set) var lastPromptProcessTime: TimeInterval?
    /// Estimated fraction of the new prompt that overlapped the last sent prompt
    /// as a leading prefix. Proxy for "how much of the KV cache should still be hot."
    /// 1.0 = full match, 0.0 = nothing in common.
    private(set) var lastCacheRatio: Double?
    private var lastSentPrompt: String?

    // Retrieval state
    private(set) var lastRetrievalHits: [VectorStore.Hit] = []
    private(set) var isIndexing: Bool = false
    private(set) var lastIndexError: String?
    /// True from the moment a send/regen kicks off the retrieval embed call
    /// until the hits land. Distinct from `isIndexing` (background re-embed).
    private(set) var isRetrieving: Bool = false

    // Activity start times — drives the elapsed-time readout in the status bar.
    private(set) var retrievingStart: Date?
    private(set) var indexingStart: Date?
    private(set) var summarizingStart: Date?
    private(set) var extractingStart: Date?

    var effectiveContext: Int {
        let override = settings.maxContextOverride
        if override > 0 { return min(override, maxContext) }
        return maxContext
    }

    let kobold: KoboldClient

    private init() {
        let s = Storage.shared.loadSettings()
        self.settings = s
        self.chats = Storage.shared.listChats()
        self.currentChatId = chats.first?.id
        let url = URL(string: s.serverURL) ?? URL(string: "http://localhost:5001")!
        self.kobold = KoboldClient(baseURL: url)
        if chats.isEmpty {
            let c = Chat(templateId: s.defaultTemplateId, samplerPresetId: s.defaultSamplerPresetId)
            Storage.shared.saveChat(c)
            self.chats = [c]
            self.currentChatId = c.id
        }
        refreshServerInfo()
        startHealthChecks()
    }

    var currentChat: Chat? {
        guard let id = currentChatId else { return nil }
        return chats.first(where: { $0.id == id })
    }

    func updateCurrent(_ mutate: (inout Chat) -> Void) {
        guard let id = currentChatId,
              let idx = chats.firstIndex(where: { $0.id == id }) else { return }
        var c = chats[idx]
        mutate(&c)
        c.modified = Date()
        chats[idx] = c
        Storage.shared.saveChat(c)
        NotificationCenter.default.post(name: AppNotification.chatUpdated, object: nil)
        scheduleUsageRecompute()
    }

    func updateChat(id: UUID, _ mutate: (inout Chat) -> Void) {
        guard let idx = chats.firstIndex(where: { $0.id == id }) else { return }
        var c = chats[idx]
        mutate(&c)
        c.modified = Date()
        chats[idx] = c
        Storage.shared.saveChat(c)
        NotificationCenter.default.post(name: AppNotification.chatUpdated, object: nil)
    }

    func selectChat(id: UUID) {
        currentChatId = id
        lastUsage = .zero
        lastTruncatedCount = 0
        lastRetrievalHits = []
        // The cached prompt is per-app-session, not per-chat — leaving it
        // populated across a chat switch makes the next send compute LCP
        // against an unrelated chat's prompt, so the cache% readout shows a
        // bogus low-but-nonzero value (template scaffolding overlap) when
        // it should read 0% / fresh prefill.
        lastSentPrompt = nil
        lastCacheRatio = nil
        NotificationCenter.default.post(name: AppNotification.currentChatChanged, object: nil)
        scheduleUsageRecompute()
        kickIndexing()
    }

    func newChat() {
        let c = Chat(
            templateId: detectedTemplateId ?? settings.defaultTemplateId,
            samplerPresetId: settings.defaultSamplerPresetId
        )
        Storage.shared.saveChat(c)
        chats.insert(c, at: 0)
        currentChatId = c.id
        // Same reason as selectChat — fresh chat must not inherit the
        // previous chat's cache baseline.
        lastSentPrompt = nil
        lastCacheRatio = nil
        NotificationCenter.default.post(name: AppNotification.chatListChanged, object: nil)
        NotificationCenter.default.post(name: AppNotification.currentChatChanged, object: nil)
    }

    func deleteChat(id: UUID) {
        Storage.shared.deleteChat(id: id)
        RetrievalEngine.shared.deleteStore(for: id)
        chats.removeAll(where: { $0.id == id })
        if currentChatId == id {
            currentChatId = chats.first?.id
            // Active chat went away — same cache-baseline reset as the
            // selectChat path so the next send into the new current chat
            // doesn't diff against the deleted chat's prompt.
            lastSentPrompt = nil
            lastCacheRatio = nil
            NotificationCenter.default.post(name: AppNotification.currentChatChanged, object: nil)
        }
        NotificationCenter.default.post(name: AppNotification.chatListChanged, object: nil)
    }

    func saveSettings(_ s: Settings) {
        self.settings = s
        Storage.shared.saveSettings(s)
        if let url = URL(string: s.serverURL) {
            kobold.setBaseURL(url)
        }
        refreshServerInfo()
        scheduleUsageRecompute()
    }

    func refreshServerInfo() {
        kobold.fetchModel { [weak self] result in
            guard let self = self else { return }
            DispatchQueue.main.async {
                switch result {
                case .success(let name):
                    self.modelName = name
                    self.detectedTemplateId = Templates.detect(forModelName: name)
                    self.markServerReachable(true)
                case .failure(let err):
                    self.markServerReachable(false, error: "\(err)")
                }
                NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
            }
        }
        kobold.fetchTrueMaxContext { [weak self] result in
            guard let self = self else { return }
            if case .success(let v) = result {
                DispatchQueue.main.async {
                    self.maxContext = v
                    NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
                    self.scheduleUsageRecompute()
                }
            }
        }
        refreshEmbeddingInfo()
    }

    /// Update reachability state and fire the transition notification only on
    /// edges so subscribers (UI banners, alerts) don't have to dedupe.
    private func markServerReachable(_ reachable: Bool, error: String? = nil) {
        self.lastServerError = reachable ? nil : error
        guard reachable != self.serverReachable else { return }
        self.serverReachable = reachable
        DebugLog.shared.write("health: server \(reachable ? "reachable again" : "UNREACHABLE — \(error ?? "?")")")
        NotificationCenter.default.post(name: AppNotification.serverReachableChanged, object: nil)
    }

    /// Start (or restart) the 30s health-check loop. Keeps `serverReachable`
    /// fresh even when the user isn't actively sending. Skipped while a
    /// generation/summarize/extract/embed call is already in flight — those
    /// calls already exercise the server, no need to double-up.
    func startHealthChecks(intervalSeconds: TimeInterval = 30) {
        healthCheckTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: intervalSeconds, repeats: true) { [weak self] _ in
            self?.healthCheckTick()
        }
        // Run on the common modes so it keeps ticking during menu interactions.
        RunLoop.main.add(timer, forMode: .common)
        healthCheckTimer = timer
    }

    /// True for the NSURLError codes that mean "we couldn't talk to the server"
    /// — distinct from server-side HTTP errors (404, 500, etc.) which mean the
    /// server is reachable but unhappy. Only the former should flip the
    /// reachability flag.
    static func isTransportError(_ err: NSError) -> Bool {
        guard err.domain == NSURLErrorDomain else { return false }
        switch err.code {
        case NSURLErrorTimedOut,
             NSURLErrorCannotConnectToHost,
             NSURLErrorCannotFindHost,
             NSURLErrorNotConnectedToInternet,
             NSURLErrorNetworkConnectionLost,
             NSURLErrorDNSLookupFailed,
             NSURLErrorResourceUnavailable,
             NSURLErrorBadServerResponse:
            return true
        default:
            return false
        }
    }

    private func healthCheckTick() {
        guard !isStreaming, !isSummarizing, !isExtracting, !isRetrieving, !isIndexing else { return }
        kobold.fetchModel { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                switch result {
                case .success(let name):
                    if self.modelName != name {
                        self.modelName = name
                        self.detectedTemplateId = Templates.detect(forModelName: name)
                        NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
                    }
                    self.markServerReachable(true)
                    // If we just came back up, also re-probe the embedding model
                    // (the user might have restarted kobold with a different one).
                    if self.embeddingDim == nil {
                        self.refreshEmbeddingInfo()
                    }
                case .failure(let err):
                    self.markServerReachable(false, error: "\(err)")
                }
            }
        }
    }

    /// Probe the server's embedding endpoint. If the call succeeds we have an
    /// embedding model loaded; we capture the dimension and a best-effort name.
    /// Logged unconditionally so the user can confirm retrieval prerequisites
    /// are in place even if retrieval itself is disabled.
    func refreshEmbeddingInfo() {
        kobold.fetchEmbeddingInfo { [weak self] info in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.embeddingModel = info.name
                self.embeddingDim = info.dim
                if let name = info.name, let dim = info.dim {
                    DebugLog.shared.write("embeddings: model=\(name) dim=\(dim)")
                } else if let dim = info.dim {
                    DebugLog.shared.write("embeddings: probe ok dim=\(dim) (name unknown)")
                } else {
                    DebugLog.shared.write("embeddings: not available — \(info.error ?? "no model loaded?")")
                }
                NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
            }
        }
    }

    // MARK: - Generation

    private var streamStart: Date?
    private var firstTokenAt: Date?
    private var streamTokens: Int = 0
    /// True only for streams initiated by `sendUserMessage`. Regen/continue
    /// streams set this false so the post-stream auto-extract pass doesn't
    /// re-tax the model on identical user windows. Read in the `onFinish`
    /// handler.
    private var streamIsFreshUserTurn: Bool = false
    /// Active when the current chat uses the Qwen template and Qwen3
    /// thinking mode is enabled — strips the leading `<think>…</think>`
    /// block from the streamed reply before it reaches `turn.text`. Reset
    /// at every `startStreaming` and finalized in the stream-finish handler.
    private var streamThinkFilter: ThinkBlockFilter?

    /// True while the active stream is inside a `<think>` block. Read by the
    /// UI to render a "Thinking…" placeholder on the active assistant turn
    /// before the first reply token lands. Driven from `appendStreamToken`.
    private(set) var isThinking: Bool = false {
        didSet {
            guard isThinking != oldValue else { return }
            NotificationCenter.default.post(
                name: AppNotification.thinkingStateChanged, object: nil
            )
        }
    }

    func sendUserMessage(_ text: String) {
        guard !isStreaming, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        updateCurrent { c in
            c.turns.append(Turn(role: .user, text: text))
            c.turns.append(Turn(role: .assistant, text: ""))
            // Pre-seed the assistant turn with one empty variant carrying
            // the upstream-context fingerprint. Done here (rather than on
            // first stream token) so a future user edit on any prior turn
            // can be detected as having invalidated this variant.
            let asstIdx = c.turns.count - 1
            let fp = Chat.makeContextFingerprint(c.turns[..<asstIdx])
            c.turns[asstIdx].addEmptyVariant(
                samplerPresetId: c.samplerPresetId,
                contextFingerprint: fp
            )
            if c.title == "New Chat" {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                c.title = String(trimmed.prefix(40))
            }
        }
        DebugLog.shared.write("trigger: send (userTextChars=\(text.count))")
        startStreaming(freshUserTurn: true)
    }

    /// Default cap on `Turn.variants.count`. Per-chat / per-app exposure of
    /// this number is a follow-up — see V2_PLAN.md §3.6.
    static let variantCap = 5

    /// Generate a new alternative reply for the trailing assistant turn,
    /// preserving prior swipes. If the chat ends on a user turn (e.g. the
    /// last reply was deleted), falls back to appending a fresh empty
    /// assistant turn. No-op when at the variant cap.
    func regenerate() {
        guard !isStreaming, var c = currentChat else { return }
        DebugLog.shared.write("trigger: regen (turnsBefore=\(c.turns.count))")
        if let lastIdx = c.turns.indices.last, c.turns[lastIdx].role == .assistant {
            if c.turns[lastIdx].variants.count >= AppState.variantCap {
                DebugLog.shared.write(
                    "regen: refused — variants at cap (\(AppState.variantCap))"
                )
                return
            }
            let fp = Chat.makeContextFingerprint(c.turns[..<lastIdx])
            c.turns[lastIdx].addEmptyVariant(
                samplerPresetId: c.samplerPresetId,
                contextFingerprint: fp
            )
        } else {
            // Append a fresh assistant turn and seed it with one empty,
            // fingerprint-stamped variant so the same staleness machinery
            // applies as in `sendUserMessage`.
            c.turns.append(Turn(role: .assistant, text: ""))
            let asstIdx = c.turns.count - 1
            let fp = Chat.makeContextFingerprint(c.turns[..<asstIdx])
            c.turns[asstIdx].addEmptyVariant(
                samplerPresetId: c.samplerPresetId,
                contextFingerprint: fp
            )
        }
        updateCurrent { ch in
            ch.turns = c.turns
        }
        startStreaming()
    }

    /// Destructive regen — overwrite the active variant in place rather than
    /// adding a new one. Used by the "Replace current variant" path
    /// (Cmd-Shift-R / context menu) so the user can opt back into the pre-V2
    /// behaviour when they don't want the old text kept around.
    func replaceCurrentVariant() {
        guard !isStreaming, var c = currentChat else { return }
        guard let lastIdx = c.turns.indices.last,
              c.turns[lastIdx].role == .assistant,
              !c.turns[lastIdx].variants.isEmpty else {
            // Nothing to replace — fall through to the normal regen path so
            // the user gets a reply regardless.
            regenerate()
            return
        }
        DebugLog.shared.write("trigger: replace-variant")
        let active = c.turns[lastIdx].activeVariant
        let fp = Chat.makeContextFingerprint(c.turns[..<lastIdx])
        c.turns[lastIdx].variants[active].text = ""
        c.turns[lastIdx].variants[active].edited = false
        c.turns[lastIdx].variants[active].contextFingerprint = fp
        c.turns[lastIdx].text = ""
        updateCurrent { ch in
            ch.turns = c.turns
        }
        startStreaming()
    }

    /// Switch the active variant of `turnId` to the previous one. No-op when
    /// already at the first variant or when the turn carries no variants.
    func selectPreviousVariant(turnId: UUID) {
        guard let id = currentChatId else { return }
        updateChat(id: id) { c in
            guard let idx = c.turns.firstIndex(where: { $0.id == turnId }) else { return }
            let cur = c.turns[idx].activeVariant
            guard cur > 0 else { return }
            c.turns[idx].setActiveIndex(cur - 1)
        }
    }

    /// Drop the currently-active variant on `turnId`, falling back to the
    /// previous one (or the first one if the active was the head). No-op
    /// when streaming or when the turn has 1 or fewer variants — we never
    /// orphan a turn into a `variants = []` shape post-V2.
    func deleteActiveVariant(turnId: UUID) {
        guard !isStreaming, let id = currentChatId else { return }
        updateChat(id: id) { c in
            guard let idx = c.turns.firstIndex(where: { $0.id == turnId }) else { return }
            guard c.turns[idx].variants.count > 1 else { return }
            let active = c.turns[idx].activeVariant
            c.turns[idx].variants.remove(at: active)
            // Keep the same numeric index when possible (so deleting variant
            // 3/5 lands on the new 3/4), else clamp to the new last index.
            let newActive = max(0, min(active, c.turns[idx].variants.count - 1))
            c.turns[idx].setActiveIndex(newActive)
        }
    }

    /// Switch the active variant of `turnId` to the next one. No-op when
    /// already at the last variant — the UI calls `regenerate()` separately
    /// to extend past the end.
    func selectNextVariant(turnId: UUID) {
        guard let id = currentChatId else { return }
        updateChat(id: id) { c in
            guard let idx = c.turns.firstIndex(where: { $0.id == turnId }) else { return }
            let count = c.turns[idx].variants.count
            let cur = c.turns[idx].activeVariant
            guard cur < count - 1 else { return }
            c.turns[idx].setActiveIndex(cur + 1)
        }
    }

    /// Resume the most recent assistant turn instead of starting a new one.
    /// Used when a reply was cut short by the per-reply token cap — the model
    /// picks up mid-sentence because the prompt is left without the assistant
    /// end-of-turn marker (see template `continuation` flag).
    func continueGeneration() {
        guard !isStreaming, let chat = currentChat,
              let last = chat.turns.last, last.role == .assistant,
              !last.text.isEmpty else { return }
        DebugLog.shared.write("trigger: continue (assistantTextChars=\(last.text.count))")
        startStreaming(continuation: true)
    }

    func stop() {
        kobold.cancel()
    }

    private func startStreaming(continuation: Bool = false, freshUserTurn: Bool = false) {
        guard let chat = currentChat else { return }
        isStreaming = true
        streamIsFreshUserTurn = freshUserTurn
        streamStart = Date()
        firstTokenAt = nil
        streamTokens = 0
        // Continuation streams resume mid-reply, after any think block has
        // already been emitted and stripped — engaging the filter would eat
        // legitimate content, so it stays nil for those.
        if !continuation,
           chat.templateId == "qwen",
           settings.qwenThinkingEnabled {
            streamThinkFilter = ThinkBlockFilter()
        } else {
            streamThinkFilter = nil
        }
        let preset = SamplerPreset.presets.first(where: { $0.id == chat.samplerPresetId }) ?? .balanced
        let ctx = effectiveContext

        // Run retrieval first (no-op if disabled or no chunks indexed yet),
        // then assemble the prompt with the retrieval block included.
        let storeChunks = RetrievalEngine.shared.store(for: chat.id).chunks.count
        DebugLog.shared.write("""
            stream-start: retrieval.enabled=\(settings.retrieval.enabled) \
            store.chunks=\(storeChunks) isIndexing=\(isIndexing) \
            embeddingModel=\(embeddingModel ?? "?") embeddingDim=\(embeddingDim.map(String.init) ?? "?") \
            chat.turns=\(chat.turns.count) summarizedThrough=\(chat.summarizedThrough) \
            summary.chars=\(chat.summary.count) memory.chars=\(chat.memory.count)
            """)
        let retrieveStart = Date()
        if settings.retrieval.enabled {
            isRetrieving = true
            retrievingStart = retrieveStart
            NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
        }
        RetrievalEngine.shared.retrieve(
            chat: chat,
            kobold: kobold,
            settings: settings.retrieval
        ) { [weak self] hits in
            guard let self = self else { return }
            self.isRetrieving = false
            self.retrievingStart = nil
            self.lastRetrievalHits = hits
            let block = PromptBuilder.formatRelevantMemories(hits)
            let dt = Date().timeIntervalSince(retrieveStart)
            let scoreList = hits.prefix(5)
                .map { String(format: "%.3f", $0.score) }
                .joined(separator: ",")
            DebugLog.shared.write("""
                retrieval: enabled=\(self.settings.retrieval.enabled) \
                hits=\(hits.count) scores=[\(scoreList)] \
                blockChars=\(block?.count ?? 0) injected=\(block != nil ? "yes" : "no") \
                topK=\(self.settings.retrieval.topK) threshold=\(self.settings.retrieval.threshold) \
                recencyExclude=\(self.settings.retrieval.recencyExclusion) \
                tookMs=\(Int(dt * 1000))
                """)
            self.assembleAndStream(chat: chat, ctx: ctx, preset: preset, relevantMemories: block, continuation: continuation)
        }
    }

    private func assembleAndStream(chat: Chat, ctx: Int, preset: SamplerPreset, relevantMemories: String?, continuation: Bool = false) {
        let replyMax = settings.replyTokensOverride > 0 ? settings.replyTokensOverride : preset.maxLength
        TokenBudget.assemble(
            chat: chat,
            effectiveCtx: ctx,
            replyReserve: replyMax,
            relevantMemories: relevantMemories,
            continuation: continuation,
            userName: settings.userName,
            qwenThinking: settings.qwenThinkingEnabled,
            kobold: kobold
        ) { [weak self] assembly in
            guard let self = self else { return }
            self.lastUsage = assembly.usage
            self.lastTruncatedCount = assembly.truncatedTurns
            // Tally the prompt cost against the chat. Done at send time so
            // regens and continuations count the same as the initial send —
            // they all eat compute. The reply side is incremented later from
            // kobold's perf endpoint at stream finish.
            let chatIdForTally = chat.id
            let promptTokens = assembly.usage.prompt
            self.updateChat(id: chatIdForTally) { c in
                c.tokensSent += promptTokens
            }
            DebugLog.shared.write("""
                send: turns=\(chat.turns.count) summarizedThrough=\(chat.summarizedThrough) \
                truncated=\(assembly.truncatedTurns) usage=\(assembly.usage.prompt)/\(ctx)tok \
                AN.depth=\(chat.authorsNote.depth) AN.text=\(chat.authorsNote.text.isEmpty ? "no" : "yes(\(chat.authorsNote.text.count)c)") \
                memory=\(chat.memory.count)c summary=\(chat.summary.count)c
                """)
            self.lastCacheRatio = self.computeCacheRatio(newPrompt: assembly.prompt)
            self.lastSentPrompt = assembly.prompt
            NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)

            let req = GenerateRequest(
                prompt: assembly.prompt,
                stopSequences: assembly.stops,
                preset: preset,
                maxContextLength: ctx,
                maxLengthOverride: self.settings.replyTokensOverride > 0 ? self.settings.replyTokensOverride : nil
            )

            self.kobold.generateStream(
                request: req,
                onToken: { [weak self] tok in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        if self.firstTokenAt == nil, let start = self.streamStart {
                            self.firstTokenAt = Date()
                            self.lastTTFT = Date().timeIntervalSince(start)
                        }
                        self.streamTokens += 1
                        self.appendStreamToken(tok)
                    }
                },
                onFinish: { [weak self] err in
                    guard let self = self else { return }
                    DispatchQueue.main.async {
                        self.isStreaming = false
                        // Drain any residue the think-filter was holding onto
                        // (rare — only if the stream ended mid-buffer or the
                        // model produced an unterminated <think>). Goes through
                        // the same append path so observers see it.
                        if var filter = self.streamThinkFilter {
                            let tail = filter.flush()
                            self.streamThinkFilter = nil
                            self.isThinking = false
                            if !tail.isEmpty,
                               let id = self.currentChatId,
                               let idx = self.chats.firstIndex(where: { $0.id == id }),
                               let lastIdx = self.chats[idx].turns.indices.last,
                               self.chats[idx].turns[lastIdx].role == .assistant {
                                self.chats[idx].turns[lastIdx].appendToActiveVariant(tail)
                                NotificationCenter.default.post(
                                    name: AppNotification.streamTokenAppended, object: tail
                                )
                            }
                        }
                        // Stream-level network error fast-paths the offline alert
                        // without waiting for the next 30s health tick.
                        if let nsErr = err as NSError?, Self.isTransportError(nsErr) {
                            self.markServerReachable(false, error: nsErr.localizedDescription)
                        } else if err == nil {
                            self.markServerReachable(true)
                        }
                        if let firstAt = self.firstTokenAt {
                            let dt = Date().timeIntervalSince(firstAt)
                            if dt > 0 {
                                self.lastTokensPerSec = Double(self.streamTokens) / dt
                            }
                        }
                        // Fetch per-request prompt-processing time from kobold.
                        self.kobold.fetchPerf { [weak self] result in
                            DispatchQueue.main.async {
                                guard let self = self,
                                      case .success(let dict) = result else { return }
                                if let v = (dict["last_process"] as? NSNumber)?.doubleValue {
                                    self.lastPromptProcessTime = v
                                }
                                let lastEval = (dict["last_eval"] as? NSNumber)?.doubleValue ?? 0
                                let lastTokens = (dict["last_token_count"] as? NSNumber)?.intValue ?? 0
                                // Tally reply tokens against the chat that
                                // just finished streaming. Done here (not in
                                // the stream-finish handler) because perf is
                                // the authoritative count from the server,
                                // and `streamTokens` is a chunk-count
                                // approximation. If perf fails we lose this
                                // stream's reply-side number — acceptable
                                // tradeoff vs. double-counting on retry.
                                if lastTokens > 0, let id = self.currentChatId {
                                    self.updateChat(id: id) { c in
                                        c.tokensReceived += lastTokens
                                    }
                                }
                                DebugLog.shared.write("""
                                    perf: ttft=\(self.lastTTFT.map { String(format: "%.2fs", $0) } ?? "?") \
                                    process=\(String(format: "%.2fs", self.lastPromptProcessTime ?? 0)) \
                                    eval=\(String(format: "%.2fs", lastEval)) \
                                    tokens=\(lastTokens) tps=\(String(format: "%.1f", self.lastTokensPerSec))
                                    """)
                                NotificationCenter.default.post(
                                    name: AppNotification.statusChanged, object: nil
                                )
                            }
                        }
                        NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
                        NotificationCenter.default.post(
                            name: AppNotification.streamFinished, object: err
                        )
                        self.scheduleUsageRecompute()
                        self.maybeAutoSummarize()
                        self.kickIndexing()
                        if self.streamIsFreshUserTurn {
                            self.reinforceEntitiesForLatestTurn()
                            self.maybeAutoExtract()
                        }
                        self.streamIsFreshUserTurn = false
                    }
                }
            )
        }
    }

    func kickIndexing() {
        guard settings.retrieval.enabled, !isIndexing, let chat = currentChat else { return }
        isIndexing = true
        indexingStart = Date()
        lastIndexError = nil
        NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
        DebugLog.shared.write("retrieval: indexing chat=\(chat.id) turns=\(chat.turns.count)")
        RetrievalEngine.shared.index(
            chat: chat,
            kobold: kobold,
            contextual: settings.retrieval.contextual,
            effectiveCtx: effectiveContext
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isIndexing = false
                self.indexingStart = nil
                switch result {
                case .success(let n):
                    DebugLog.shared.write("retrieval: indexed +\(n) chunks (total store size=\(RetrievalEngine.shared.store(for: chat.id).chunks.count))")
                case .failure(let e):
                    self.lastIndexError = "\(e)"
                    DebugLog.shared.write("retrieval: index failed — \(e)")
                }
                NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
            }
        }
    }

    /// Longest common prefix of last sent prompt and the new one, as a fraction
    /// of the new prompt's length. A proxy for KV-cache hit potential — if it's
    /// near 1.0 we expect the prefill to be nearly free (Context Shifting/SmartCache).
    private func computeCacheRatio(newPrompt: String) -> Double {
        guard let prev = lastSentPrompt, !prev.isEmpty, !newPrompt.isEmpty else {
            DebugLog.shared.write("cache: no previous prompt (first send) · new=\(newPrompt.count)B")
            return 0
        }
        let a = Array(prev.utf8)
        let b = Array(newPrompt.utf8)
        var i = 0
        let limit = min(a.count, b.count)
        while i < limit && a[i] == b[i] { i += 1 }
        let ratio = Double(i) / Double(b.count)

        // Show what diverges. Print 60 bytes before the split and 120 after, on each side.
        let pre = max(0, i - 60)
        let postNew = min(b.count, i + 120)
        let postOld = min(a.count, i + 120)
        let context = String(decoding: b[pre..<i], as: UTF8.self)
        let oldTail = String(decoding: a[i..<postOld], as: UTF8.self)
        let newTail = String(decoding: b[i..<postNew], as: UTF8.self)
        DebugLog.shared.write("""
            cache: prev=\(a.count)B  new=\(b.count)B  match=\(i)B  ratio=\(String(format: "%.1f%%", ratio * 100))
              context before split: \(escape(context))
              old tail @\(i):       \(escape(oldTail))
              new tail @\(i):       \(escape(newTail))
            """)
        return ratio
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\n", with: "\\n")
    }

    // MARK: - Usage recompute (status-bar ctx fill bar)

    private var usageRecomputeWork: DispatchWorkItem?

    func scheduleUsageRecompute() {
        usageRecomputeWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.recomputeUsage() }
        usageRecomputeWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    private func recomputeUsage() {
        guard !isStreaming, let chat = currentChat else { return }
        let preset = SamplerPreset.presets.first(where: { $0.id == chat.samplerPresetId }) ?? .balanced
        let ctx = effectiveContext
        TokenBudget.assemble(
            chat: chat,
            effectiveCtx: ctx,
            replyReserve: preset.maxLength,
            qwenThinking: settings.qwenThinkingEnabled,
            kobold: kobold
        ) { [weak self] assembly in
            guard let self = self else { return }
            self.lastUsage = assembly.usage
            self.lastTruncatedCount = assembly.truncatedTurns
            NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
        }
    }

    // MARK: - Summarization

    private func maybeAutoSummarize() {
        guard !isStreaming, !isSummarizing, let chat = currentChat else { return }
        let ctx = effectiveContext
        guard ctx > 0 else { return }
        let trigger = Double(lastUsage.prompt) / Double(ctx)
        guard trigger >= chat.summaryTriggerRatio else { return }
        let unsummarized = chat.turns.count - chat.summarizedThrough
        guard unsummarized >= 6 else { return }
        runSummarizer()
    }

    /// Freeze the live rolling summary into `sceneSummaries` and start a fresh
    /// rolling summary. The next auto-summarize cycle picks up from
    /// `summarizedThrough`, so unsummarized turns aren't lost. No-op if there
    /// is no rolling summary to freeze. See MEMORY_RESEARCH.md §9.2.
    func markSceneBreak() {
        guard !isStreaming, !isSummarizing, let chat = currentChat else { return }
        let trimmed = chat.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        DebugLog.shared.write("scene-break: freezing summary (\(trimmed.count)c) → sceneSummaries[\(chat.sceneSummaries.count)]")
        updateCurrent { c in
            // Markers cover the same range the rolling summary covered:
            // [previous-scene.lastTurn + 1 .. summarizedThrough - 1] inclusive.
            // summarizedThrough is exclusive (first not-yet-summarised turn),
            // so subtract 1 for the inclusive lastTurn.
            let prevLast = c.sceneSummaries.last?.lastTurn ?? -1
            let firstTurn = max(0, prevLast + 1)
            let lastTurn = max(firstTurn, c.summarizedThrough - 1)
            c.sceneSummaries.append(SceneSummary(
                text: trimmed,
                firstTurn: firstTurn,
                lastTurn: lastTurn
            ))
            c.summary = ""
        }
        // Scene break = explicit "this matters, capture state now" signal.
        // Force-fire the extractor regardless of cadence.
        maybeAutoExtract(force: true)
    }

    func runSummarizer() {
        guard !isStreaming, !isSummarizing, let chat = currentChat else { return }
        isSummarizing = true
        summarizingStart = Date()
        lastSummarizerError = nil
        DebugLog.shared.write("summarizer: invoked on chat=\(chat.id) turns=\(chat.turns.count) summarizedThrough=\(chat.summarizedThrough)")
        NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)

        let chatId = chat.id
        Summarizer.run(
            chat: chat,
            kobold: kobold,
            effectiveCtx: effectiveContext
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isSummarizing = false
                self.summarizingStart = nil
                switch result {
                case .success(let r):
                    let trimmed = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.count < 20 {
                        // Reject: side-call returned nothing usable. Don't advance summarizedThrough
                        // — that would silently strip turns from the prompt.
                        DebugLog.shared.write("summarizer: REJECTED empty/too-short summary (\(trimmed.count)c). summarizedThrough NOT advanced.")
                        self.lastSummarizerError = "empty summary returned (model emitted only thinking?)"
                    } else {
                        DebugLog.shared.write("summarizer: applied summary=\(trimmed.count)c summarizedThrough=\(r.summarizedThrough)")
                        self.updateChat(id: chatId) { c in
                            c.summary = trimmed
                            c.summarizedThrough = r.summarizedThrough
                        }
                        self.scheduleUsageRecompute()
                    }
                case .failure(let e):
                    DebugLog.shared.write("summarizer: failed — \(e)")
                    self.lastSummarizerError = "\(e)"
                }
                NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
            }
        }
    }

    private func appendStreamToken(_ tok: String) {
        guard let id = currentChatId,
              let idx = chats.firstIndex(where: { $0.id == id }) else { return }
        guard let lastIdx = chats[idx].turns.indices.last,
              chats[idx].turns[lastIdx].role == .assistant else { return }
        // For Qwen3 thinking mode, route every chunk through the filter so
        // the reasoning trace never reaches turn.text (and therefore never
        // reaches the chunker, summarizer, or retrieval embeddings).
        let displayed: String
        if streamThinkFilter != nil {
            displayed = streamThinkFilter!.ingest(tok)
            // Sync the public thinking flag *after* ingest so the UI sees
            // the transition in/out of the block as it happens.
            isThinking = streamThinkFilter?.isInsideThinkBlock ?? false
            if displayed.isEmpty { return }
        } else {
            displayed = tok
        }
        // Route through the variant helper so the seed variant is created
        // on the first token of a fresh assistant turn (sendUserMessage and
        // regenerate both leave the trailing turn with `variants = []`),
        // and so subsequent tokens accumulate on the *active* variant rather
        // than the now-stale `text` mirror.
        chats[idx].turns[lastIdx].appendToActiveVariant(displayed)
        // Don't save on every token; save on finish via finish handler.
        NotificationCenter.default.post(
            name: AppNotification.streamTokenAppended, object: displayed
        )
    }

    // Save chat on stream finish
    func persistCurrent() {
        guard let c = currentChat else { return }
        Storage.shared.saveChat(c)
    }

    // MARK: - Salience reinforcement (Step D)

    /// Bump `lastReinforcedTurn` and `mentionCount` for every fact whose
    /// parent entity is mentioned in the latest user→assistant exchange.
    /// Gated by `streamIsFreshUserTurn` so regen/continue don't double-count.
    /// Uses the same case-insensitive name+alias substring match as
    /// `PromptBuilder.entitiesBlock` (via `Entity.mentioned(in:)`).
    private func reinforceEntitiesForLatestTurn() {
        guard let chat = currentChat else { return }
        // Scan the latest user turn plus the just-finished assistant turn —
        // i.e. one exchange. Matches the unit the cadence pointer uses.
        let recent = chat.turns.suffix(2)
        let lower = recent.map { $0.text }.joined(separator: "\n").lowercased()
        guard !lower.isEmpty else { return }
        let userTurnsNow = chat.turns.filter { $0.role == .user }.count
        var bumped = 0
        updateChat(id: chat.id) { c in
            for i in c.entities.indices where c.entities[i].mentioned(in: lower) {
                bumped += 1
                for j in c.entities[i].facts.indices {
                    c.entities[i].facts[j].lastReinforcedTurn = userTurnsNow
                    c.entities[i].facts[j].mentionCount += 1
                }
            }
        }
        if bumped > 0 {
            DebugLog.shared.write("salience: reinforced \(bumped) entit\(bumped == 1 ? "y" : "ies") @ userTurn=\(userTurnsNow)")
        }
    }

    // MARK: - Auto fact extraction (Step B)

    /// Hard ceiling on the pending suggestions queue. Prevents the queue from
    /// growing unbounded if the user lets auto-extraction run for hundreds of
    /// turns without reviewing. When at the cap, oldest suggestions evict.
    private let pendingSuggestionsCap = 50

    /// Run the §9.3 fact extractor in the background if cadence + state allow.
    /// Force=true skips the cadence check (used by scene-break).
    func maybeAutoExtract(force: Bool = false) {
        guard settings.factExtractionEnabled else { return }
        guard !isStreaming, !isSummarizing, !isExtracting, !isRetrieving else {
            // Avoid double-loading the model. The next stream-finish or
            // scene-break will re-attempt.
            return
        }
        guard let chat = currentChat else { return }
        guard chat.turns.count >= 2 else { return }
        if !force {
            let cadence = max(1, settings.factExtractionEveryNTurns)
            // Cadence is in user turns, not total turns — one user→assistant
            // exchange counts as 1, not 2. Clamp lastExtractedTurn to handle
            // pre-fix chats where it was stored as a total-turn count.
            let userTurnsNow = chat.turns.filter { $0.role == .user }.count
            let lastSeen = min(chat.lastExtractedTurn, userTurnsNow)
            let unseen = userTurnsNow - lastSeen
            guard unseen >= cadence else { return }
        }
        runExtractor()
    }

    private func runExtractor() {
        guard !isStreaming, !isSummarizing, !isExtracting, let chat = currentChat else { return }
        isExtracting = true
        extractingStart = Date()
        lastExtractError = nil
        let chatId = chat.id
        let turnSnapshot = chat.turns.filter { $0.role == .user }.count
        let scanWindow: Int = {
            if chat.factExtractionScanTurns > 0 {
                return chat.factExtractionScanTurns
            }
            // Auto: cover the unseen user turns since the last extract plus a
            // little overlap so the model can re-anchor what it already saw.
            // All counts are in user turns (= cycles) — same unit as the
            // cadence setting, so users see one consistent number.
            let userTurnsNow = chat.turns.filter { $0.role == .user }.count
            let unseen = max(0, userTurnsNow - chat.lastExtractedTurn)
            return max(4, unseen + 2)
        }()
        DebugLog.shared.write("extractor(auto): chat=\(chatId) turns=\(chat.turns.count) lastExtracted=\(chat.lastExtractedTurn) scanWindow=\(scanWindow)")
        NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)

        FactExtractor.run(
            chat: chat,
            kobold: kobold,
            effectiveCtx: effectiveContext,
            lastN: scanWindow
        ) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.isExtracting = false
                self.extractingStart = nil
                switch result {
                case .failure(let err):
                    self.lastExtractError = "\(err)"
                    DebugLog.shared.write("extractor(auto): failed — \(err)")
                case .success(let r):
                    DebugLog.shared.write("extractor(auto): \(r.facts.count) facts · \(r.validJSON ? "ok" : "PARSE ERROR") · \(r.latencyMs)ms · scanned \(r.turnsScanned) turns")
                    let added = self.addSuggestions(r.facts, toChat: chatId, atTurnSnapshot: turnSnapshot)
                    DebugLog.shared.write("extractor(auto): queued \(added) new suggestion(s)")
                }
                // Always advance the cadence pointer — even on failure or
                // empty result, so we don't busy-loop on the same window.
                self.updateChat(id: chatId) { c in
                    c.lastExtractedTurn = turnSnapshot
                }
                NotificationCenter.default.post(name: AppNotification.statusChanged, object: nil)
            }
        }
    }

    // MARK: - Fact suggestions (Step A)

    /// Append extracted facts to the current chat's pending suggestions queue.
    /// Dedupes against pending suggestions AND against pinned memory lines so
    /// re-running the extractor doesn't resurface a fact the user already
    /// promoted. Dismissed suggestions are intentionally not tracked — the user
    /// said no, but a later re-emission with new context might still be worth
    /// reviewing. Returns the number of suggestions actually added.
    @discardableResult
    func addSuggestions(_ facts: [ExtractedFact]) -> Int {
        guard let id = currentChatId else { return 0 }
        return addSuggestions(facts, toChat: id, atTurnSnapshot: nil)
    }

    /// Targeted variant used by auto-extraction so the result lands on the chat
    /// that was extracted *from*, even if the user has since switched chats.
    /// `turnSnapshot` records the turn count at extract-time as
    /// `FactSuggestion.createdTurn`; pass nil to use the chat's current count.
    @discardableResult
    func addSuggestions(_ facts: [ExtractedFact], toChat chatId: UUID, atTurnSnapshot turnSnapshot: Int?) -> Int {
        guard !facts.isEmpty,
              let idx = chats.firstIndex(where: { $0.id == chatId }) else { return 0 }
        let chat = chats[idx]
        let createdTurn = turnSnapshot ?? chat.turns.count
        var existing = Set(chat.pendingFactSuggestions.map { "\($0.category)|\($0.fact)" })
        let memoryLines = chat.memory
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // Entity-store dedup: a fact already promoted into an entity should
        // not resurface as a suggestion. Compare on (lowercased name, exact
        // fact text). Names compared case-insensitively so "Sage" doesn't
        // re-emit when the entity is "sage".
        var entityFactSet = Set<String>()
        for ent in chat.entities {
            let nameKey = ent.name.lowercased()
            for f in ent.facts {
                entityFactSet.insert("\(nameKey)|\(f.text)")
            }
        }
        var added = 0
        var fresh: [FactSuggestion] = []
        for f in facts {
            let factText = "\(f.entityName) — \(f.fact)"
            let key = "\(f.entityType)|\(factText)"
            if existing.contains(key) { continue }
            let asMemoryLine = "[\(f.entityType)] \(factText)"
            if memoryLines.contains(asMemoryLine) { continue }
            let entityKey = "\(f.entityName.lowercased())|\(f.fact)"
            if entityFactSet.contains(entityKey) { continue }
            fresh.append(FactSuggestion(
                category: f.entityType,
                fact: factText,
                createdTurn: createdTurn
            ))
            existing.insert(key)
            added += 1
        }
        guard added > 0 else { return 0 }
        let toAppend = fresh
        let cap = pendingSuggestionsCap
        updateChat(id: chatId) { c in
            c.pendingFactSuggestions.append(contentsOf: toAppend)
            if c.pendingFactSuggestions.count > cap {
                let overflow = c.pendingFactSuggestions.count - cap
                c.pendingFactSuggestions.removeFirst(overflow)
            }
        }
        return added
    }

    /// Promote a suggestion into the structured entity store and remove it
    /// from the queue. Routing rules:
    ///   • An existing entity whose name OR alias matches the suggestion's
    ///     parsed name (case-insensitive) gets the new fact appended.
    ///   • Otherwise a new entity is created with the suggestion's category
    ///     as type and the parsed name as canonical name.
    /// Naive de-dup: skip if an entity already carries this exact fact text.
    func acceptSuggestion(id: UUID) {
        guard let chat = currentChat,
              let s = chat.pendingFactSuggestions.first(where: { $0.id == id }) else { return }
        let parsed = parseSuggestionFact(s.fact)
        let type = EntityType(rawValue: s.category.lowercased()) ?? .event
        let userTurnsNow = chat.turns.filter { $0.role == .user }.count

        updateChat(id: chat.id) { c in
            let nameLower = parsed.name.lowercased()
            let matchIdx = c.entities.firstIndex { ent in
                if ent.name.lowercased() == nameLower { return true }
                return ent.aliases.contains { $0.lowercased() == nameLower }
            }
            let factText = parsed.fact
            if let idx = matchIdx {
                let alreadyHas = c.entities[idx].facts.contains { $0.text == factText }
                if !alreadyHas {
                    c.entities[idx].facts.append(Fact(
                        text: factText,
                        addedTurn: userTurnsNow,
                        lastReinforcedTurn: userTurnsNow
                    ))
                }
            } else {
                c.entities.append(Entity(
                    name: parsed.name,
                    type: type,
                    facts: [Fact(
                        text: factText,
                        addedTurn: userTurnsNow,
                        lastReinforcedTurn: userTurnsNow
                    )],
                    pinnedByUser: false,
                    createdTurn: userTurnsNow
                ))
            }
            c.pendingFactSuggestions.removeAll(where: { $0.id == id })
        }
    }

    /// Split a suggestion's `fact` field (formatted as `<name> — <text>` by
    /// `addSuggestions`) back into the entity name and fact body. Falls back
    /// to using the whole string as the fact text if the separator is missing
    /// (which it should never be for well-formed suggestions, but it's cheap
    /// to be defensive).
    private func parseSuggestionFact(_ raw: String) -> (name: String, fact: String) {
        if let r = raw.range(of: " — ") {
            let name = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let body = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? "Unknown" : name, body.isEmpty ? raw : body)
        }
        if let r = raw.range(of: " - ") {
            let name = String(raw[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            let body = String(raw[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            return (name.isEmpty ? "Unknown" : name, body.isEmpty ? raw : body)
        }
        return ("Unknown", raw)
    }

    /// Drop a suggestion without writing it anywhere.
    func dismissSuggestion(id: UUID) {
        guard let chat = currentChat else { return }
        guard chat.pendingFactSuggestions.contains(where: { $0.id == id }) else { return }
        updateChat(id: chat.id) { c in
            c.pendingFactSuggestions.removeAll(where: { $0.id == id })
        }
    }
}
