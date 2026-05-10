import Foundation

/// Reusable priority-topic preset, available across chats. The user maintains
/// the library in global Settings; per-chat topic lists are populated by
/// *copying* from the library, so subsequent library edits don't surprise an
/// active chat. See MEMORY_V2_PLAN.md Step B follow-up.
struct LibraryTopic: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String

    init(id: UUID = UUID(), text: String) {
        self.id = id
        self.text = text
    }
}

struct Settings: Codable, Equatable {
    var servers: [ServerProfile]
    var defaultServerId: UUID
    var summarizerServerId: UUID?
    var extractorServerId: UUID?
    var embeddingsServerId: UUID?
    /// User-chosen display name. When non-empty, prepended to the memory block
    /// as "The user's name is {name}." so the model can address them by name.
    /// Empty string disables the injection.
    var userName: String
    var defaultTemplateId: String
    var defaultSamplerPresetId: String
    /// Subsystem gate for the TTS pipeline (Phase 6 §7.1f). When false, no
    /// engine init, no model download prompts; the chat-header runtime toggle
    /// is forced disabled. The Settings checkbox is labelled "Enable voice
    /// subsystem".
    var voiceEnabled: Bool
    /// Runtime toggle, distinct from the subsystem gate. Lives on the chat
    /// header and is the cheap mute the user reaches for per-turn. Speech
    /// only synthesises when `voiceEnabled && voiceActive`.
    var voiceActive: Bool
    /// 0 means "use whatever the server reports as true_max_context_length".
    /// Anything > 0 caps the effective context below that.
    var maxContextOverride: Int
    var retrieval: RetrievalSettings
    /// Override for the per-reply token cap. 0 = use the sampler preset's value.
    /// Larger values let replies run longer but eat into prompt budget (the
    /// reserve subtracts from effective context).
    var replyTokensOverride: Int
    /// Auto-fire the §9.3 fact extractor every N user turns (post-stream) and
    /// after scene breaks. Suggestions land silently in the inspector pane.
    var factExtractionEnabled: Bool
    /// Cadence for auto-extraction. Counted in user turns since the last
    /// extraction window. Lower = fresher suggestions, more side-call cost.
    var factExtractionEveryNTurns: Int
    /// Reusable priority-topic presets surfaced in the per-chat extraction
    /// pane via "Add from library". Editing the library does not retroactively
    /// modify any chat's active topics.
    var priorityTopicLibrary: [LibraryTopic]
    /// When true and the active chat uses the Qwen template, the assistant
    /// generation marker is left bare so the model produces its own
    /// `<think>…</think>` reasoning trace. The trace is stripped from the
    /// streamed reply before it reaches `turn.text` (so retrieval, summary,
    /// and the chunker never see it). When false, an empty `<think></think>`
    /// pre-fill suppresses thinking — that's the Qwen3 non-thinking pattern.
    var qwenThinkingEnabled: Bool
    /// Default persona id picked up by `newChat` when a chat is created
    /// without an explicit persona. Nil = anonymous (the prompt builder will
    /// fall back to `userName` as before). The library window owns assignment
    /// of this — Settings just remembers the pointer.
    var defaultPersonaId: UUID?
    /// Filesystem location for downloaded TTS voice models (Phase 6 §7.1).
    /// Nil = unset; the first-run prompt fires when the user enables Speak
    /// replies, picks an external volume if mounted, and persists the choice
    /// here. AVKit fallback runs whenever this is nil or the volume isn't
    /// available.
    var voiceModelPath: String?
    /// Global default narrator voice (Phase 6 §7.2c). Bottom of the two-tier
    /// fallback chain — `Entity.voice ?? Chat.voice ?? Settings.defaultVoice`.
    /// Nil means "no global default set yet"; the speaker layer falls
    /// through to whatever the §7.1l selector picks.
    var defaultVoice: VoicePreference?

    /// Server preference for the Card Creator window's AI-assist side-calls
    /// (Phase 9 §3.1). Defaults to the active chat's server, then to
    /// `defaultServerId`. Persisted so the creator opens with the same
    /// choice next time. Routed separately from `.summarizer` because card
    /// generation produces prose that small SFW-tuned summarizer models
    /// will sanitize or refuse — see Phase 9 §4.4.
    var cardCreatorServerId: UUID?

    /// User-accumulated tag vocabulary surfaced by the Card Creator's tag
    /// autocomplete in addition to the bundled hand-curated common-set
    /// (Phase 9 §3.8). New tags committed by the author get appended here
    /// when novel; the autocomplete queries the union via
    /// `TagVocabulary.matches(prefix:customTags:)`.
    var customTags: [String]

    /// Free-form style guidance appended to every chat's system block
    /// (after the character's `systemPrompt`, before the `userName`
    /// line). Lets the user nudge global behaviour — reply length,
    /// register, content-policy preferences — without editing every
    /// card individually. `{{user}}` and `{{char}}` substitution
    /// applies. Empty string disables injection. Default ships
    /// non-empty (paragraph-count + intimate-description guidance)
    /// based on user feedback 2026-05-09; the user can clear or
    /// rewrite via Settings UI.
    var systemPromptAddendum: String

