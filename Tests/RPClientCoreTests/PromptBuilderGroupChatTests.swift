import Foundation
@testable import RPClientCore

/// Phase 8 §4.2b — PromptBuilder per-speaker assembly for multi-cast chats.
///
/// Pure tests on the prompt-building functions (no AppState, no LLM):
/// builds in-memory chats with explicit cast + speaker assignments and
/// checks the rendered prompt + per-speaker scene reads.
///
/// Covers:
/// - Cohabitant briefs (hybrid card scoping — full active card + brief
///   one-liners for other cast members) injected into the memory block.
/// - History formatting: name-prefix on each prior assistant turn (`Sarah:`).
/// - Cross-speaker reasoning stripping (`<think>…</think>` removed from
///   other speakers' turns; active speaker's own preserved).
/// - Group-nudge system message (`[Write the next reply only as X.]`)
///   appended at end-of-prompt with the active speaker's name.
/// - Lazy scene-summary read: when `SceneSummary.summariesBySpeaker[id]`
///   is populated, that text is used; absent → falls back to `text`.
/// - Solo / free-form chats (cast.count <= 1) behave as today.
func promptBuilderGroupChatTests() -> TestSuite {
    let s = TestSuite("PromptBuilderGroupChat")

    // Two-cast chat fixture: Anna (cast[0]), Sarah (cast[1]).
    // Returns (chat, anna, sarah).
    func twoCastFixture() -> (Chat, Character, Character) {
        let anna = Character(
            name: "Anna",
            description: "A scholar from the northern academy. Quick to anger but loyal once trusted.",
            personality: "studious",
            scenario: "Anna sits in the library."
        )
        let sarah = Character(
            name: "Sarah",
            description: "A cautious diplomat from the eastern reaches. Reads people before words.",
            personality: "diplomatic",
            scenario: "Sarah waits at the window."
        )
        var chat = Chat(title: "Library scene")
        chat.cast = [anna.id, sarah.id]
        // Spine of three turns: user, anna's greeting, user.
        var u1 = Turn(role: .user, text: "Hello.")
        var a1 = Turn(role: .assistant, text: "Welcome.")
        a1.speakerId = anna.id
        a1.parentId = u1.id
        var u2 = Turn(role: .user, text: "Sarah, what do you think?")
        u2.parentId = a1.id
        chat.turns = [u1, a1, u2]
        chat.activePath = [u1.id, a1.id, u2.id]
        return (chat, anna, sarah)
    }

    // MARK: - Cohabitant briefs (composeMemoryBlock)

    s.test("composeMemoryBlock with no cohabitants behaves as today (solo chat)") {
        let anna = Character(name: "Anna", description: "A scholar.")
        var chat = Chat(title: "x")
        chat.cast = [anna.id]
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: anna,
            userName: "User",
            cohabitants: []
        )
        // Whatever the block contains, the cohabitants section must be absent.
        try expectFalse((block ?? "").contains("Other characters present"))
    }

    s.test("composeMemoryBlock with cohabitants emits the briefs section") {
        let anna = Character(name: "Anna", description: "A scholar from the northern academy.")
        let sarah = Character(name: "Sarah", description: "A cautious diplomat from the eastern reaches.")
        var chat = Chat(title: "x")
        chat.cast = [anna.id, sarah.id]
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: anna,
            userName: "User",
            cohabitants: [sarah]
        )
        let body = block ?? ""
        try expectTrue(body.contains("Other characters present"), "missing cohabitants header in: \(body)")
        try expectTrue(body.contains("Sarah"), "missing cohabitant name in: \(body)")
        try expectTrue(body.contains("cautious diplomat"), "missing cohabitant brief in: \(body)")
    }

    s.test("cohabitant brief truncates each member to ~60 tokens (240 chars)") {
        // Description longer than 240 chars should get truncated.
        let longDesc = String(repeating: "A long description that runs on. ", count: 12)
        let lila = Character(name: "Lila", description: longDesc)
        let anna = Character(name: "Anna", description: "Scholar.")
        var chat = Chat(title: "x")
        chat.cast = [anna.id, lila.id]
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: anna,
            userName: "User",
            cohabitants: [lila]
        ) ?? ""
        // Find the line for Lila and check length.
        let lilaLine = block.components(separatedBy: "\n").first(where: { $0.contains("Lila") }) ?? ""
        try expectLessThan(lilaLine.count, 280)  // 240 char brief + ~40 char name+formatting overhead
    }

    s.test("cohabitant brief uses first sentence when description has multiple") {
        let lila = Character(name: "Lila", description: "A young thief with a sharp tongue. She can pick any lock. Born in the slums.")
        let anna = Character(name: "Anna", description: "Scholar.")
        var chat = Chat(title: "x")
        chat.cast = [anna.id, lila.id]
        let block = PromptBuilder.composeMemoryBlock(
            chat: chat,
            character: anna,
            userName: "User",
            cohabitants: [lila]
        ) ?? ""
        let lilaLine = block.components(separatedBy: "\n").first(where: { $0.contains("Lila") }) ?? ""
        try expectTrue(lilaLine.contains("sharp tongue"), "first sentence missing: \(lilaLine)")
        try expectFalse(lilaLine.contains("Born in the slums"), "subsequent sentences should be dropped: \(lilaLine)")
    }

    // MARK: - History transform (name prefix + reasoning strip)

    s.test("formatHistoryForSpeaker prefixes other speakers' assistant turns with their name") {
        let (chat, anna, _) = twoCastFixture()
        // We're generating for Sarah; Anna's prior turn should appear as
        // "Anna: Welcome." in Sarah's view.
        let sarah = Character(name: "Sarah")
        var sarahWithSarahId = sarah
        sarahWithSarahId = Character(id: chat.cast[1], name: "Sarah")
        let activeSpeakerId = chat.cast[1]  // Sarah
        let transformed = PromptBuilder.formatHistoryForSpeaker(
            turns: chat.turns,
            activeSpeakerId: activeSpeakerId,
            cast: [Character(id: anna.id, name: "Anna"), sarahWithSarahId]
        )
        // Find Anna's transformed turn — it's the assistant turn at index 1.
        try expectEqual(transformed[1].text, "Anna: Welcome.")
        // User turns are NOT prefixed.
        try expectEqual(transformed[0].text, "Hello.")
        try expectEqual(transformed[2].text, "Sarah, what do you think?")
    }

    s.test("formatHistoryForSpeaker does not prefix the active speaker's own prior turns") {
        // Three turns: user, Anna (active speaker), user. We're generating
        // for Anna — Anna's own prior turn should appear unprefixed.
        let (chat, anna, sarah) = twoCastFixture()
        let activeSpeakerId = chat.cast[0]  // Anna
        let transformed = PromptBuilder.formatHistoryForSpeaker(
            turns: chat.turns,
            activeSpeakerId: activeSpeakerId,
            cast: [Character(id: anna.id, name: "Anna"), Character(id: sarah.id, name: "Sarah")]
        )
        try expectEqual(transformed[1].text, "Welcome.")  // no "Anna: " prefix on own turn
    }

    s.test("formatHistoryForSpeaker strips <think>...</think> from other speakers' turns") {
        // Anna spoke with reasoning; Sarah is generating; Anna's reasoning
        // should be stripped from Sarah's view.
        let anna = Character(name: "Anna")
        let sarah = Character(name: "Sarah")
        var u = Turn(role: .user, text: "Q?")
        var aTurn = Turn(role: .assistant, text: "<think>I should answer carefully.</think>\nThe answer is X.")
        aTurn.speakerId = anna.id
        aTurn.parentId = u.id
        let turns = [u, aTurn]
        let transformed = PromptBuilder.formatHistoryForSpeaker(
            turns: turns,
            activeSpeakerId: sarah.id,
            cast: [anna, sarah]
        )
        try expectFalse(transformed[1].text.contains("<think>"), "think tag should be stripped from other speaker's turn: \(transformed[1].text)")
        try expectFalse(transformed[1].text.contains("answer carefully"), "think content should be stripped: \(transformed[1].text)")
        try expectTrue(transformed[1].text.contains("answer is X"), "reply content should survive: \(transformed[1].text)")
    }

    s.test("formatHistoryForSpeaker preserves active speaker's own <think>...</think>") {
        // Anna is generating; her own prior reasoning is preserved (it's
        // her own internal monologue, useful to her continuation).
        let anna = Character(name: "Anna")
        let sarah = Character(name: "Sarah")
        var u = Turn(role: .user, text: "Q?")
        var aTurn = Turn(role: .assistant, text: "<think>I'll explain.</think>\nThe answer is X.")
        aTurn.speakerId = anna.id
        aTurn.parentId = u.id
        let turns = [u, aTurn]
        let transformed = PromptBuilder.formatHistoryForSpeaker(
            turns: turns,
            activeSpeakerId: anna.id,
            cast: [anna, sarah]
        )
        try expectTrue(transformed[1].text.contains("<think>"), "active speaker's own think should be preserved: \(transformed[1].text)")
        try expectTrue(transformed[1].text.contains("I'll explain"), "active speaker's own reasoning content should be preserved: \(transformed[1].text)")
    }

    // MARK: - Group nudge

    s.test("groupNudge renders the canonical SillyTavern-style sysmsg") {
        let nudge = PromptBuilder.groupNudge(activeSpeakerName: "Anna")
        try expectEqual(nudge, "[Write the next reply only as Anna.]")
    }

    s.test("PromptBuilder.build for multi-cast chat appends the group nudge at end of prompt") {
        let (chat, anna, sarah) = twoCastFixture()
        let result = PromptBuilder.build(
            chat: chat,
            character: anna,
            persona: nil,
            speakerId: anna.id,
            cast: [anna, sarah]
        )
        // The group nudge with active speaker's name (Anna) must appear
        // somewhere near the end of the prompt — explicitly in the last
        // user turn's body so it's the closest signal to the model marker.
        try expectTrue(result.prompt.contains("[Write the next reply only as Anna.]"),
                       "group nudge missing from multi-cast prompt")
    }

    s.test("PromptBuilder.build for solo chat omits the group nudge") {
        let anna = Character(name: "Anna", description: "Scholar.")
        var chat = Chat(title: "Solo")
        chat.cast = [anna.id]
        var u = Turn(role: .user, text: "hi")
        chat.turns = [u]
        chat.activePath = [u.id]
        let result = PromptBuilder.build(
            chat: chat,
            character: anna,
            persona: nil,
            speakerId: anna.id,
            cast: [anna]
        )
        try expectFalse(result.prompt.contains("Write the next reply only as"),
                        "group nudge should NOT appear on solo chat: \(result.prompt)")
    }

    // MARK: - Multi-cast build round-trip — distinct prompts per speaker

    s.test("PromptBuilder.build produces distinct prompts when speakerId differs") {
        let (chat, anna, sarah) = twoCastFixture()
        let asAnna = PromptBuilder.build(
            chat: chat,
            character: anna,
            persona: nil,
            speakerId: anna.id,
            cast: [anna, sarah]
        ).prompt
        let asSarah = PromptBuilder.build(
            chat: chat,
            character: sarah,
            persona: nil,
            speakerId: sarah.id,
            cast: [anna, sarah]
        ).prompt
        // The two prompts must differ — different active speaker → different
        // card content + different group nudge name.
        try expect(asAnna != asSarah, "expected distinct prompts per speaker")
        try expectTrue(asAnna.contains("northern academy"), "Anna's prompt should include Anna's full description")
        try expectTrue(asSarah.contains("eastern reaches"), "Sarah's prompt should include Sarah's full description")
        try expectTrue(asAnna.contains("[Write the next reply only as Anna.]"))
        try expectTrue(asSarah.contains("[Write the next reply only as Sarah.]"))
    }

    // MARK: - Lazy scene-summary read

    s.test("renderableScenes returns summariesBySpeaker[speaker] when populated") {
        let speakerA = UUID()
        let speakerB = UUID()
        let scene = SceneSummary(
            text: "Narrator-view of the scene.",
            firstTurnId: nil,
            lastTurnId: nil
        )
        var sceneWithCache = scene
        sceneWithCache.summariesBySpeaker = [
            speakerA: "What A remembers.",
            speakerB: "What B remembers.",
        ]
        var chat = Chat(title: "x")
        chat.cast = [speakerA, speakerB]
        chat.sceneSummaries = [sceneWithCache]
        // Anchor with a turn so it isn't filtered for being orphan-on-branch.
        var u = Turn(role: .user, text: "hi")
        chat.turns = [u]
        chat.activePath = [u.id]
        sceneWithCache.firstTurnId = u.id
        sceneWithCache.lastTurnId = u.id
        chat.sceneSummaries = [sceneWithCache]

        let renderedForA = PromptBuilder.renderableScenes(chat: chat, speakerId: speakerA)
        let renderedForB = PromptBuilder.renderableScenes(chat: chat, speakerId: speakerB)
        try expectEqual(renderedForA.first?.text, "What A remembers.")
        try expectEqual(renderedForB.first?.text, "What B remembers.")
    }

    s.test("renderableScenes falls back to scene.text when summariesBySpeaker is missing entry") {
        let speakerA = UUID()
        let speakerB = UUID()
        var scene = SceneSummary(text: "Narrator-view of the scene.")
        scene.summariesBySpeaker = [speakerA: "What A remembers."]
        var chat = Chat(title: "x")
        chat.cast = [speakerA, speakerB]
        var u = Turn(role: .user, text: "hi")
        chat.turns = [u]
        chat.activePath = [u.id]
        scene.firstTurnId = u.id
        scene.lastTurnId = u.id
        chat.sceneSummaries = [scene]

        // B has no entry — should get the narrator-view fallback.
        let renderedForB = PromptBuilder.renderableScenes(chat: chat, speakerId: speakerB)
        try expectEqual(renderedForB.first?.text, "Narrator-view of the scene.")
    }

    s.test("renderableScenes with no speakerId (solo path) uses scene.text always") {
        let speakerA = UUID()
        var scene = SceneSummary(text: "Narrator-view of the scene.")
        scene.summariesBySpeaker = [speakerA: "What A remembers."]
        var chat = Chat(title: "x")
        var u = Turn(role: .user, text: "hi")
        chat.turns = [u]
        chat.activePath = [u.id]
        scene.firstTurnId = u.id
        scene.lastTurnId = u.id
        chat.sceneSummaries = [scene]

        // No speakerId → solo path; per-speaker cache is ignored.
        let rendered = PromptBuilder.renderableScenes(chat: chat)
        try expectEqual(rendered.first?.text, "Narrator-view of the scene.")
    }

    return s
}
