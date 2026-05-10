import Foundation
@testable import RPClientCore

/// Phase 7 §3.2.C — `RetrievalEngine.excludePredicate(chat:summarizedThrough:)`
/// is the chat-aware replacement for the legacy
/// `excludePredicate(turnsCount:summarizedThrough:)`. It resolves chunk
/// endpoints via `chat.activePosition(of:)` instead of comparing raw Ints,
/// so chunks indexed against an off-branch turn don't get caught by the
/// recency / verbatim window filter (cross-branch memory is retrievable
/// even when the user is on a different branch).
///
/// Legacy callers (existing tests use the Int signature) are unaffected;
/// the legacy method stays as a thin wrapper around the same math.
func retrievalEngineBranchingTests() -> TestSuite {
    let s = TestSuite("RetrievalEngineBranching")

    // MARK: - Branch-aware predicate

    s.test("chunks within the recency window get excluded based on activePath position") {
        // Build a 10-turn chat (no branching), summarizedThrough=4, recency=3.
        // Chunks with lastPosition >= 7 (10 - 3) get excluded.
        var chat = Chat(title: "Test")
        let ids = (0..<10).map { _ in UUID() }
        chat.turns = ids.enumerated().map { (i, id) in
            var t = Turn(id: id, role: i.isMultiple(of: 2) ? .user : .assistant, text: "t\(i)")
            t.parentId = i > 0 ? ids[i - 1] : nil
            return t
        }
        chat.activePath = ids

        let pred = RetrievalEngine.excludePredicate(chat: chat, summarizedThrough: 4, recencyExclusion: 3)

        let chunkA = Chunk(chatId: chat.id, firstTurnId: ids[0], lastTurnId: ids[2],
                           firstTurnIdx: 0, lastTurnIdx: 2, text: "a")  // lastPos=2, eligible
        let chunkB = Chunk(chatId: chat.id, firstTurnId: ids[5], lastTurnId: ids[7],
                           firstTurnIdx: 5, lastTurnIdx: 7, text: "b")  // lastPos=7, in recency
        let chunkC = Chunk(chatId: chat.id, firstTurnId: ids[2], lastTurnId: ids[4],
                           firstTurnIdx: 2, lastTurnIdx: 4, text: "c")  // lastPos=4 == verbatimCutoff
        try expectFalse(pred(chunkA))
        try expectTrue(pred(chunkB))
        try expectTrue(pred(chunkC))
    }

    s.test("off-branch chunks escape the exclude predicate (their endpoints don't resolve)") {
        // Branch A active. Chunk C indexed against off-branch sibling. The
        // chunk's lastTurnId doesn't resolve on the current path → predicate
        // returns false (don't exclude — let cosine similarity decide).
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let onPath = Turn(role: .assistant, text: "on")
        let offPath = Turn(role: .assistant, text: "off")
        chat.turns = [root, onPath, offPath]
        chat.activePath = [root.id, onPath.id]

        let pred = RetrievalEngine.excludePredicate(chat: chat, summarizedThrough: 0, recencyExclusion: 1)

        let offBranchChunk = Chunk(chatId: chat.id, firstTurnId: root.id, lastTurnId: offPath.id,
                                   firstTurnIdx: 0, lastTurnIdx: 1, text: "off")
        try expectFalse(pred(offBranchChunk))
    }

    s.test("legacy chunks (nil UUIDs) fall back to Int comparison") {
        // A legacy chunk on disk still has only Int positions. The branch-
        // aware predicate falls back to the Int snapshot for these so the
        // recency/verbatim filter still applies during the migration window.
        var chat = Chat(title: "Test")
        let ids = (0..<6).map { _ in UUID() }
        chat.turns = ids.enumerated().map { (i, id) in
            var t = Turn(id: id, role: .user, text: "t\(i)")
            t.parentId = i > 0 ? ids[i - 1] : nil
            return t
        }
        chat.activePath = ids

        let pred = RetrievalEngine.excludePredicate(chat: chat, summarizedThrough: 2, recencyExclusion: 1)

        let legacy = Chunk(chatId: chat.id, firstTurnIdx: 4, lastTurnIdx: 5, text: "old")
        try expectTrue(pred(legacy), "legacy chunk lastIdx=5 falls in the recency window via Int fallback")

        let legacyOldEnough = Chunk(chatId: chat.id, firstTurnIdx: 0, lastTurnIdx: 1, text: "older")
        try expectFalse(pred(legacyOldEnough), "legacy chunk lastIdx=1 is below verbatim cutoff 2")
    }

    s.test("legacy excludePredicate(turnsCount:summarizedThrough:) still works for existing callers") {
        // Backwards-compat path. Same math as the canonical 2026-05-04 case
        // exercised by the existing VectorStoreTests.
        let pred = RetrievalEngine.excludePredicate(
            turnsCount: 77, summarizedThrough: 51, recencyExclusion: 10
        )
        let chatId = UUID()
        try expectFalse(pred(Chunk(chatId: chatId, firstTurnIdx: 0, lastTurnIdx: 3, text: "x")))
        try expectTrue(pred(Chunk(chatId: chatId, firstTurnIdx: 60, lastTurnIdx: 63, text: "x")))
    }

    return s
}
