import Foundation

/// Carves chat history into rolling windows. Default 4 turns wide, 1 turn
/// overlap (so neighbouring chunks share one turn). Per-turn chunks are too
/// small to retrieve usefully — they match on filler words. Per-scene is too
/// fuzzy without explicit boundaries. 4-with-overlap is the sweet spot per
/// MEMORY_RESEARCH.md §9.1.
///
/// Phase 7 §3.2.B — walks the chat's active path so chunks are scoped to
/// "what's currently visible." Falls back to chat.turns when activePath is
/// empty (in-memory chats that bypassed the decode-time spine migration;
/// production paths get proper activePath maintenance in §3.3).
enum Chunker {
    static let windowSize = 4
    static let stride = 3   // windowSize - overlap(1) = stride

    /// Generates chunks for the given chat. Trailing partial windows are
    /// emitted as long as they cover at least 2 turns.
    static func chunks(for chat: Chat) -> [Chunk] {
        let turns = chat.activePath.isEmpty && !chat.turns.isEmpty
            ? chat.turns
            : chat.activeTurns
        guard turns.count >= 2 else { return [] }
        var out: [Chunk] = []
        var start = 0
        while start < turns.count {
            let end = min(start + windowSize, turns.count)
            if end - start < 2 { break }
            let body = formatTurns(turns[start..<end])
            out.append(Chunk(
                chatId: chat.id,
                firstTurnId: turns[start].id,
                lastTurnId: turns[end - 1].id,
                firstTurnIdx: start,
                lastTurnIdx: end - 1,
                text: body
            ))
            if end == turns.count { break }
            start += stride
        }
        return out
    }

    private static func formatTurns(_ turns: ArraySlice<Turn>) -> String {
        turns.map { t in
            let role = t.role == .user ? "User" : "Assistant"
            return "\(role): \(t.text)"
        }.joined(separator: "\n\n")
    }
}
