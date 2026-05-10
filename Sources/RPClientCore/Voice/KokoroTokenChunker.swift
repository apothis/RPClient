import Foundation

/// Splits a pad-wrapped Kokoro token sequence into chunks short enough to
/// pass through the ONNX model in a single inference call. Phase 6 §7.1k6.
///
/// The model's per-call length limit is the style buffer's slot count (510 —
/// see `KokoroEngine.styleSlots`); inputs longer than that produce
/// `KokoroEngineError.styleSliceOutOfRange`. Real assistant replies easily
/// exceed this (a few sentences ≈ 500–1500 phoneme tokens).
///
/// Each chunk is wrapped with leading + trailing pad before synthesis. The
/// trailing pad cues end-of-utterance prosody to the model — a real period
/// at the cut point sounds natural, but a comma sounds like a fake full
/// stop. So we **prefer harder punctuation** at split points:
///   1. Sentence-end (`. ! ? — …`)
///   2. Clause-end (`; :`)
///   3. Comma (`,`)
///   4. Space (last-resort word boundary)
///   5. Hard cap (mid-word; only when the run has no whitespace at all)
/// Within a tier we pick the latest break (greedy — maximises audio per
/// chunk). Leading space tokens are stripped from each chunk so chunks 2+
/// don't begin with a "pause" cue.
public enum KokoroTokenChunker {
    /// Pad token id (`KokoroTokenizer.padTokenId`).
    private static let pad: Int64 = 0
    /// Space token id.
    private static let spaceId: Int64 = 16
    /// Token-id sets ordered from highest to lowest preference for splits.
    /// See file-level doc comment for rationale.
    private static let punctuationTiers: [Set<Int64>] = [
        [4, 5, 6, 9, 10],   // sentence-end: . ! ? — …
        [1, 2],             // clause-end:   ; :
        [3],                // comma:        ,
    ]

    /// Split `tokens` into pad-wrapped chunks each carrying ≤ `maxUnpadded`
    /// inner tokens. Empty / pad-only inputs return an empty array.
    public static func chunk(tokens: [Int64], maxUnpadded: Int) -> [[Int64]] {
        // Strip ambient leading/trailing pad. We accept either `[pad, ..., pad]`
        // (the tokenizer's normal output) or unwrapped, and return chunks
        // wrapped exactly once on each side.
        var inner = tokens[...]
        while inner.first == pad { inner = inner.dropFirst() }
        while inner.last == pad { inner = inner.dropLast() }

        let innerArray = Array(inner)
        if innerArray.isEmpty { return [] }
        if innerArray.count <= maxUnpadded {
            return [wrap(stripLeadingSpace(innerArray))]
        }

        var chunks: [[Int64]] = []
        var cursor = 0
        while cursor < innerArray.count {
            let cap = min(cursor + maxUnpadded, innerArray.count)

            // Remainder fits → take the rest as one chunk.
            if cap == innerArray.count {
                chunks.append(wrap(stripLeadingSpace(Array(innerArray[cursor..<cap]))))
                break
            }

            let splitAt = bestSplit(in: innerArray, cursor: cursor, cap: cap)
            chunks.append(wrap(stripLeadingSpace(Array(innerArray[cursor..<splitAt]))))
            cursor = splitAt
        }
        // Empty (all-space) chunks reduce to [pad] + [] + [pad] = [0, 0]
        // after stripping; filter those out.
        return chunks.filter { $0.count > 2 }
    }

    /// Find the best split point inside `[cursor, cap)`, preferring higher
    /// punctuation tiers. Falls back to the last space, then to a hard
    /// split at `cap`. Never returns `<= cursor` (that would zero-advance
    /// and infinite-loop on pathological inputs).
    private static func bestSplit(in inner: [Int64], cursor: Int, cap: Int) -> Int {
        let range = cursor..<cap
        for tier in punctuationTiers {
            if let p = range.reversed().first(where: { tier.contains(inner[$0]) }), p > cursor {
                return p + 1
            }
        }
        if let sp = range.reversed().first(where: { inner[$0] == spaceId }), sp > cursor {
            return sp + 1
        }
        return cap
    }

    private static func stripLeadingSpace(_ inner: [Int64]) -> [Int64] {
        var arr = inner[...]
        while arr.first == spaceId { arr = arr.dropFirst() }
        return Array(arr)
    }

    private static func wrap(_ inner: [Int64]) -> [Int64] {
        if inner.isEmpty { return [pad, pad] }   // filtered out by caller
        return [pad] + inner + [pad]
    }
}
