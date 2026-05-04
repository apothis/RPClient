import Foundation
@testable import RPClientCore

func templateTests() -> TestSuite {
    let s = TestSuite("Templates")

    s.test("byId falls back to gemma for unknown id") {
        try expectEqual(Templates.byId("nonsense").id, "gemma")
        try expectEqual(Templates.byId("gemma").id, "gemma")
        try expectEqual(Templates.byId("qwen").id, "qwen")
    }

    // MARK: - Gemma

    s.test("gemma wraps turns in role markers") {
        let out = GemmaTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [
                Turn(role: .user, text: "hello"),
                Turn(role: .assistant, text: "world"),
            ],
            continuation: false
        )
        try expectTrue(out.contains("<start_of_turn>user\nhello<end_of_turn>"))
        try expectTrue(out.contains("<start_of_turn>model\nworld<end_of_turn>"))
        try expectTrue(out.hasSuffix("<start_of_turn>model\n"))
    }

    s.test("gemma preamble attaches to the first user turn body") {
        let out = GemmaTemplate().assemble(
            memoryBlock: "MEM",
            entitiesBlock: nil,
            sceneSummaries: [SceneSummary(text: "scene-a", firstTurn: 0, lastTurn: 5)],
            summary: "SUM",
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [Turn(role: .user, text: "hi")],
            continuation: false
        )
        try expectTrue(out.contains("<start_of_turn>user\nMEM"))
        // Past-tense framing per MEMORY_AUDIT §4.1-B.
        try expectTrue(out.contains("[Earlier in the story — completed arc 1, turns 0–5]"))
        try expectTrue(out.contains("scene-a"))
        try expectTrue(out.contains("SUM"))
        try expectTrue(out.contains("\n\nhi<end_of_turn>"))
    }

    s.test("gemma scene block omits range when markers missing") {
        let out = GemmaTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [SceneSummary(text: "legacy")],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [Turn(role: .user, text: "hi")],
            continuation: false
        )
        try expectTrue(out.contains("[Earlier in the story — completed arc 1]"))
        try expectFalse(out.contains("turns "))
    }

    s.test("gemma current-scene anchor lands at the very tail of the last user turn") {
        let out = GemmaTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: "MEMS",
            tailMemoryDigest: "DIGEST",
            currentSceneAnchor: "ANCHOR",
            turns: [
                Turn(role: .user, text: "first"),
                Turn(role: .assistant, text: "reply"),
                Turn(role: .user, text: "latest"),
            ],
            continuation: false
        )
        // All extras land on the LAST user turn.
        try expectTrue(out.contains("MEMS"))
        try expectTrue(out.contains("DIGEST"))
        try expectTrue(out.contains("ANCHOR"))
        // Anchor must be the last block before the user turn closes.
        let userClose = "ANCHOR<end_of_turn>"
        try expectTrue(out.contains(userClose))
        // Order check: digest before anchor.
        guard let dRange = out.range(of: "DIGEST"),
              let aRange = out.range(of: "ANCHOR") else {
            throw TestFailure(message: "expected DIGEST and ANCHOR present", file: #file, line: #line)
        }
        try expectTrue(dRange.lowerBound < aRange.lowerBound, "digest must precede anchor")
    }

    s.test("gemma relevant memories attach only to last user turn, BEFORE the user text") {
        let out = GemmaTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: "MEMS",
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [
                Turn(role: .user, text: "first"),
                Turn(role: .assistant, text: "reply"),
                Turn(role: .user, text: "latest"),
            ],
            continuation: false
        )
        // First user turn must NOT carry the retrieval block.
        try expectFalse(out.contains("first\n\nMEMS"))
        try expectFalse(out.contains("MEMS\n\nfirst"))
        // Last user turn carries it BEFORE the user's actual text — this is
        // the fix for the "model starts a little before my message" symptom
        // (retrieval-shaped dialog appearing right before the gen marker).
        try expectTrue(out.contains("MEMS\n\nlatest"))
        try expectFalse(out.contains("latest\n\nMEMS"),
                        "retrieval must precede the user's actual message, not follow it")
    }

    s.test("gemma continuation leaves final assistant open") {
        let out = GemmaTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [
                Turn(role: .user, text: "u"),
                Turn(role: .assistant, text: "partial"),
            ],
            continuation: true
        )
        try expectTrue(out.hasSuffix("partial"))
        try expectFalse(out.hasSuffix("<end_of_turn>\n"))
    }

    // MARK: - Qwen

    s.test("qwen emits system block when preamble nonempty") {
        let out = QwenTemplate().assemble(
            memoryBlock: "MEM",
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [Turn(role: .user, text: "hi")],
            continuation: false
        )
        try expectTrue(out.hasPrefix("<|im_start|>system\nMEM<|im_end|>\n"))
    }

    s.test("qwen omits system block when preamble empty") {
        let out = QwenTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [Turn(role: .user, text: "hi")],
            continuation: false
        )
        try expectFalse(out.contains("<|im_start|>system"))
        try expectTrue(out.hasPrefix("<|im_start|>user\nhi"))
    }

    s.test("qwen ends with assistant scaffold unless continuation") {
        let out = QwenTemplate().assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [Turn(role: .user, text: "hi")],
            continuation: false
        )
        try expectTrue(out.hasSuffix("<|im_start|>assistant\n<think>\n\n</think>\n\n"))
    }

    s.test("qwen thinkingEnabled drops the empty <think> pre-fill") {
        let out = QwenTemplate(thinkingEnabled: true).assemble(
            memoryBlock: nil,
            entitiesBlock: nil,
            sceneSummaries: [],
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            relevantMemories: nil,
            tailMemoryDigest: nil,
            currentSceneAnchor: nil,
            turns: [
                Turn(role: .user, text: "hi"),
                Turn(role: .assistant, text: "yo"),
                Turn(role: .user, text: "again"),
            ],
            continuation: false
        )
        try expectTrue(out.hasSuffix("<|im_start|>assistant\n"))
        try expectFalse(out.contains("<think>"))
        // Past assistant turns also lose the pre-fill so the cache shape
        // matches what's now coming from the model itself.
        try expectTrue(out.contains("<|im_start|>assistant\nyo<|im_end|>\n"))
    }

    s.test("Templates.byId honours qwenThinking flag") {
        let off = Templates.byId("qwen", qwenThinking: false)
        let on = Templates.byId("qwen", qwenThinking: true)
        try expectEqual(off.id, "qwen")
        try expectEqual(on.id, "qwen")
        let empty: [Turn] = [Turn(role: .user, text: "u")]
        let outOff = off.assemble(memoryBlock: nil, entitiesBlock: nil, sceneSummaries: [],
                                  summary: nil, worldInfoHits: [], authorsNote: nil,
                                  relevantMemories: nil, tailMemoryDigest: nil,
                                  currentSceneAnchor: nil, turns: empty, continuation: false)
        let outOn = on.assemble(memoryBlock: nil, entitiesBlock: nil, sceneSummaries: [],
                                summary: nil, worldInfoHits: [], authorsNote: nil,
                                relevantMemories: nil, tailMemoryDigest: nil,
                                currentSceneAnchor: nil, turns: empty, continuation: false)
        try expectTrue(outOff.contains("<think>"))
        try expectFalse(outOn.contains("<think>"))
    }

    // MARK: - ThinkBlockFilter

    s.test("filter strips a contiguous <think> block at the head of the reply") {
        var f = ThinkBlockFilter()
        let out = f.ingest("<think>plan plan plan</think>\n\nHello there!")
        try expectEqual(out, "Hello there!")
        // Subsequent chunks pass through untouched.
        try expectEqual(f.ingest(" More."), " More.")
        try expectEqual(f.flush(), "")
    }

    s.test("filter handles tag split across chunks") {
        var f = ThinkBlockFilter()
        try expectEqual(f.ingest("<thi"), "")
        try expectEqual(f.ingest("nk>reasoning"), "")
        try expectEqual(f.ingest(" continues</th"), "")
        try expectEqual(f.ingest("ink>\n\nReply."), "Reply.")
    }

    s.test("filter passes through replies that don't open with <think>") {
        var f = ThinkBlockFilter()
        // First chunk doesn't start with `<` or whitespace — passthrough.
        try expectEqual(f.ingest("Direct reply, no thinking."), "Direct reply, no thinking.")
        try expectEqual(f.ingest(" Continued."), " Continued.")
    }

    s.test("filter tolerates leading whitespace before <think>") {
        var f = ThinkBlockFilter()
        try expectEqual(f.ingest("\n\n  <think>plan</think>\n\nReply."), "Reply.")
    }

    s.test("filter flush surfaces residue when stream cut mid-decision") {
        var f = ThinkBlockFilter()
        // "<th" alone could grow into either <think> or "<thanks!" — buffered.
        try expectEqual(f.ingest("<th"), "")
        // Stream ends here — residue must surface so the user sees something.
        try expectEqual(f.flush(), "<th")
    }

    s.test("filter flush flags unterminated think block") {
        var f = ThinkBlockFilter()
        try expectEqual(f.ingest("<think>open with no close"), "")
        let tail = f.flush()
        try expectTrue(tail.contains("unterminated"))
    }

    s.test("filter trims leading whitespace from the chunk after </think>") {
        // Repro for the bug where </think> landing at the very end of one
        // chunk left the next chunk's "\n\n" padding leaking through as if
        // it were reply content.
        var f = ThinkBlockFilter()
        try expectEqual(f.ingest("<think>plan</think>"), "")
        try expectEqual(f.ingest("\n\nReply."), "Reply.")
        // Subsequent chunks pass through unchanged — only the first
        // post-close chunk gets the trim.
        try expectEqual(f.ingest("\n\n more"), "\n\n more")
    }

    s.test("filter trim flag waits past an all-whitespace chunk") {
        var f = ThinkBlockFilter()
        try expectEqual(f.ingest("<think>x</think>"), "")
        try expectEqual(f.ingest("   \n"), "")
        try expectEqual(f.ingest("\n  Reply."), "Reply.")
    }

    s.test("filter exposes isInsideThinkBlock for UI binding") {
        var f = ThinkBlockFilter()
        try expectFalse(f.isInsideThinkBlock)
        _ = f.ingest("<think>")
        try expectTrue(f.isInsideThinkBlock)
        _ = f.ingest("reasoning")
        try expectTrue(f.isInsideThinkBlock)
        _ = f.ingest("</think>\n\nReply")
        try expectFalse(f.isInsideThinkBlock)
    }

    return s
}
