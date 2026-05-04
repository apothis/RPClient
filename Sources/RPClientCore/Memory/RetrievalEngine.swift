import Foundation

struct RetrievalSettings: Codable, Equatable {
    var enabled: Bool
    var topK: Int
    var threshold: Float
    /// Don't retrieve chunks whose lastTurnIdx is within this many turns of the end —
    /// otherwise we just retrieve content that's already verbatim in context (echo).
    var recencyExclusion: Int
    /// Anthropic's contextual-retrieval recipe: generate a 1–2 sentence
    /// "place this snippet in the story" blurb per chunk before embedding.
    /// Costs one short side-call per new chunk during indexing; pays off
    /// at retrieval time with sharper scores. Reported ~49% reduction in
    /// retrieval failures in Anthropic's tests.
    var contextual: Bool

    static let `default` = RetrievalSettings(
        enabled: false,
        topK: 3,
        threshold: 0.70,
        recencyExclusion: 10,
        contextual: true
    )

    init(enabled: Bool, topK: Int, threshold: Float, recencyExclusion: Int, contextual: Bool = true) {
        self.enabled = enabled
        self.topK = topK
        self.threshold = threshold
        self.recencyExclusion = recencyExclusion
        self.contextual = contextual
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = RetrievalSettings.default
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        topK = try c.decodeIfPresent(Int.self, forKey: .topK) ?? d.topK
        threshold = try c.decodeIfPresent(Float.self, forKey: .threshold) ?? d.threshold
        recencyExclusion = try c.decodeIfPresent(Int.self, forKey: .recencyExclusion) ?? d.recencyExclusion
        contextual = try c.decodeIfPresent(Bool.self, forKey: .contextual) ?? d.contextual
    }
}

/// Owns per-chat VectorStores. Indexes chunks (chunk → embed → persist) and
/// runs top-K cosine retrieval at prompt-build time.
final class RetrievalEngine {
    static let shared = RetrievalEngine()
    private var stores: [UUID: VectorStore] = [:]
    private let lock = NSLock()
    private let storesDirOverride: URL?

    init(storesDir: URL? = nil) {
        self.storesDirOverride = storesDir
    }

    private var storesDir: URL {
        storesDirOverride ?? Storage.shared.vectorsDir
    }

    func store(for chatId: UUID) -> VectorStore {
        lock.lock()
        defer { lock.unlock() }
        if let s = stores[chatId] { return s }
        let s = VectorStore(chatId: chatId, dir: storesDir)
        stores[chatId] = s
        return s
    }

    func deleteStore(for chatId: UUID) {
        lock.lock()
        defer { lock.unlock() }
        stores.removeValue(forKey: chatId)
    }

    /// Reconcile chunks for the chat against the store, then embed any that need it.
    /// Returns the number of newly embedded chunks.
    /// `effectiveCtx` is the kobold context cap; passed to the blurb side-call
    /// when contextual retrieval is enabled.
    func index(
        chat: Chat,
        embedder: KoboldEmbedding,
        blurber: KoboldGenerating,
        contextual: Bool = false,
        effectiveCtx: Int = 4096,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        let store = store(for: chat.id)
        let desired = Chunker.chunks(for: chat)
        let desiredIds = Set(desired.map(\.id))

        // Drop chunks no longer present (turn count shrunk, range shifted, etc.)
        for existingId in store.chunks.keys where !desiredIds.contains(existingId) {
            store.remove(id: existingId)
        }

        // Find chunks to embed: new ones, or ones whose text changed.
        var toEmbed: [Chunk] = []
        for chunk in desired {
            if let existing = store.chunks[chunk.id] {
                if existing.text == chunk.text, existing.isEmbedded {
                    continue
                }
                var updated = chunk
                updated.embedding = nil
                // Content has changed for this id → blurb is stale too.
                updated.contextBlurb = nil
                store.upsert(updated)
                toEmbed.append(updated)
            } else {
                store.upsert(chunk)
                toEmbed.append(chunk)
            }
        }

        guard !toEmbed.isEmpty else {
            store.save()
            completion(.success(0))
            return
        }

        // Generate contextual blurbs sequentially (one side-call per chunk)
        // *before* embedding. Sequential rather than parallel because kobold
        // serves one generation at a time. Failures are non-fatal — we fall
        // back to embedding the raw chunk text for that one entry.
        annotateWithBlurbs(
            toEmbed, contextual: contextual, chat: chat,
            blurber: blurber, effectiveCtx: effectiveCtx, store: store
        ) { [weak self] annotated in
            guard let self = self else { return }
            self.embedBatched(annotated, embedder: embedder, store: store) { result in
                store.save()
                completion(result)
            }
        }
    }

