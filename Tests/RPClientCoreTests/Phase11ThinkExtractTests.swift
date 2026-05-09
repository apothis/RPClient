import AppKit
import Foundation
@testable import RPClientCore

/// Phase 11 §4.b — `Markdown.extractThinking` separates the thinking
/// block from the body so the chat surface can render the body inline
/// AND surface a "Thought for Xs" disclosure for the thinking content.
///
/// Before §4.b the only consumer of thinking was `Markdown.stripThinking`,
/// which threw the content away. Non-UI callers (DirectorPicker, TTS,
/// Summariser, Blurber, side-call generators) still want strip-only;
/// extract is the chat-pane addition that keeps both halves.
///
/// **No-fork rule.** `stripThinking(s) == extractThinking(s).body` for
/// every input — the strip path is just a convenience wrapper.
func phase11ThinkExtractTests() -> TestSuite {
    let s = TestSuite("Phase11ThinkExtract")

    s.test("plain text — no think tags — returns (nil, body)") {
        let r = Markdown.extractThinking("Hello there.")
        try expectEqual(r.think, nil)
        try expectEqual(r.body, "Hello there.")
    }

    s.test("<think> block — returns (content, body-without-block)") {
        let r = Markdown.extractThinking("<think>weighing options</think>The answer is 42.")
        try expectEqual(r.think, "weighing options")
        try expectEqual(r.body, "The answer is 42.")
    }

    s.test("<thinking> variant — same shape") {
        let r = Markdown.extractThinking("<thinking>weighing</thinking>Done.")
        try expectEqual(r.think, "weighing")
        try expectEqual(r.body, "Done.")
    }

    s.test("Gemma <|begin_of_thought|> variant — same shape") {
        let r = Markdown.extractThinking("<|begin_of_thought|>plan<|end_of_thought|>OK.")
        try expectEqual(r.think, "plan")
        try expectEqual(r.body, "OK.")
    }

    s.test("empty <think></think> — returns (nil, body) per Phase 10 finding") {
        // V2_PHASE10_CHAT_TUNING_RESEARCH §A.1.1 — the empty pre-fill
        // is harmless on Qwen3.6 and shows up routinely. Suppressing
        // the disclosure keeps the chat surface quiet.
        let r = Markdown.extractThinking("<think></think>The reply.")
        try expectEqual(r.think, nil)
        try expectEqual(r.body, "The reply.")
    }

    s.test("whitespace-only <think>   \\n  </think> — returns (nil, body)") {
        let r = Markdown.extractThinking("<think>   \n  </think>The reply.")
        try expectEqual(r.think, nil)
        try expectEqual(r.body, "The reply.")
    }

    s.test("multiline thinking content preserved verbatim (modulo trim)") {
        let raw = "<think>line one\nline two\n  line three</think>The body."
        let r = Markdown.extractThinking(raw)
        try expectEqual(r.think, "line one\nline two\n  line three")
        try expectEqual(r.body, "The body.")
    }

    s.test("body text trimmed of leading/trailing whitespace (matches strip)") {
        let r = Markdown.extractThinking("<think>x</think>\n\n  body  \n")
        try expectEqual(r.body, "body")
    }

    s.test("multiple think blocks — first kept, all stripped from body") {
        // Models can emit multiple think segments on a single turn (rare
        // but observed). Surface the first as the disclosure (the other
        // segments would clutter); the body contains the prose between
        // and after them.
        let r = Markdown.extractThinking("<think>first</think>middle<think>second</think>end")
        try expectEqual(r.think, "first")
        // Body has neither block; "middle" + "end" survive.
        try expectTrue(!r.body.contains("<think"), "body still has tag: \(r.body)")
        try expectTrue(r.body.contains("middle"))
        try expectTrue(r.body.contains("end"))
    }

    s.test("no-fork rule — stripThinking(s) == extractThinking(s).body for all inputs") {
        let cases = [
            "plain text",
            "<think>x</think>body",
            "<thinking>y</thinking>body",
            "<|begin_of_thought|>z<|end_of_thought|>body",
            "<think></think>body",
            "<think>   </think>body",
            "<think>a</think>middle<think>b</think>end",
            "  body trim  ",
        ]
        for c in cases {
            try expectEqual(
                Markdown.stripThinking(c),
                Markdown.extractThinking(c).body,
                "diverged on input: \(c)"
            )
        }
    }

    return s
}
