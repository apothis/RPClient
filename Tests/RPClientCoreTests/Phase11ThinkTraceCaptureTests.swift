import Foundation
@testable import RPClientCore

/// Phase 11 §D.11 (option 2) — `ThinkBlockFilter.capturedTrace`
/// preserves the content between `<think>` and `</think>` so the side-
/// channel Turn.thinkingTrace can be populated at stream finalize.
///
/// Pre-§D.11 the filter just discarded the trace; the streaming output
/// was a token-stripper, not a token-router. Adding capture is purely
/// additive — the existing `ingest(...) -> String` contract (display
/// text only) doesn't change.
func phase11ThinkTraceCaptureTests() -> TestSuite {
    let s = TestSuite("Phase11ThinkTraceCapture")

    s.test("simple <think>x</think>body — capturedTrace = x") {
        var f = ThinkBlockFilter()
        let out = f.ingest("<think>weighing options</think>The reply.")
        try expectEqual(out, "The reply.")
        try expectEqual(f.capturedTrace, "weighing options")
    }

    s.test("no <think> tag — capturedTrace stays empty") {
        var f = ThinkBlockFilter()
        let out = f.ingest("Plain reply with no thinking.")
        try expectEqual(out, "Plain reply with no thinking.")
        try expectEqual(f.capturedTrace, "")
    }

    s.test("empty <think></think> — capturedTrace stays empty") {
        // The Qwen3 empty pre-fill case (Phase 10 finding) — harmless
        // and very common. Caller treats empty trace as "no disclosure
        // worth showing"; the filter just reports what it saw.
        var f = ThinkBlockFilter()
        let out = f.ingest("<think></think>The reply.")
        try expectEqual(out, "The reply.")
        try expectEqual(f.capturedTrace, "")
    }

    s.test("whitespace-only <think> — capturedTrace preserves the whitespace verbatim") {
        // The caller (AppState) decides whether to discard. Filter
        // stays honest about what it saw so the test of "what's a
        // meaningful trace?" lives in one place upstream.
        var f = ThinkBlockFilter()
        let out = f.ingest("<think>   \n  </think>The reply.")
        try expectEqual(out, "The reply.")
        try expectEqual(f.capturedTrace, "   \n  ")
    }

    s.test("multi-chunk: open tag splits across chunks") {
        var f = ThinkBlockFilter()
        var out = ""
        out += f.ingest("<thi")
        out += f.ingest("nk>plan A</think>Body.")
        try expectEqual(out, "Body.")
        try expectEqual(f.capturedTrace, "plan A")
    }

    s.test("multi-chunk: close tag splits across chunks") {
        var f = ThinkBlockFilter()
        var out = ""
        out += f.ingest("<think>plan B</thi")
        out += f.ingest("nk>Body.")
        try expectEqual(out, "Body.")
        try expectEqual(f.capturedTrace, "plan B")
    }

    s.test("multi-chunk: trace itself splits across chunks") {
        var f = ThinkBlockFilter()
        var out = ""
        out += f.ingest("<think>plan ")
        out += f.ingest("with multiple ")
        out += f.ingest("chunks</think>Body.")
        try expectEqual(out, "Body.")
        try expectEqual(f.capturedTrace, "plan with multiple chunks")
    }

    s.test("multi-line trace preserved verbatim") {
        var f = ThinkBlockFilter()
        let out = f.ingest("<think>line one\nline two\n  line three</think>Body.")
        try expectEqual(out, "Body.")
        try expectEqual(f.capturedTrace, "line one\nline two\n  line three")
    }

    s.test("flush on unterminated <think> — capturedTrace holds the partial") {
        // Broken model output: <think> opens, stream ends mid-trace.
        // Caller surfaces "[unterminated <think>… block]" as the body
        // (existing behaviour). We *also* keep what we accumulated so
        // the user can see the partial trace via the disclosure pill.
        var f = ThinkBlockFilter()
        _ = f.ingest("<think>started reasoning but the conn dropped")
        let flushed = f.flush()
        try expectTrue(flushed.contains("unterminated"))
        try expectEqual(f.capturedTrace, "started reasoning but the conn dropped")
    }

    s.test("capturedTrace stays empty when filter never sees <think>") {
        // Even after flush(), if the prefix never opened with <think>,
        // capturedTrace stays "". Caller can rely on this to skip
        // writing thinkingTrace when nothing was thought.
        var f = ThinkBlockFilter()
        _ = f.ingest("Hello, world.")
        _ = f.flush()
        try expectEqual(f.capturedTrace, "")
    }

    return s
}