    /// Temporary façade preserving the pre-Phase-4 single-server API. Reads
    /// the default profile's baseURL; setter mutates the default profile's
    /// URL in place. Removed in 4b once AppState routes through the registry.
    var serverURL: String {
        get { defaultServer?.baseURL.absoluteString ?? "http://localhost:5001" }
        set {
            guard let url = URL(string: newValue),
                  let idx = servers.firstIndex(where: { $0.id == defaultServerId })
            else { return }
            servers[idx].baseURL = url
        }
    }

    var defaultServer: ServerProfile? {
        servers.first(where: { $0.id == defaultServerId })
    }

    /// Default text for `systemPromptAddendum` — the two pieces of
    /// guidance the user requested 2026-05-09. Conservative wording:
    /// the paragraph target is "roughly four", not strict; the
    /// intimate-detail directive is conditional ("when the scene
    /// calls for it") so SFW chats aren't pushed toward content the
    /// scene doesn't ask for. The user can edit / clear via the
    /// Settings UI.
    static let defaultSystemPromptAddendum = """
    Aim for roughly four paragraphs per reply. Vary the rhythm — fewer when a moment calls for brevity, more when a scene needs space to unfold. Don't pad to hit a target.

    When the scene calls for intimate physical description, be specific and anatomically accurate. Account for the character's age and body type — what's plausible for one body isn't for another. Don't generalise or soften.
    """

    static let `default`: Settings = {
        let defaultId = UUID()
        let defaultProfile = ServerProfile(
            id: defaultId,
            name: "Default",
            baseURL: URL(string: "http://localhost:5001")!
        )
        return Settings(
            servers: [defaultProfile],
            defaultServerId: defaultId,
            userName: "",
            defaultTemplateId: "gemma",
            defaultSamplerPresetId: "balanced",
            voiceEnabled: false,
            voiceActive: true,
            maxContextOverride: 0,
            retrieval: .default,
            replyTokensOverride: 0,
            factExtractionEnabled: true,
            factExtractionEveryNTurns: 4,
            priorityTopicLibrary: [],
            qwenThinkingEnabled: false,
            defaultPersonaId: nil,
            voiceModelPath: nil,
            defaultVoice: nil,
            systemPromptAddendum: Settings.defaultSystemPromptAddendum
        )
    }()

