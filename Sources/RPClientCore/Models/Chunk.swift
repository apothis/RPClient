import Foundation

/// A unit of chat history that can be embedded and retrieved as a "memory."
///
/// Phase 7 §3.2.B — Chunks are tree-aware. Canonical range markers are
/// `firstTurnId`/`lastTurnId` (UUID) so a chunk indexed against branch A
/// doesn't collide with one indexed against branch B at the same Int
/// positions. The Int positions (`firstTurnIdx`/`lastTurnIdx`) stay
/// populated for legacy decode tolerance and for callers that render the
/// range as "turns N–M". Chunk `id` is UUID-based when emitted by Chunker;
/// legacy chunks loaded from disk retain their Int-based id and get
/// dropped naturally on the next index pass (their id won't match the
/// UUID-based ids Chunker produces).
struct Chunk: Codable, Equatable {
    /// Stable id derived from the chat + range. UUID-based for Phase 7+
    /// chunks (`{chatId}-{firstTurnId}-{lastTurnId}`); Int-based for legacy
    /// chunks (`{chatId}-{firstTurnIdx}-{lastTurnIdx}`).
    let id: String
    let chatId: UUID
    /// Phase 7 §3.2.B — canonical inclusive turn-id range. nil on legacy
    /// chunks loaded from disk; populated on all Chunker-emitted chunks.
    let firstTurnId: UUID?
    let lastTurnId: UUID?
    /// Inclusive Int positions, kept for rendering the range as "turns
    /// N–M" without needing chat access at every render call site.
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

    /// Phase 7+ initializer — UUID-keyed. Populates both UUID and Int
    /// fields; derives id from UUIDs.
    init(chatId: UUID, firstTurnId: UUID, lastTurnId: UUID, firstTurnIdx: Int, lastTurnIdx: Int, text: String) {
        self.chatId = chatId
        self.firstTurnId = firstTurnId
        self.lastTurnId = lastTurnId
        self.firstTurnIdx = firstTurnIdx
        self.lastTurnIdx = lastTurnIdx
        self.text = text
        self.embedding = nil
        self.embeddedAt = nil
        self.contextBlurb = nil
        self.id = "\(chatId.uuidString)-\(firstTurnId.uuidString)-\(lastTurnId.uuidString)"
    }

    /// Legacy initializer — Int-keyed. Used by tests and as the decode
    /// fallback for pre-Phase-7 chunks. UUID fields stay nil; id derives
    /// from Ints.
    init(chatId: UUID, firstTurnIdx: Int, lastTurnIdx: Int, text: String) {
        self.chatId = chatId
        self.firstTurnId = nil
        self.lastTurnId = nil
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
