import Foundation
@testable import RPClientCore

/// Tests for `KokoroTokenChunker` — splits long pad-wrapped token
/// sequences into chunks ≤ the Kokoro model's per-call length limit
/// (style buffer only carries embeddings for input lengths 0..509).
/// Phase 6 §7.1k6. Pure logic.
func kokoroTokenChunkerTests() -> TestSuite {
    let s = TestSuite("KokoroTokenChunker")

    // Vocab cheat-sheet (matches `KokoroTokenizer.vocab`):
    //   0  = pad
    //   1  = ;     2 = :    3 = ,    4 = .    5 = !    6 = ?
    //   9  = —    10 = …
    //   16 = space
    //   50–67 = h..y (lowercase)
    //   ... rest unused here

    s.test("short input returns a single chunk unchanged") {
        let input: [Int64] = [0, 50, 51, 52, 4, 0]   // pad h i j . pad
        let chunks = KokoroTokenChunker.chunk(tokens: input, maxUnpadded: 500)
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0], input)
    }

    s.test("empty / pad-only input returns no chunks") {
        try expectEqual(KokoroTokenChunker.chunk(tokens: [], maxUnpadded: 500), [])
        try expectEqual(KokoroTokenChunker.chunk(tokens: [0, 0], maxUnpadded: 500), [])
        try expectEqual(KokoroTokenChunker.chunk(tokens: [0], maxUnpadded: 500), [])
    }

    s.test("splits at last punctuation when the chunk would otherwise overflow") {
        // 600 letter tokens, comma at position 250 (0-indexed within inner).
        // maxUnpadded = 400 → the split should happen at the comma (last
        // punctuation in [0, 400)), not at hard-cap 400.
        var inner: [Int64] = Array(repeating: 50, count: 600)
        inner[250] = 3   // comma
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        // Chunk 1: pad + inner[0..251] + pad → length 253
        try expectEqual(chunks[0].count, 253)
        try expectEqual(chunks[0].first, 0)
        try expectEqual(chunks[0].last, 0)
        try expectEqual(chunks[0][251], 3)   // comma is the last inner token
        // Chunk 2: pad + inner[251..600] + pad → length 351
        try expectEqual(chunks[1].count, 351)
    }

    s.test("falls back to last space when no punctuation is reachable") {
        var inner: [Int64] = Array(repeating: 50, count: 600)
        inner[300] = 16   // space, no punctuation anywhere
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        // Split should land just after the space (index 300 → splitAt 301)
        try expectEqual(chunks[0].count, 303)   // pad + 0..301 + pad
        try expectEqual(chunks[0][301], 16)
    }

    s.test("hard-splits at maxUnpadded when no punctuation or space is reachable") {
        let inner: [Int64] = Array(repeating: 50, count: 600)
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0].count, 402)   // pad + 400 letters + pad
        try expectEqual(chunks[1].count, 202)   // pad + 200 letters + pad
    }

    s.test("multi-chunk run: every chunk is pad-wrapped and within the limit") {
        var inner: [Int64] = Array(repeating: 50, count: 1500)
        // Sprinkle commas every 200 tokens.
        for j in stride(from: 199, to: 1500, by: 200) { inner[j] = 3 }
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectGreaterThan(chunks.count, 1)
        for chunk in chunks {
            try expectEqual(chunk.first, 0)
            try expectEqual(chunk.last, 0)
            try expectTrue(chunk.count - 2 <= 400, "chunk overflow: \(chunk.count - 2)")
            try expectTrue(chunk.count - 2 >= 1, "empty chunk")
        }
        // Concatenating the unpadded interiors reconstructs the original.
        let recovered: [Int64] = chunks.flatMap { Array($0.dropFirst().dropLast()) }
        try expectEqual(recovered, inner)
    }

    s.test("strips ambient leading/trailing pad before chunking") {
        // Caller may pass tokens already double-padded; we should still
        // produce single-padded chunks, not preserve their padding.
        let tokens: [Int64] = [0, 0, 50, 51, 52, 0, 0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 500)
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0], [0, 50, 51, 52, 0])
    }

    s.test("prefers sentence-end punctuation over comma even when comma is closer to the cap") {
        // Period at 100, comma at 250 (comma is *later*, closer to cap=400).
        // Naive "latest punctuation wins" would pick the comma — but a
        // comma split makes Kokoro sound like it's hit a full stop because
        // the trailing pad cues end-of-utterance prosody. Tiered logic
        // must walk back further to the period.
        // Inner length 500: with chunk 1 ending at period (101 inner tokens),
        // chunk 2 carries 399 tokens, which fits under cap=400 → 2 chunks.
        var inner: [Int64] = Array(repeating: 50, count: 500)
        inner[100] = 4   // period
        inner[250] = 3   // comma
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0][101], 4)   // last inner = period
        try expectEqual(chunks[0].count, 103)
    }

    s.test("prefers clause-end (semicolon) over comma when no sentence-end is reachable") {
        var inner: [Int64] = Array(repeating: 50, count: 500)
        inner[100] = 1   // semicolon
        inner[250] = 3   // comma (later but lower-priority)
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks[0].count, 103)   // pad + 101 inner + pad
        try expectEqual(chunks[0][101], 1)      // last inner = semicolon
    }

    s.test("strips leading space tokens from chunks 2+ to avoid begin-with-pause prosody") {
        // Period at 200, then a space at 201 (typical: ". word…"). After
        // splitting, chunk 2's inner content would otherwise begin with
        // the space token; the chunker must drop that leading space so the
        // model doesn't synthesize an unnatural opening pause.
        var inner: [Int64] = Array(repeating: 50, count: 600)
        inner[200] = 4    // period
        inner[201] = 16   // space
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectEqual(chunks.count, 2)
        // Chunk 2: pad + (space-stripped inner) + pad. First inner token
        // (chunks[1][1]) must be a letter, not a space.
        try expectTrue(chunks[1][1] != 16, "chunk 2 still begins with a space token")
    }

    s.test("doesn't infinite-loop when the only punctuation is at chunk start") {
        // Pathological: comma at position 0, then 500 letters. Backward
        // scan for last punct in [0, 400) finds index 0; splitting there
        // would zero-advance. Implementation must hard-split instead.
        var inner: [Int64] = Array(repeating: 50, count: 500)
        inner[0] = 3
        let tokens: [Int64] = [0] + inner + [0]
        let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: 400)
        try expectGreaterThan(chunks.count, 0)
        for chunk in chunks {
            try expectTrue(chunk.count - 2 <= 400)
        }
    }

    return s
}