    private func annotateWithBlurbs(
        _ chunks: [Chunk],
        contextual: Bool,
        chat: Chat,
        blurber: KoboldGenerating,
        effectiveCtx: Int,
        store: VectorStore,
        completion: @escaping ([Chunk]) -> Void
    ) {
        guard contextual else { completion(chunks); return }
        var remaining = chunks
        var done: [Chunk] = []
        done.reserveCapacity(chunks.count)

        func step() {
            guard !remaining.isEmpty else {
                completion(done)
                return
            }
            var chunk = remaining.removeFirst()
            // Skip if already blurbed (e.g. retried index after partial failure).
            if let existing = chunk.contextBlurb,
               !existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                done.append(chunk)
                step()
                return
            }
            ContextBlurber.run(
                chunk: chunk, chat: chat, kobold: blurber, effectiveCtx: effectiveCtx
            ) { result in
                DispatchQueue.main.async {
                    switch result {
                    case .success(let blurb):
                        chunk.contextBlurb = blurb
                        store.upsert(chunk)
                    case .failure:
                        // Leave blurb nil and proceed — chunk falls back to
                        // raw-text embedding for this round. Next index pass
                        // will retry if conditions allow.
                        break
                    }
                    done.append(chunk)
                    step()
                }
            }
        }
        step()
    }

    private func embedBatched(
        _ chunks: [Chunk],
        embedder: KoboldEmbedding,
        store: VectorStore,
        batchSize: Int = 16,
        completion: @escaping (Result<Int, Error>) -> Void
    ) {
        var remaining = chunks
        var embedded = 0

        func nextBatch() {
            guard !remaining.isEmpty else {
                completion(.success(embedded))
                return
            }
            let batch = Array(remaining.prefix(batchSize))
            remaining.removeFirst(batch.count)
            // Embed `embeddingText` (blurb + text when present, else just
            // text) so the contextual retrieval signal gets baked into the
            // vector itself.
            embedder.embed(texts: batch.map(\.embeddingText)) { result in
                switch result {
                case .failure(let e):
                    completion(.failure(e))
                case .success(let vecs):
                    for idx in 0..<min(batch.count, vecs.count) {
                        var updated = batch[idx]
                        updated.embedding = vecs[idx]
                        updated.embeddedAt = Date()
                        store.upsert(updated)
                    }
                    embedded += min(batch.count, vecs.count)
                    nextBatch()
                }
            }
        }
        nextBatch()
    }

    /// Two-rail exclusion predicate that says "skip this chunk":
    ///  1. **Recency cutoff** — chunk tails within `recencyExclusion` turns
    ///     of the head are skipped because they echo content already verbatim.
    ///  2. **Verbatim cutoff** — chunks overlapping or following
    ///     `summarizedThrough` are skipped unconditionally because the
    ///     entire verbatim window is already in the prompt. Without this,
    ///     retrieval pulls 4-turn windows from the current scene itself
    ///     and the model sees them as the latest dialog right before the
    ///     generation marker, then narrates from inside one of them before
    ///     catching up to the user's actual most-recent message. Hard rule:
    ///     never inject content that's already verbatim in the prompt.
    /// Public so tests can exercise the rules without mocking the embed call.
    static func excludePredicate(
        turnsCount: Int,
        summarizedThrough: Int,
        recencyExclusion: Int
    ) -> (Chunk) -> Bool {
        let recencyCutoff = turnsCount - recencyExclusion
        let verbatimCutoff = summarizedThrough
        return { chunk in
            chunk.lastTurnIdx >= recencyCutoff
                || chunk.lastTurnIdx >= verbatimCutoff
        }
    }

    /// Retrieve top-K relevant chunks for the current state of the chat.
    /// Returns hits in descending similarity order.
    func retrieve(
        chat: Chat,
        embedder: KoboldEmbedding,
        settings: RetrievalSettings,
        completion: @escaping ([VectorStore.Hit]) -> Void
    ) {
        guard settings.enabled else { completion([]); return }
        let store = store(for: chat.id)
        guard !store.chunks.isEmpty else { completion([]); return }

        // Query: the latest user/assistant exchange concatenated. Captures both
        // the user's intent and the immediate scene context.
        let recent = chat.turns.suffix(4)
        let query = recent.map { t -> String in
            let role = t.role == .user ? "User" : "Assistant"
            return "\(role): \(t.text)"
        }.joined(separator: "\n\n")
        guard !query.isEmpty else { completion([]); return }

        embedder.embed(texts: [query]) { result in
            DispatchQueue.main.async {
                guard case .success(let vecs) = result, let q = vecs.first else {
                    completion([])
                    return
                }
                let predicate = RetrievalEngine.excludePredicate(
                    turnsCount: chat.turns.count,
                    summarizedThrough: chat.summarizedThrough,
                    recencyExclusion: settings.recencyExclusion
                )
                let hits = store.search(
                    query: q,
                    topK: settings.topK,
                    threshold: settings.threshold,
                    excluding: predicate
                )
                completion(hits)
            }
        }
    }
}
