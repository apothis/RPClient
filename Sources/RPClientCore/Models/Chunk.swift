import Foundation

/// A unit of chat history that can be embedded and retrieved as a "memory."
/// Chunks are stable: deterministic id from `(chatId, firstTurnIdx, lastTurnIdx)`,
/// content hashed so we can re-embed only when text actually changes.
struct Chunk: Codable, Equatable {
    /// Stable id derived from the chat + range. Lets us update an existing chunk
    /// in place when a turn within it gets edited.
    let id: String
    let chatId: UUID
    let firstTurnIdx: Int
    let lastTurnIdx: Int
    var text: String
    var embedding: [Float]?
    var embeddedAt: Date?
    /// Optional 1–2 sentence "place this snippet in the story" blurb generated
    /// by a side-call before embedding. Following Anthropic's *Contextual
    /// Retrieval* recipe — embedding `blurb + text` instead of `text` alone
    /// makes near-miss chunks distinguishable by their setting/cast/intent,
    /// which Anthropic reports cuts retrieval failures by ~49%. nil on chunks
    /// indexed before the feature shipped or while the feature is disabled.
    var contextBlurb: String?

    init(chatId: UUID, firstTurnIdx: Int, lastTurnIdx: Int, text: String) {
        self.chatId = chatId
        self.firstTurnIdx = firstTurnIdx
        self.lastTurnIdx = lastTurnIdx
        self.text = text
        self.embedding = nil
        self.embeddedAt = nil
        self.contextBlurb = nil
        self.id = "\(chatId.uuidString)-\(firstTurnIdx)-\(lastTurnIdx)"
    }

    var isEmbedded: Bool { embedding != nil }

    /// What we feed to the embedder and inject into the prompt: the blurb
    /// (when present) glued to the chunk text. Falls back to plain `text`
    /// for legacy chunks that haven't been re-indexed under contextual
    /// retrieval.
    var embeddingText: String {
        guard let blurb = contextBlurb?.trimmingCharacters(in: .whitespacesAndNewlines),
              !blurb.isEmpty else { return text }
        return "\(blurb)\n\n\(text)"
    }
}
