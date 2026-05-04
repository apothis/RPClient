import Foundation

/// A frozen rolling-summary snapshot covering a completed prior arc of the
/// chat. `firstTurn`/`lastTurn` mark the inclusive turn range it summarises so
/// the prompt builder can frame it as past, decay it once enough verbatim
/// turns have moved past, or attribute facts back to it. See
/// `MEMORY_AUDIT.md` §4.1 (Phase 2, item A).
///
/// Legacy chats stored these as bare `[String]`. Decode tolerates both shapes:
/// a string is taken as `text` with `firstTurn=nil, lastTurn=nil` so absence
/// of a marker is distinguishable from a real `0`.
struct SceneSummary: Codable, Equatable {
    var text: String
    /// Inclusive index of the first turn this scene summarises. `nil` means
    /// the value was lost in legacy `[String]` storage.
    var firstTurn: Int?
    /// Inclusive index of the last turn this scene summarises. `nil` means
    /// the value was lost in legacy `[String]` storage.
    var lastTurn: Int?

    init(text: String, firstTurn: Int? = nil, lastTurn: Int? = nil) {
        self.text = text
        self.firstTurn = firstTurn
        self.lastTurn = lastTurn
    }
}
