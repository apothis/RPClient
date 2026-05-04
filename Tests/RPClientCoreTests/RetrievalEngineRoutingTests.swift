import Foundation
@testable import RPClientCore

func retrievalEngineRoutingTests() -> TestSuite {
    let s = TestSuite("RetrievalEngineRouting")

    final class FakeBlurber: KoboldGenerating {
        var generateCallCount = 0
        var lastPrompt: String?
        func generate(
            prompt: String,
            stopSequences: [String],
            preset: SamplerPreset,
            maxContextLength: Int,
            grammar: String?,
            maxLengthOverride: Int?,
            completion: @escaping (Result<String, Error>) -> Void
        ) {
            generateCallCount += 1
            lastPrompt = prompt
            completion(.success("(stub blurb)"))
        }
    }

    final class FakeEmbedder: KoboldEmbedding {
        var embedCallCount = 0
        var totalTextsEmbedded = 0
        func embed(
            texts: [String],
            completion: @escaping (Result<[[Float]], Error>) -> Void
        ) {
            embedCallCount += 1
            totalTextsEmbedded += texts.count
            // Return a tiny canned embedding per input — must be non-empty so
            // VectorStore considers the chunk embedded.
            let vecs = texts.map { _ -> [Float] in [0.1, 0.2, 0.3, 0.4] }
            completion(.success(vecs))
        }
    }

    func makeTmpDir() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RPClientTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func makeChatWithTurns(_ count: Int) -> Chat {
        var chat = Chat(title: "Routed")
        chat.turns = (0..<count).map { i in
            Turn(role: i % 2 == 0 ? .user : .assistant,
                 text: "turn \(i): " + String(repeating: "x", count: 200))
        }
        return chat
    }

    s.test("index with contextual=true routes generate to blurber, embed to embedder") {
        // Phase 4 §5.2 — the engine's two side-calls (blurb + embed) must be
        // routable to *different* koboldcpp profiles. Inject two distinct
        // fakes; assert each one received its expected call shape and only
        // its own.
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RetrievalEngine(storesDir: dir)
        let chat = makeChatWithTurns(8)
        let blurber = FakeBlurber()
        let embedder = FakeEmbedder()

        var indexResult: Result<Int, Error>?
        engine.index(
            chat: chat,
            embedder: embedder,
            blurber: blurber,
            contextual: true,
            effectiveCtx: 4096
        ) { r in indexResult = r }

        // The blurb step uses DispatchQueue.main.async between chunks (real
        // KoboldClient finishes on URLSession's queue; this hop reasserts
        // main). Pump the run loop until the completion fires or we time out.
        let deadline = Date(timeIntervalSinceNow: 5)
        while indexResult == nil && Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date(timeIntervalSinceNow: 0.05))
        }
        let r = try expectNotNil(indexResult)
        switch r {
        case .failure(let e):
            try expect(false, "index failed: \(e)")
        case .success(let n): try expectGreaterThan(n, 0)
        }
        try expectGreaterThan(blurber.generateCallCount, 0)
        try expectGreaterThan(embedder.embedCallCount, 0)
        try expectEqual(blurber.generateCallCount, embedder.totalTextsEmbedded,
                        "one blurb generated per chunk; one chunk embedded per blurb")
    }

    s.test("index with contextual=false skips blurber entirely") {
        // Same routing contract, opposite branch: when the user disables
        // contextual retrieval the blurber must not be touched at all (saves
        // a side-call per chunk on indexing).
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RetrievalEngine(storesDir: dir)
        let chat = makeChatWithTurns(6)
        let blurber = FakeBlurber()
        let embedder = FakeEmbedder()

        engine.index(
            chat: chat,
            embedder: embedder,
            blurber: blurber,
            contextual: false,
            effectiveCtx: 4096
        ) { _ in }

        try expectEqual(blurber.generateCallCount, 0)
        try expectGreaterThan(embedder.embedCallCount, 0)
    }

    s.test("retrieve uses only the embedder for the query") {
        // retrieve() never blurbs — it only embeds the query and runs cosine
        // search over the existing store. Test that asking a populated store
        // for retrieval doesn't accidentally fall through to a blurber the
        // function shouldn't even hold.
        let dir = makeTmpDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let engine = RetrievalEngine(storesDir: dir)
        let chat = makeChatWithTurns(8)
        let embedder = FakeEmbedder()
        let blurber = FakeBlurber()

        // Seed the store via index.
        engine.index(
            chat: chat,
            embedder: embedder,
            blurber: blurber,
            contextual: false,
            effectiveCtx: 4096
        ) { _ in }
        let embedsAfterIndex = embedder.embedCallCount

        var retrieveSettings = RetrievalSettings.default
        retrieveSettings.enabled = true
        retrieveSettings.threshold = -1   // accept everything
        retrieveSettings.recencyExclusion = 0
        engine.retrieve(chat: chat, embedder: embedder, settings: retrieveSettings) { _ in }

        try expectGreaterThan(embedder.embedCallCount, embedsAfterIndex)
        try expectEqual(blurber.generateCallCount, 0,
                        "blurber must not be touched in the retrieve path")
    }

    return s
}