    init(servers: [ServerProfile],
         defaultServerId: UUID,
         summarizerServerId: UUID? = nil,
         extractorServerId: UUID? = nil,
         embeddingsServerId: UUID? = nil,
         userName: String = "",
         defaultTemplateId: String, defaultSamplerPresetId: String,
         voiceEnabled: Bool, voiceActive: Bool = true,
         maxContextOverride: Int, retrieval: RetrievalSettings,
         replyTokensOverride: Int,
         factExtractionEnabled: Bool, factExtractionEveryNTurns: Int,
         priorityTopicLibrary: [LibraryTopic],
         qwenThinkingEnabled: Bool = false,
         defaultPersonaId: UUID? = nil,
         voiceModelPath: String? = nil,
         defaultVoice: VoicePreference? = nil,
         cardCreatorServerId: UUID? = nil,
         customTags: [String] = [],
         systemPromptAddendum: String = Settings.defaultSystemPromptAddendum) {
        self.servers = servers
        self.defaultServerId = defaultServerId
        self.summarizerServerId = summarizerServerId
        self.extractorServerId = extractorServerId
        self.embeddingsServerId = embeddingsServerId
        self.userName = userName
        self.defaultTemplateId = defaultTemplateId
        self.defaultSamplerPresetId = defaultSamplerPresetId
        self.voiceEnabled = voiceEnabled
        self.voiceActive = voiceActive
        self.maxContextOverride = maxContextOverride
        self.retrieval = retrieval
        self.replyTokensOverride = replyTokensOverride
        self.factExtractionEnabled = factExtractionEnabled
        self.factExtractionEveryNTurns = factExtractionEveryNTurns
        self.priorityTopicLibrary = priorityTopicLibrary
        self.qwenThinkingEnabled = qwenThinkingEnabled
        self.defaultPersonaId = defaultPersonaId
        self.voiceModelPath = voiceModelPath
        self.defaultVoice = defaultVoice
        self.cardCreatorServerId = cardCreatorServerId
        self.customTags = customTags
        self.systemPromptAddendum = systemPromptAddendum
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default

        // Migration: pre-Phase-4 settings carry `serverURL: String`. Migrate it
        // into a single ServerProfile named "Default" if no `servers` array.
        if let decoded = try c.decodeIfPresent([ServerProfile].self, forKey: .servers),
           let decodedDefaultId = try c.decodeIfPresent(UUID.self, forKey: .defaultServerId),
           decoded.contains(where: { $0.id == decodedDefaultId }) {
            servers = decoded
            defaultServerId = decodedDefaultId
        } else {
            let legacyURL = (try c.decodeIfPresent(String.self, forKey: .serverURL))
                .flatMap { URL(string: $0) }
                ?? URL(string: "http://localhost:5001")!
            let migrated = ServerProfile(name: "Default", baseURL: legacyURL)
            servers = [migrated]
            defaultServerId = migrated.id
        }

        summarizerServerId = try c.decodeIfPresent(UUID.self, forKey: .summarizerServerId)
        extractorServerId = try c.decodeIfPresent(UUID.self, forKey: .extractorServerId)
        embeddingsServerId = try c.decodeIfPresent(UUID.self, forKey: .embeddingsServerId)

        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        defaultTemplateId = try c.decodeIfPresent(String.self, forKey: .defaultTemplateId) ?? d.defaultTemplateId
        defaultSamplerPresetId = try c.decodeIfPresent(String.self, forKey: .defaultSamplerPresetId) ?? d.defaultSamplerPresetId
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? d.voiceEnabled
        voiceActive = try c.decodeIfPresent(Bool.self, forKey: .voiceActive) ?? d.voiceActive
        maxContextOverride = try c.decodeIfPresent(Int.self, forKey: .maxContextOverride) ?? d.maxContextOverride
        retrieval = try c.decodeIfPresent(RetrievalSettings.self, forKey: .retrieval) ?? d.retrieval
        replyTokensOverride = try c.decodeIfPresent(Int.self, forKey: .replyTokensOverride) ?? d.replyTokensOverride
        factExtractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .factExtractionEnabled) ?? d.factExtractionEnabled
        factExtractionEveryNTurns = try c.decodeIfPresent(Int.self, forKey: .factExtractionEveryNTurns) ?? d.factExtractionEveryNTurns
        priorityTopicLibrary = try c.decodeIfPresent([LibraryTopic].self, forKey: .priorityTopicLibrary) ?? d.priorityTopicLibrary
        qwenThinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .qwenThinkingEnabled) ?? d.qwenThinkingEnabled
        defaultPersonaId = try c.decodeIfPresent(UUID.self, forKey: .defaultPersonaId)
        voiceModelPath = try c.decodeIfPresent(String.self, forKey: .voiceModelPath)
        defaultVoice = try c.decodeIfPresent(VoicePreference.self, forKey: .defaultVoice)
        cardCreatorServerId = try c.decodeIfPresent(UUID.self, forKey: .cardCreatorServerId)
        customTags = try c.decodeIfPresent([String].self, forKey: .customTags) ?? []
        systemPromptAddendum = try c.decodeIfPresent(String.self, forKey: .systemPromptAddendum) ?? d.systemPromptAddendum
    }

    enum CodingKeys: String, CodingKey {
        case servers, defaultServerId
        case summarizerServerId, extractorServerId, embeddingsServerId
        case serverURL  // legacy — migrated on decode, not encoded
        case userName, defaultTemplateId, defaultSamplerPresetId
        case voiceEnabled, voiceActive, maxContextOverride, retrieval
        case replyTokensOverride
        case factExtractionEnabled, factExtractionEveryNTurns
        case priorityTopicLibrary, qwenThinkingEnabled, defaultPersonaId
        case voiceModelPath
        case defaultVoice
        case cardCreatorServerId
        case customTags
        case systemPromptAddendum
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(servers, forKey: .servers)
        try c.encode(defaultServerId, forKey: .defaultServerId)
        try c.encodeIfPresent(summarizerServerId, forKey: .summarizerServerId)
        try c.encodeIfPresent(extractorServerId, forKey: .extractorServerId)
        try c.encodeIfPresent(embeddingsServerId, forKey: .embeddingsServerId)
        try c.encode(userName, forKey: .userName)
        try c.encode(defaultTemplateId, forKey: .defaultTemplateId)
        try c.encode(defaultSamplerPresetId, forKey: .defaultSamplerPresetId)
        try c.encode(voiceEnabled, forKey: .voiceEnabled)
        try c.encode(voiceActive, forKey: .voiceActive)
        try c.encode(maxContextOverride, forKey: .maxContextOverride)
        try c.encode(retrieval, forKey: .retrieval)
        try c.encode(replyTokensOverride, forKey: .replyTokensOverride)
        try c.encode(factExtractionEnabled, forKey: .factExtractionEnabled)
        try c.encode(factExtractionEveryNTurns, forKey: .factExtractionEveryNTurns)
        try c.encode(priorityTopicLibrary, forKey: .priorityTopicLibrary)
        try c.encode(qwenThinkingEnabled, forKey: .qwenThinkingEnabled)
        try c.encodeIfPresent(defaultPersonaId, forKey: .defaultPersonaId)
        try c.encodeIfPresent(voiceModelPath, forKey: .voiceModelPath)
        try c.encodeIfPresent(defaultVoice, forKey: .defaultVoice)
        try c.encodeIfPresent(cardCreatorServerId, forKey: .cardCreatorServerId)
        if !customTags.isEmpty {
            try c.encode(customTags, forKey: .customTags)
        }
        try c.encode(systemPromptAddendum, forKey: .systemPromptAddendum)
    }
}
