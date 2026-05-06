import Foundation

/// A frozen rolling-summary snapshot covering a completed prior arc of the
/// chat. Phase 7 §3.2 — `firstTurnId`/`lastTurnId` (UUID-based) are the
/// canonical range markers; pre-Phase-7 chats stored Int positions in
/// `firstTurn`/`lastTurn`, which decode tolerates and `Chat.init(from:)`
/// resolves to UUIDs against the spine activePath. New writes set only the
/// UUID fields.
///
/// Use `firstTurnPosition(in:)` / `lastTurnPosition(in:)` (extension below)
/// when you need a rendered position — they prefer UUID resolution against
/// the chat's current `activePath` (so branch switches give per-branch
/// positions) and fall back to the legacy Int snapshot when UUID is
/// unavailable or off-path.
///
/// Legacy chats stored these as bare `[String]`. `Chat.init(from:)`
/// tolerates both shapes: a string is taken as `text` with all positions nil.
struct SceneSummary: Codable, Equatable {
    var text: String

    /// Phase 7 §3.2 — canonical inclusive turn-ID range. Resolved against
    /// the active path at read time via `firstTurnPosition(in:)`.
    var firstTurnId: UUID?
    var lastTurnId: UUID?

    /// Pre-Phase-7 inclusive Int positions. Decoded if present (legacy
    /// chats); resolved to UUIDs by `Chat.init(from:)`'s post-pass and
    /// preserved for backward compat with any reader that hasn't been
    /// migrated yet. New writes leave these nil.
    var firstTurn: Int?
    var lastTurn: Int?

    /// Phase 7+ initializer — UUID-only.
    init(text: String, firstTurnId: UUID? = nil, lastTurnId: UUID? = nil) {
        self.text = text
        self.firstTurnId = firstTurnId
        self.lastTurnId = lastTurnId
        self.firstTurn = nil
        self.lastTurn = nil
    }

    /// Legacy initializer — Int positions only. Kept for the AppState
    /// scene-break write path during the Phase 7 transition window and for
    /// existing tests that construct SceneSummaries with Int positions.
    init(text: String, firstTurn: Int?, lastTurn: Int?) {
        self.text = text
        self.firstTurnId = nil
        self.lastTurnId = nil
        self.firstTurn = firstTurn
        self.lastTurn = lastTurn
    }
}

extension SceneSummary {
    /// Position of `firstTurnId` along the chat's active path. Falls back to
    /// the legacy `firstTurn` Int when the UUID is nil or doesn't resolve
    /// (e.g., the scene was indexed against a different branch). Returns nil
    /// when neither yields a value — caller should treat as "this scene
    /// doesn't apply to the current branch and shouldn't be rendered."
    func firstTurnPosition(in chat: Chat) -> Int? {
        if let id = firstTurnId, let pos = chat.activePosition(of: id) {
            return pos
        }
        return firstTurn
    }

    /// Same as `firstTurnPosition(in:)` but for the inclusive last turn.
    func lastTurnPosition(in chat: Chat) -> Int? {
        if let id = lastTurnId, let pos = chat.activePosition(of: id) {
            return pos
        }
        return lastTurn
    }
}
