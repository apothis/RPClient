import Foundation
import Accelerate

/// Per-chat in-memory store of embedded chunks, persisted to disk as JSON.
/// Brute-force cosine search via Accelerate — fine up to tens of thousands of
/// chunks for a single chat (see MEMORY_RESEARCH.md §9.1).
final class VectorStore {
    let chatId: UUID
    private(set) var chunks: [String: Chunk]   // keyed by Chunk.id
    private let url: URL

    init(chatId: UUID, dir: URL) {
        self.chatId = chatId
        self.url = dir.appendingPathComponent("\(chatId.uuidString).vec.json")
        self.chunks = [:]
        load()
    }

    // MARK: - Mutation

    func upsert(_ chunk: Chunk) {
        chunks[chunk.id] = chunk
    }

    func remove(id: String) {
        chunks.removeValue(forKey: id)
    }

    /// Drop chunks whose range overlaps any of the given turn indices. Use
    /// when a turn gets edited or deleted: invalidate any chunk that covered it.
    func invalidate(turnIndices: Set<Int>) {
        let dropping = chunks.values.filter { c in
            (c.firstTurnIdx...c.lastTurnIdx).contains(where: turnIndices.contains)
        }
        for c in dropping { chunks.removeValue(forKey: c.id) }
    }

    /// Drop chunks that no longer match anything in the chat (e.g. ranges that
    /// exceed the current turn count after a delete).
    func clampToTurnCount(_ count: Int) {
        let dropping = chunks.values.filter { $0.lastTurnIdx >= count }
        for c in dropping { chunks.removeValue(forKey: c.id) }
    }

    // MARK: - Search

    struct Hit {
        let chunk: Chunk
        let score: Float
    }

    /// Top-K cosine similarity search with a hard threshold. Pass a predicate
    /// to drop e.g. recent-window chunks before scoring (cheap recency filter).
    func search(
        query: [Float],
        topK: Int,
        threshold: Float,
        excluding: (Chunk) -> Bool
    ) -> [Hit] {
        guard !query.isEmpty else { return [] }
        let qNorm = norm(query)
        guard qNorm > 0 else { return [] }

        var hits: [Hit] = []
        for chunk in chunks.values {
            guard let emb = chunk.embedding, !emb.isEmpty,
                  emb.count == query.count,
                  !excluding(chunk) else { continue }
            let dot = dotProduct(query, emb)
            let cNorm = norm(emb)
            guard cNorm > 0 else { continue }
            let score = dot / (qNorm * cNorm)
            if score >= threshold {
                hits.append(Hit(chunk: chunk, score: score))
            }
        }
        hits.sort { $0.score > $1.score }
        return Array(hits.prefix(topK))
    }

    private func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
    }

    private func norm(_ v: [Float]) -> Float {
        var sumSq: Float = 0
        vDSP_svesq(v, 1, &sumSq, vDSP_Length(v.count))
        return sqrt(sumSq)
    }

    // MARK: - Persistence

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    func save() {
        let arr = Array(chunks.values).sorted { $0.firstTurnIdx < $1.firstTurnIdx }
        guard let data = try? Self.encoder.encode(arr) else { return }
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            } else {
                try FileManager.default.moveItem(at: tmp, to: url)
            }
        } catch {
            try? data.write(to: url)
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let arr = try? Self.decoder.decode([Chunk].self, from: data) else {
            return
        }
        for c in arr { chunks[c.id] = c }
    }
}
