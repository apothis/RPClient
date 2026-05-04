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
    var serverURL: String
    /// User-chosen display name. When non-empty, prepended to the memory block
    /// as "The user's name is {name}." so the model can address them by name.
    /// Empty string disables the injection.
    var userName: String
    var defaultTemplateId: String
    var defaultSamplerPresetId: String
    var voiceEnabled: Bool
    /// 0 means "use whatever the server reports as true_max_context_length".
    /// Anything > 0 caps the effective context below that.
    var maxContextOverride: Int
    var retrieval: RetrievalSettings
    /// Offset applied to every UI font's base size. 0 = baseline, +N = larger.
    var uiFontOffset: Int
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

    static let `default` = Settings(
        serverURL: "http://localhost:5001",
        userName: "",
        defaultTemplateId: "gemma",
        defaultSamplerPresetId: "balanced",
        voiceEnabled: false,
        maxContextOverride: 0,
        retrieval: .default,
        uiFontOffset: 1,
        replyTokensOverride: 0,
        factExtractionEnabled: true,
        factExtractionEveryNTurns: 4,
        priorityTopicLibrary: [],
        qwenThinkingEnabled: false
    )

    init(serverURL: String, userName: String = "",
         defaultTemplateId: String, defaultSamplerPresetId: String,
         voiceEnabled: Bool, maxContextOverride: Int, retrieval: RetrievalSettings,
         uiFontOffset: Int, replyTokensOverride: Int,
         factExtractionEnabled: Bool, factExtractionEveryNTurns: Int,
         priorityTopicLibrary: [LibraryTopic],
         qwenThinkingEnabled: Bool = false) {
        self.serverURL = serverURL
        self.userName = userName
        self.defaultTemplateId = defaultTemplateId
        self.defaultSamplerPresetId = defaultSamplerPresetId
        self.voiceEnabled = voiceEnabled
        self.maxContextOverride = maxContextOverride
        self.retrieval = retrieval
        self.uiFontOffset = uiFontOffset
        self.replyTokensOverride = replyTokensOverride
        self.factExtractionEnabled = factExtractionEnabled
        self.factExtractionEveryNTurns = factExtractionEveryNTurns
        self.priorityTopicLibrary = priorityTopicLibrary
        self.qwenThinkingEnabled = qwenThinkingEnabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings.default
        serverURL = try c.decodeIfPresent(String.self, forKey: .serverURL) ?? d.serverURL
        userName = try c.decodeIfPresent(String.self, forKey: .userName) ?? d.userName
        defaultTemplateId = try c.decodeIfPresent(String.self, forKey: .defaultTemplateId) ?? d.defaultTemplateId
        defaultSamplerPresetId = try c.decodeIfPresent(String.self, forKey: .defaultSamplerPresetId) ?? d.defaultSamplerPresetId
        voiceEnabled = try c.decodeIfPresent(Bool.self, forKey: .voiceEnabled) ?? d.voiceEnabled
        maxContextOverride = try c.decodeIfPresent(Int.self, forKey: .maxContextOverride) ?? d.maxContextOverride
        retrieval = try c.decodeIfPresent(RetrievalSettings.self, forKey: .retrieval) ?? d.retrieval
        uiFontOffset = try c.decodeIfPresent(Int.self, forKey: .uiFontOffset) ?? d.uiFontOffset
        replyTokensOverride = try c.decodeIfPresent(Int.self, forKey: .replyTokensOverride) ?? d.replyTokensOverride
        factExtractionEnabled = try c.decodeIfPresent(Bool.self, forKey: .factExtractionEnabled) ?? d.factExtractionEnabled
        factExtractionEveryNTurns = try c.decodeIfPresent(Int.self, forKey: .factExtractionEveryNTurns) ?? d.factExtractionEveryNTurns
        priorityTopicLibrary = try c.decodeIfPresent([LibraryTopic].self, forKey: .priorityTopicLibrary) ?? d.priorityTopicLibrary
        qwenThinkingEnabled = try c.decodeIfPresent(Bool.self, forKey: .qwenThinkingEnabled) ?? d.qwenThinkingEnabled
    }
}
