import Foundation
@testable import RPClientCore

func vectorStoreTests() -> TestSuite {
    let s = TestSuite("VectorStore")

    func makeTmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RPClientTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func embedded(_ chatId: UUID, range: ClosedRange<Int>, vector: [Float], text: String = "x") -> Chunk {
        var c = Chunk(chatId: chatId, firstTurnIdx: range.lowerBound, lastTurnIdx: range.upperBound, text: text)
        c.embedding = vector
        return c
    }

    s.test("search ranks by cosine similarity") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...1, vector: [1, 0, 0]))
        store.upsert(embedded(chatId, range: 2...3, vector: [0, 1, 0]))
        store.upsert(embedded(chatId, range: 4...5, vector: [1, 1, 0]))

        let hits = store.search(query: [1, 0, 0], topK: 3, threshold: 0, excluding: { _ in false })
        try expectEqual(hits.count, 3)
        try expectEqual(hits[0].chunk.firstTurnIdx, 0)
        try expectGreaterThan(hits[0].score, hits[1].score)
    }

    s.test("search applies threshold") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...1, vector: [1, 0]))
        store.upsert(embedded(chatId, range: 2...3, vector: [0, 1]))

        let hits = store.search(query: [1, 0], topK: 5, threshold: 0.99, excluding: { _ in false })
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].chunk.firstTurnIdx, 0)
    }

    // MARK: - RetrievalEngine.excludePredicate (chunk-vs-active-window invariant)

    s.test("excludePredicate skips chunks within the verbatim window") {
        // Canonical case from the 2026-05-04 'starts before my request' bug:
        // turns=77, summarizedThrough=51, recencyExclusion=10. The verbatim
        // window is turns 51..76, all already in the prompt as raw text.
        // Retrieval must not pull chunks from that range.
        let pred = RetrievalEngine.excludePredicate(
            turnsCount: 77,
            summarizedThrough: 51,
            recencyExclusion: 10
        )
        let chatId = UUID()
        func chunk(_ range: ClosedRange<Int>) -> Chunk {
            Chunk(chatId: chatId, firstTurnIdx: range.lowerBound, lastTurnIdx: range.upperBound, text: "x")
        }
        // Pre-summarize chunks: eligible.
        try expectFalse(pred(chunk(0...3)))
        try expectFalse(pred(chunk(48...50)))
        // Chunks ending at or beyond summarizedThrough: skipped.
        try expectTrue(pred(chunk(48...51)), "chunk lastIdx=51 must be skipped — turn 51 is already verbatim")
        try expectTrue(pred(chunk(60...63)), "deep inside verbatim window must be skipped")
        try expectTrue(pred(chunk(74...76)), "chunk lastIdx near head also caught by recencyExclusion=10")
    }

    s.test("excludePredicate skips everything when no summary has been written") {
        // summarizedThrough=0 means the entire chat is verbatim — retrieval
        // is redundant by definition. The predicate should reflect that.
        let pred = RetrievalEngine.excludePredicate(
            turnsCount: 30,
            summarizedThrough: 0,
            recencyExclusion: 10
        )
        let chatId = UUID()
        try expectTrue(pred(Chunk(chatId: chatId, firstTurnIdx: 0, lastTurnIdx: 3, text: "x")))
        try expectTrue(pred(Chunk(chatId: chatId, firstTurnIdx: 25, lastTurnIdx: 28, text: "x")))
    }

    s.test("search respects excluding predicate") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...1, vector: [1, 0]))
        store.upsert(embedded(chatId, range: 8...9, vector: [1, 0]))

        let hits = store.search(query: [1, 0], topK: 5, threshold: 0,
                                excluding: { $0.lastTurnIdx >= 8 })
        try expectEqual(hits.map(\.chunk.firstTurnIdx), [0])
    }

    s.test("invalidate drops chunks whose range overlaps any given turn") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...3, vector: [1]))
        store.upsert(embedded(chatId, range: 3...6, vector: [1]))
        store.upsert(embedded(chatId, range: 6...9, vector: [1]))

        store.invalidate(turnIndices: [3])
        try expectEqual(store.chunks.count, 1)
        try expectEqual(store.chunks.values.first?.firstTurnIdx, 6)
    }

    s.test("clampToTurnCount drops chunks past the turn count") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...3, vector: [1]))
        store.upsert(embedded(chatId, range: 4...7, vector: [1]))
        store.clampToTurnCount(5)
        try expectEqual(store.chunks.count, 1)
        try expectEqual(store.chunks.values.first?.lastTurnIdx, 3)
    }

    s.test("save then reload round-trips chunks") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        do {
            let store = VectorStore(chatId: chatId, dir: dir)
            store.upsert(embedded(chatId, range: 0...1, vector: [0.5, -0.5], text: "hi"))
            store.save()
        }
        let reopened = VectorStore(chatId: chatId, dir: dir)
        try expectEqual(reopened.chunks.count, 1)
        try expectEqual(reopened.chunks.values.first?.text, "hi")
        try expectEqual(reopened.chunks.values.first?.embedding, [0.5, -0.5])
    }

    s.test("search skips chunks whose embedding length disagrees with the query") {
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let chatId = UUID()
        let store = VectorStore(chatId: chatId, dir: dir)
        store.upsert(embedded(chatId, range: 0...1, vector: [1, 0, 0]))
        store.upsert(embedded(chatId, range: 2...3, vector: [1, 0]))
        let hits = store.search(query: [1, 0, 0], topK: 5, threshold: 0, excluding: { _ in false })
        try expectEqual(hits.count, 1)
    }

    return s
}
