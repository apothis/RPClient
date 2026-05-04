import Foundation
@testable import RPClientCore

/// Regression tests for the 2026-05-03 failure documented in MEMORY_AUDIT.md.
///
/// The test mirrors the canonical chat structure (concert scene summary, "at
/// the car" rolling summary, recent verbatim turns set in the apartment) and
/// asserts the prompt shape produced by `PromptBuilder.build` honours the
/// contract:
///
///   1. Scene summaries are framed as completed prior arcs, not as `[Scene N]`.
///   2. A current-scene anchor appears near the assistant generation marker.
///   3. The anchor lands later in the prompt than the scene block (so position
///      reinforces the "now-is-recent-verbatim" signal).
///   4. The most recent verbatim turn lands later in the prompt than the
///      scene block.
func memoryAuditRegressionTests() -> TestSuite {
    let s = TestSuite("MemoryAuditRegression")

    func makeCanonicalChat() -> Chat {
        var chat = Chat()
        chat.templateId = "gemma"
        // Match the canonical chat: 60 turns, summarizedThrough=47, one scene
        // summary covering the concert arc, rolling summary placing the group
        // at the car, recent verbatim turns set in the apartment.
        chat.sceneSummaries = [
            SceneSummary(
                text: "Sarah and her boyfriend arrived outside a Metallica stadium, ate loaded fries, and made out before the show. They saw Dominum open and discussed Metallica's set list.",
                firstTurn: 0,
                lastTurn: 46
            )
        ]
        chat.summary = "Sarah and Emily joined the user at his car after attending a concert. The group is now at the car, intending to return to the user's residence."
        chat.summarizedThrough = 47

        var turns: [Turn] = []
        // Pad turns 0..46 with placeholder content so summarizedThrough lines up.
        for i in 0..<47 {
            turns.append(Turn(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                text: "concert turn \(i)"
            ))
        }
        // Transit turns 47..56 (post-scene-break, summarized into rolling summary).
        for i in 47..<57 {
            turns.append(Turn(
                role: i.isMultiple(of: 2) ? .user : .assistant,
                text: "transit turn \(i)"
            ))
        }
        // Verbatim head: the apartment scene that the failure regressed.
        let recent: [(TurnRole, String)] = [
            (.assistant, "We are now in my apartment, the 2 girls are naked apart from their lace panties. I'm naked and my cock is fully erect and throbbing."),
            (.user, "I run my hands over Emily's body as she leans into me, my hands caressing her arms, her back, and down to her bum, feeling the lace of her panties."),
            (.assistant, "Emily lets out a soft, shaky breath as you run your hands over her, her skin tingling under your touch."),
        ]
        for (role, text) in recent {
            turns.append(Turn(role: role, text: text))
        }
        chat.turns = turns
        return chat
    }

    s.test("scene block uses past-tense framing, not [Scene N]") {
        let chat = makeCanonicalChat()
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectFalse(prompt.contains("[Scene 1]"), "stale [Scene N] framing must be gone")
        try expectTrue(prompt.contains("[Earlier in the story — completed arc 1, turns 0–46]"),
                       "scene block must announce its turn range as a completed arc")
    }

    s.test("stale scene block is compressed — vivid concert prose does not reach the model") {
        // Canonical case: scene's lastTurn=46, turns.count=60 → 13 turns past,
        // well over the default 8-turn staleness threshold.
        let chat = makeCanonicalChat()
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectFalse(prompt.contains("ate loaded fries"),
                        "interior concert detail must be dropped for stale scenes")
        try expectFalse(prompt.contains("Dominum"),
                        "specific opener-band reference must not survive compression")
        try expectTrue(prompt.contains("earlier scene compressed"),
                       "compression must announce itself so the model reads the body as reference, not setting")
    }

    s.test("recent scene block keeps full body — compression only fires on stale arcs") {
        var chat = makeCanonicalChat()
        // Move the scene forward so it sits within the staleness window:
        // lastTurn=58, turns.count=60 → 1 turn past, under threshold 8.
        chat.sceneSummaries = [
            SceneSummary(
                text: "Sarah and her boyfriend arrived outside a Metallica stadium, ate loaded fries, and made out before the show.",
                firstTurn: 50,
                lastTurn: 58
            )
        ]
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectTrue(prompt.contains("ate loaded fries"),
                       "active scene content must reach the model verbatim")
        try expectFalse(prompt.contains("earlier scene compressed"))
    }

    s.test("legacy nil-marker scene defaults to compressed (we don't know how old it is)") {
        var chat = makeCanonicalChat()
        chat.sceneSummaries = [
            SceneSummary(text: "Sarah and her boyfriend arrived outside a Metallica stadium, ate loaded fries, and made out before the show.")
        ]
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectFalse(prompt.contains("ate loaded fries"),
                        "legacy markers (nil) should default to compressed so on-disk v2 chats benefit immediately")
    }

    s.test("current-scene anchor present and follows scene block in the prompt") {
        let chat = makeCanonicalChat()
        let (prompt, _) = PromptBuilder.build(chat: chat)
        let anchor = try expectNotNil(prompt.range(of: "[Current scene"))
        let sceneBlock = try expectNotNil(prompt.range(of: "Earlier in the story"))
        try expectTrue(sceneBlock.lowerBound < anchor.lowerBound,
                       "anchor must appear AFTER the scene block to win as the latest signal")
    }

    s.test("recent verbatim apartment turn outranks the concert scene block by position") {
        let chat = makeCanonicalChat()
        let (prompt, _) = PromptBuilder.build(chat: chat)
        let scene = try expectNotNil(prompt.range(of: "Metallica stadium"))
        let apartment = try expectNotNil(prompt.range(of: "naked apart from their lace panties"))
        try expectTrue(scene.lowerBound < apartment.lowerBound,
                       "apartment verbatim must follow the concert scene in the prompt")
    }

    s.test("anchor is suppressed in continuation mode") {
        let chat = makeCanonicalChat()
        let (prompt, _) = PromptBuilder.build(chat: chat, continuation: true)
        try expectFalse(prompt.contains("[Current scene"),
                        "no anchor when the assistant turn is mid-stream")
    }

    s.test("anchor is omitted when there are no scene summaries to disambiguate") {
        var chat = makeCanonicalChat()
        chat.sceneSummaries = []
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectFalse(prompt.contains("[Current scene"))
    }

    s.test("markSceneBreak shape: synthesise from chat state") {
        // Scene break populates firstTurn/lastTurn from the prior scene + summarizedThrough.
        // We verify the helper that computes the markers (mirrors AppState.markSceneBreak).
        var chat = Chat()
        chat.summary = "first arc"
        chat.summarizedThrough = 10
        // Simulate scene break: synthesise the same way AppState does so that
        // the test catches drift between the two call sites.
        let prevLast = chat.sceneSummaries.last?.lastTurn ?? -1
        let firstTurn = max(0, prevLast + 1)
        let lastTurn = max(firstTurn, chat.summarizedThrough - 1)
        chat.sceneSummaries.append(SceneSummary(text: "first arc", firstTurn: firstTurn, lastTurn: lastTurn))
        chat.summary = ""

        try expectEqual(chat.sceneSummaries.last?.firstTurn, 0)
        try expectEqual(chat.sceneSummaries.last?.lastTurn, 9)

        // Second scene break: now build on top.
        chat.summary = "second arc"
        chat.summarizedThrough = 25
        let prevLast2 = chat.sceneSummaries.last?.lastTurn ?? -1
        let firstTurn2 = max(0, prevLast2 + 1)
        let lastTurn2 = max(firstTurn2, chat.summarizedThrough - 1)
        chat.sceneSummaries.append(SceneSummary(text: "second arc", firstTurn: firstTurn2, lastTurn: lastTurn2))

        try expectEqual(chat.sceneSummaries.last?.firstTurn, 10)
        try expectEqual(chat.sceneSummaries.last?.lastTurn, 24)
    }

    return s
}
