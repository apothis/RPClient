import Foundation
@testable import RPClientCore

/// Phase 7 §3.2.B — Chunk + Chunker + VectorStore migration from
/// `firstTurnIdx`/`lastTurnIdx: Int` to `firstTurnId`/`lastTurnId: UUID`.
///
/// Strategy: Chunk carries both shapes during the migration window. Two
/// initializers — legacy (Int-only, derives Int-based id) and Phase-7+
/// (UUIDs + Int positions, derives UUID-based id). Chunker emits Phase-7+
/// chunks; legacy chunks loaded from disk coexist until the next index
/// pass drops them (their Int-based ids won't match Chunker's UUID-based
/// ids in the desiredIds check).
///
/// VectorStore gains turnIds-keyed `invalidate` / `clamp` methods alongside
/// the existing Int-keyed ones; both work during the transition.
func chunkBranchingTests() -> TestSuite {
    let s = TestSuite("ChunkBranching")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func makeTmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RPClientTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - Chunk: dual initializers + id format

    s.test("legacy Int initializer derives Int-based id and leaves UUID fields nil") {
        let chatId = UUID()
        let chunk = Chunk(chatId: chatId, firstTurnIdx: 2, lastTurnIdx: 5, text: "x")
        try expectEqual(chunk.id, "\(chatId.uuidString)-2-5")
        try expectEqual(chunk.firstTurnIdx, 2)
        try expectEqual(chunk.lastTurnIdx, 5)
        try expectEqual(chunk.firstTurnId, nil)
        try expectEqual(chunk.lastTurnId, nil)
    }

    s.test("Phase 7+ UUID initializer derives UUID-based id and populates both fields") {
        let chatId = UUID()
        let firstId = UUID()
        let lastId = UUID()
        let chunk = Chunk(chatId: chatId, firstTurnId: firstId, lastTurnId: lastId,
                          firstTurnIdx: 2, lastTurnIdx: 5, text: "x")
        try expectEqual(chunk.id, "\(chatId.uuidString)-\(firstId.uuidString)-\(lastId.uuidString)")
        try expectEqual(chunk.firstTurnId, firstId)
        try expectEqual(chunk.lastTurnId, lastId)
        try expectEqual(chunk.firstTurnIdx, 2)
        try expectEqual(chunk.lastTurnIdx, 5)
    }

    s.test("Chunk round-trip preserves UUID-based id and all fields") {
        let chatId = UUID()
        let firstId = UUID()
        let lastId = UUID()
        var chunk = Chunk(chatId: chatId, firstTurnId: firstId, lastTurnId: lastId,
                          firstTurnIdx: 2, lastTurnIdx: 5, text: "hello")
        chunk.embedding = [0.1, 0.2]
        let data = try encoder.encode(chunk)
        let decoded = try decoder.decode(Chunk.self, from: data)
        try expectEqual(decoded.id, chunk.id)
        try expectEqual(decoded.firstTurnId, firstId)
        try expectEqual(decoded.lastTurnId, lastId)
        try expectEqual(decoded.firstTurnIdx, 2)
        try expectEqual(decoded.lastTurnIdx, 5)
        try expectEqual(decoded.text, "hello")
        try expectEqual(decoded.embedding, [0.1, 0.2])
    }

    s.test("legacy Chunk JSON (Int-only) decodes with nil UUIDs") {
        let chatId = UUID()
        let json = """
        {
            "id": "\(chatId.uuidString)-0-3",
            "chatId": "\(chatId.uuidString)",
            "firstTurnIdx": 0,
            "lastTurnIdx": 3,
            "text": "legacy"
        }
        """
        let chunk = try decoder.decode(Chunk.self, from: Data(json.utf8))
        try expectEqual(chunk.firstTurnIdx, 0)
        try expectEqual(chunk.lastTurnIdx, 3)
        try expectEqual(chunk.firstTurnId, nil)
        try expectEqual(chunk.lastTurnId, nil)
        try expectEqual(chunk.id, "\(chatId.uuidString)-0-3")
    }

    // MARK: - Chunker walks active path

    s.test("Chunker.chunks(for:) emits UUID-keyed chunks against the active path") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        let t2 = Turn(role: .user, text: "c")
        let t3 = Turn(role: .assistant, text: "d")
        chat.turns = [t0, t1, t2, t3]
        chat.activePath = [t0.id, t1.id, t2.id, t3.id]

        let chunks = Chunker.chunks(for: chat)
        try expectEqual(chunks.count, 1) // window=4, single chunk covering all 4 turns
        try expectEqual(chunks[0].firstTurnId, t0.id)
        try expectEqual(chunks[0].lastTurnId, t3.id)
        // Int positions still populated for legacy callers/displays.
        try expectEqual(chunks[0].firstTurnIdx, 0)
        try expectEqual(chunks[0].lastTurnIdx, 3)
    }

    s.test("Chunker only chunks turns on the active path, not off-branch siblings") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let onPath1 = Turn(role: .assistant, text: "on1")
        let onPath2 = Turn(role: .user, text: "on2")
        let offPath = Turn(role: .assistant, text: "off")
        chat.turns = [root, onPath1, onPath2, offPath]
        chat.activePath = [root.id, onPath1.id, onPath2.id]   // offPath excluded

        let chunks = Chunker.chunks(for: chat)
        // Only the 3 active-path turns produce chunks. Window=4 + at-least-2-trailing = one chunk.
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].firstTurnId, root.id)
        try expectEqual(chunks[0].lastTurnId, onPath2.id)
    }

    s.test("Chunker falls back to chat.turns when activePath is empty (in-memory chats)") {
        // Pre-Phase-7-aware in-memory chat (existing tests use this pattern).
        var chat = Chat()
        chat.turns = (0..<4).map { i in
            Turn(role: i.isMultiple(of: 2) ? .user : .assistant, text: "t\(i)")
        }
        // activePath stays empty — Chunker falls back to chat.turns.

        let chunks = Chunker.chunks(for: chat)
        try expectEqual(chunks.count, 1)
        // First chunk covers turns 0–3.
        try expectEqual(chunks[0].firstTurnIdx, 0)
        try expectEqual(chunks[0].lastTurnIdx, 3)
        // UUIDs populated from the actual turn ids even on the fallback path.
        try expectEqual(chunks[0].firstTurnId, chat.turns[0].id)
        try expectEqual(chunks[0].lastTurnId, chat.turns[3].id)
    }

    // MARK: - VectorStore: turnIds-keyed invalidate / clamp

    s.test("VectorStore.invalidate(turnIds:) drops chunks whose UUID range covers any given id") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)

        let ids = (0..<10).map { _ in UUID() }
        store.upsert(Chunk(chatId: chatId, firstTurnId: ids[0], lastTurnId: ids[3],
                           firstTurnIdx: 0, lastTurnIdx: 3, text: "a"))
        store.upsert(Chunk(chatId: chatId, firstTurnId: ids[3], lastTurnId: ids[6],
                           firstTurnIdx: 3, lastTurnIdx: 6, text: "b"))
        store.upsert(Chunk(chatId: chatId, firstTurnId: ids[6], lastTurnId: ids[9],
                           firstTurnIdx: 6, lastTurnIdx: 9, text: "c"))

        store.invalidate(turnIds: [ids[3]])
        try expectEqual(store.chunks.count, 1)
        try expectEqual(store.chunks.values.first?.firstTurnId, ids[6])
    }

    s.test("VectorStore.clamp(toTurnIdsPresent:) drops chunks whose endpoint UUIDs are missing") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)

        let ids = (0..<6).map { _ in UUID() }
        store.upsert(Chunk(chatId: chatId, firstTurnId: ids[0], lastTurnId: ids[3],
                           firstTurnIdx: 0, lastTurnIdx: 3, text: "a"))
        store.upsert(Chunk(chatId: chatId, firstTurnId: ids[2], lastTurnId: ids[5],
                           firstTurnIdx: 2, lastTurnIdx: 5, text: "b"))

        // Only ids[0..3] are still in the chat. Chunk b's lastTurnId (ids[5]) is gone → drop.
        store.clamp(toTurnIdsPresent: Set(ids[0...3]))
        try expectEqual(store.chunks.count, 1)
        try expectEqual(store.chunks.values.first?.firstTurnId, ids[0])
    }

    s.test("VectorStore.invalidate(turnIds:) leaves legacy Int-only chunks alone") {
        // Defensive: a legacy chunk loaded from disk has nil UUIDs; the
        // turnIds-keyed invalidator can't match against nil — the chunk
        // survives. Cleanup of legacy chunks happens via the next index
        // pass (id mismatch with desiredIds).
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(Chunk(chatId: chatId, firstTurnIdx: 0, lastTurnIdx: 3, text: "legacy"))

        store.invalidate(turnIds: [UUID()])
        try expectEqual(store.chunks.count, 1)
    }

    return s
}
