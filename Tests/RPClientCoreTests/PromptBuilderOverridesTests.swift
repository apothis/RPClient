import Foundation
@testable import RPClientCore

// Phase 10 §10.c — tests for the chat-path consumption of
// `ChatPathOverrides`. PromptBuilder.groupNudge gains a `style` +
// `xToX` parameter; PromptBuilder.build accepts an `overrides:`
// parameter that propagates groupNudgeStyle into the rendered nudge
// and stopSequenceAugmentation into the returned stops.
//
// Per-EXACT-model isolation regression-test: a build call for one
// chat (whose server is loaded with model A) sees model A's
// overrides, not model B's. The store keying invariant is verified
// in ModelCapabilitiesTests; here we verify the consumption side
// uses the lookup correctly.
func promptBuilderOverridesTests() -> TestSuite {
    let s = TestSuite("PromptBuilderOverrides")

    // MARK: - groupNudge variants

    s.test("groupNudge .standard renders the production line") {
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .standard, xToX: false)
        try expectEqual(n, "[Write the next reply only as Cass.]")
    }

    s.test("groupNudge .strong renders the silence directive") {
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .strong, xToX: false)
        try expectTrue(n.contains("speaks now"))
        try expectTrue(n.contains("silent"))
    }

    s.test("groupNudge .continuing falls back to standard on X→Y") {
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .continuing, xToX: false)
        try expectEqual(n, "[Write the next reply only as Cass.]")
    }

    s.test("groupNudge .continuing emits Continuing-as on X→X") {
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .continuing, xToX: true)
        try expectEqual(n, "[Continuing as Cass.]")
    }

    s.test("groupNudge .stopAugment leaves the nudge text alone") {
        // The stop-augment variant changes stops, NOT the nudge text —
        // assembly path appends extras to stopSequences, not in-prompt.
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .stopAugment, xToX: false)
        try expectEqual(n, "[Write the next reply only as Cass.]")
    }

    s.test("groupNudge .strongStop renders the strong text") {
        let n = PromptBuilder.groupNudge(activeSpeakerName: "Cass", style: .strongStop, xToX: false)
        try expectTrue(n.contains("speaks now"))
    }

    // MARK: - PromptBuilder.build wires the override through

    /// Build a 3-cast multi-character chat where the LAST assistant
    /// turn was spoken by the active speaker (X→X case). This is the
    /// shape that triggers the `continuing` variant's swap.
    @MainActor
    func makeXToXChat() -> (chat: Chat, cast: [Character], activeId: UUID) {
        let cassId = UUID()
        let raeId = UUID()
        let alexId = UUID()
        let cass = Character(id: cassId, name: "Cass", description: "test")
        let rae = Character(id: raeId, name: "Rae", description: "test")
        let alex = Character(id: alexId, name: "Alex", description: "test")

        var chat = Chat(id: UUID(), title: "x", templateId: "qwen")
        chat.cast = [cassId, raeId, alexId]
        chat.characterId = cassId
        chat.speakerSelection = .roundRobin

        var u = Turn(role: .user, text: "Begin the scene.")
        var a1 = Turn(role: .assistant, text: "*Cass enters.*")
        a1.parentId = u.id
        a1.speakerId = cassId
        chat.turns = [u, a1]
        chat.activePath = [u.id, a1.id]
        return (chat, [cass, rae, alex], cassId)
    }

    s.test("PromptBuilder.build with default overrides renders standard nudge") {
        let (chat, cast, activeId) = makeXToXChat()
        let result = PromptBuilder.build(
            chat: chat,
            character: cast.first(where: { $0.id == activeId }),
            speakerId: activeId,
            cast: cast
        )
        try expectTrue(result.prompt.contains("[Write the next reply only as Cass.]"))
    }

    s.test("PromptBuilder.build with continuing override on X→X uses Continuing-as") {
        let (chat, cast, activeId) = makeXToXChat()
        var overrides = ChatPathOverrides()
        overrides.groupNudgeStyle = .continuing
        let result = PromptBuilder.build(
            chat: chat,
            character: cast.first(where: { $0.id == activeId }),
            speakerId: activeId,
            cast: cast,
            overrides: overrides
        )
        try expectTrue(result.prompt.contains("[Continuing as Cass.]"))
        try expectFalse(result.prompt.contains("[Write the next reply only as Cass.]"))
    }

    s.test("PromptBuilder.build with stop-augment style auto-adds cohabitant stops") {
        let (chat, cast, activeId) = makeXToXChat()
        var overrides = ChatPathOverrides()
        overrides.groupNudgeStyle = .stopAugment
        let result = PromptBuilder.build(
            chat: chat,
            character: cast.first(where: { $0.id == activeId }),
            speakerId: activeId,
            cast: cast,
            overrides: overrides
        )
        // Cohabitants are Rae + Alex; both newline-prefixed and bare
        // forms should land in stops (caught the model leading with
        // "Name:" with or without a newline).
        try expectTrue(result.stops.contains("\nRae:"))
        try expectTrue(result.stops.contains("Rae:"))
        try expectTrue(result.stops.contains("\nAlex:"))
        try expectTrue(result.stops.contains("Alex:"))
    }

    s.test("PromptBuilder.build with explicit stopSequenceAugmentation appends those") {
        let (chat, cast, activeId) = makeXToXChat()
        var overrides = ChatPathOverrides()
        overrides.stopSequenceAugmentation = ["\nNarrator:", "[END]"]
        let result = PromptBuilder.build(
            chat: chat,
            character: cast.first(where: { $0.id == activeId }),
            speakerId: activeId,
            cast: cast,
            overrides: overrides
        )
        try expectTrue(result.stops.contains("\nNarrator:"))
        try expectTrue(result.stops.contains("[END]"))
    }

    s.test("PromptBuilder.build solo chat ignores groupNudgeStyle (no nudge emitted)") {
        // Solo chats don't get a group-nudge at all (PromptBuilder
        // only emits the nudge when isMultiCast). Setting
        // groupNudgeStyle on a solo chat's record is a no-op —
        // verifies we don't accidentally inject the directive on a
        // chat that doesn't need it.
        var chat = Chat(id: UUID(), title: "solo", templateId: "qwen")
        let cid = UUID()
        chat.characterId = cid
        let char = Character(id: cid, name: "Mira", description: "test")
        var u = Turn(role: .user, text: "Hi.")
        chat.turns = [u]
        chat.activePath = [u.id]

        var overrides = ChatPathOverrides()
        overrides.groupNudgeStyle = .strong  // would be loud if injected
        let result = PromptBuilder.build(
            chat: chat,
            character: char,
            speakerId: nil,    // solo path
            cast: [],
            overrides: overrides
        )
        try expectFalse(result.prompt.contains("speaks now"))
        try expectFalse(result.prompt.contains("silent for this turn"))
        try expectFalse(result.prompt.contains("[Continuing as"))
        try expectFalse(result.prompt.contains("[Write the next reply only as"))
    }

    return s
}
