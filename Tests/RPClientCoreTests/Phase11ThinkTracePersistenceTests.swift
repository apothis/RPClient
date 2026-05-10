import Foundation
@testable import RPClientCore

/// Phase 11 §D.11 (option 2) — `TurnVariant.thinkingTrace` round-trip
/// + backwards-compat decode. The trace lives on TurnVariant (not on
/// Turn) so each regeneration carries its own trace; swiping variants
/// shows the matching reasoning rather than always the latest.
///
/// Backward compat is the load-bearing test: existing chat files have
/// no `thinkingTrace` key. A missing key must decode as nil, an
/// explicit null must decode as nil, and an empty string must be
/// preserved verbatim (caller decides whether empty is meaningful).
func phase11ThinkTracePersistenceTests() -> TestSuite {
    let s = TestSuite("Phase11ThinkTracePersistence")

    s.test("variant round-trip preserves a non-empty thinkingTrace") {
        let v = TurnVariant(
            text: "The reply.",
            ts: Date(timeIntervalSince1970: 1_700_000_000),
            thinkingTrace: "weighing options"
        )
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(TurnVariant.self, from: data)
        try expectEqual(decoded.thinkingTrace, "weighing options")
    }

    s.test("variant round-trip preserves nil thinkingTrace") {
        let v = TurnVariant(text: "no trace here", thinkingTrace: nil)
        let data = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(TurnVariant.self, from: data)
        try expectEqual(decoded.thinkingTrace, nil)
    }

    s.test("legacy variant JSON (no thinkingTrace key) decodes to nil") {
        // Existing chat files don't have the field. Backwards-compat
        // is non-negotiable — every chat the user has on disk must
        // continue to load.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001",
         "text":"legacy reply",
         "edited":false,
         "ts":634000000.0}
        """.data(using: .utf8)!
        let v = try JSONDecoder().decode(TurnVariant.self, from: json)
        try expectEqual(v.thinkingTrace, nil)
        try expectEqual(v.text, "legacy reply")
    }

    s.test("explicit null thinkingTrace decodes to nil") {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000002",
         "text":"r",
         "edited":false,
         "ts":634000000.0,
         "thinkingTrace":null}
        """.data(using: .utf8)!
        let v = try JSONDecoder().decode(TurnVariant.self, from: json)
        try expectEqual(v.thinkingTrace, nil)
    }

    s.test("empty-string thinkingTrace decodes verbatim") {
        // Caller decides whether empty == meaningful. Filter +
        // streaming write nil when empty (Phase11ThinkTraceCapture
        // pinned that the empty pre-fill stays empty in capturedTrace
        // and the streaming code only writes non-nil for non-empty);
        // but a hand-edited JSON could carry "" and we don't lose it.
        let json = """
        {"id":"00000000-0000-0000-0000-000000000003",
         "text":"r",
         "edited":false,
         "ts":634000000.0,
         "thinkingTrace":""}
        """.data(using: .utf8)!
        let v = try JSONDecoder().decode(TurnVariant.self, from: json)
        try expectEqual(v.thinkingTrace, "")
    }

    s.test("Turn round-trip preserves thinkingTrace on each variant") {
        // Two variants with different traces — swiping must show the
        // matching reasoning.
        var t = Turn(role: .assistant, text: "reply A", ts: Date(timeIntervalSince1970: 1_700_000_100))
        t.variants[0].thinkingTrace = "thought for A"
        t.variants.append(TurnVariant(
            text: "reply B",
            ts: Date(timeIntervalSince1970: 1_700_000_200),
            thinkingTrace: "thought for B"
        ))
        let data = try JSONEncoder().encode(t)
        let decoded = try JSONDecoder().decode(Turn.self, from: data)
        try expectEqual(decoded.variants.count, 2)
        try expectEqual(decoded.variants[0].thinkingTrace, "thought for A")
        try expectEqual(decoded.variants[1].thinkingTrace, "thought for B")
    }

    s.test("Turn legacy decode (no variants array, no thinkingTrace) — synthesised variant has nil trace") {
        // Pre-V2 chats had no variants array; Turn.init(from:) synthesises
        // one from `text`. Make sure the synthesised variant carries nil
        // trace (we have nothing to put there).
        let json = """
        {"id":"00000000-0000-0000-0000-000000000010",
         "role":"assistant",
         "text":"pre-V2 reply",
         "edited":false,
         "ts":634000000.0}
        """.data(using: .utf8)!
        let t = try JSONDecoder().decode(Turn.self, from: json)
        try expectEqual(t.variants.count, 1)
        try expectEqual(t.variants[0].thinkingTrace, nil)
    }

    return s
}
