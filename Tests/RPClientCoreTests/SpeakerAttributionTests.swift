import Foundation
@testable import RPClientCore

/// Phase 6 §7.3: per-line speaker attribution. Produces `[AttributedSegment]`
/// from a turn's plain text + the chat's entities, in one of two modes:
///
/// - **Heuristic** — matches `"…"` quoted spans to the most-recently-mentioned
///   entity in surrounding narration. Cheap, requires no model cooperation.
/// - **Tagged** — parses `^Name: …` lines against entity names + aliases.
///   Requires the model to follow the convention; produces cleaner attribution
///   when it does.
///
/// Pure logic. Output drives `Speaker.speakSegments(_:)` (§7.4b).
func speakerAttributionTests() -> TestSuite {
    let s = TestSuite("SpeakerAttribution")

    let sage = Entity(
        id: UUID(),
        name: "Sage",
        aliases: ["the mage"],
        type: .character
    )
    let kira = Entity(
        id: UUID(),
        name: "Kira",
        aliases: [],
        type: .character
    )

    // MARK: - Heuristic

    s.test("heuristic: empty text → empty segments") {
        let segs = SpeakerAttribution.split(text: "", entities: [sage, kira], mode: .heuristic)
        try expectEqual(segs, [])
    }

    s.test("heuristic: pure narration → one narrator segment") {
        let segs = SpeakerAttribution.split(
            text: "The room is quiet.",
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs, [AttributedSegment(text: "The room is quiet.", entityId: nil)])
    }

    s.test("heuristic: quoted span attributed to most-recently-mentioned entity") {
        let segs = SpeakerAttribution.split(
            text: #"Sage steps forward. "Hello there.""#,
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs.count, 2)
        try expectEqual(segs[0].text, "Sage steps forward. ")
        try expectEqual(segs[0].entityId, nil)
        try expectEqual(segs[1].text, "\"Hello there.\"")
        try expectEqual(segs[1].entityId, sage.id)
    }

    s.test("heuristic: alias matches as well as name") {
        let segs = SpeakerAttribution.split(
            text: #"The mage looks up. "I see.""#,
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs.last?.entityId, sage.id)
    }

    s.test("heuristic: most-recent mention wins when multiple entities are present") {
        let segs = SpeakerAttribution.split(
            text: #"Sage and Kira walk in. Kira waves. "Hi.""#,
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs.last?.entityId, kira.id)
    }

    s.test("heuristic: quoted span with no preceding mention falls back to narrator") {
        let segs = SpeakerAttribution.split(
            text: #""Who said that?" the room was empty."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs[0].entityId, nil)
    }

    s.test("heuristic: multiple quotes in one turn each get attributed independently") {
        // "X." is Sage's; later "Y." should attribute to Kira after she's mentioned.
        let segs = SpeakerAttribution.split(
            text: #"Sage smiled. "Hello." Kira nodded. "Hi.""#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.filter { $0.entityId != nil }
        try expectEqual(attributed.count, 2)
        try expectEqual(attributed[0].entityId, sage.id)
        try expectEqual(attributed[1].entityId, kira.id)
    }

    s.test("heuristic: smart quotes are recognised") {
        let segs = SpeakerAttribution.split(
            text: "Sage spoke. \u{201C}Hello.\u{201D}",
            entities: [sage, kira],
            mode: .heuristic
        )
        try expectEqual(segs.last?.entityId, sage.id)
    }

    s.test("heuristic: first-person markers attribute to the chat's character entity") {
        // The model's typical RP voice is the chat character speaking in
        // first person ("I felt..." / "I said..."). Without a hint, the
        // existing rule would attribute the quote to the most-recently-named
        // third-party entity. The first-person hint makes "I" win when no
        // third-person entity has been named more recently.
        let segs = SpeakerAttribution.split(
            text: #"I felt nervous. "Hello.""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        try expectEqual(segs.last?.entityId, kira.id)
    }

    s.test("heuristic: third-person mention more recent than 'I' wins") {
        // "I felt nervous as Sage approached. \"Hi, Sage.\"" — Sage is named
        // *after* the "I", so the heuristic still reads this as third-person
        // (the AI character addressing Sage by name). The first-person hint
        // doesn't override a more-recent third-person mention.
        let segs = SpeakerAttribution.split(
            text: #"I felt nervous as Sage approached. "Hi.""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        try expectEqual(segs.last?.entityId, sage.id)
    }

    s.test("heuristic: 'I' wins when it appears more recently than any third-person mention") {
        let segs = SpeakerAttribution.split(
            text: #"Sage walked off. I sat there a while. "Hello.""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        try expectEqual(segs.last?.entityId, kira.id)
    }

    s.test("heuristic: first-person hint nil leaves behavior unchanged") {
        let segs = SpeakerAttribution.split(
            text: #"I felt nervous. "Hello.""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: nil
        )
        // No hint, no entity name in surrounding narration → narrator.
        try expectEqual(segs.last?.entityId, nil)
    }

    s.test("heuristic: word-bounded 'I' only — don't match 'I' inside other words") {
        // "Iron", "Ireland", "It" should not trigger first-person.
        let segs = SpeakerAttribution.split(
            text: #"Iron rusts. Ireland is wet. It's late. "Hello.""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        try expectEqual(segs.last?.entityId, nil)
    }

    s.test("heuristic: unmatched opening quote does not eat the rest of the text") {
        // Defensive: a stray `"` shouldn't blackhole all subsequent narration.
        let segs = SpeakerAttribution.split(
            text: #"Sage said "hi but the rest is narration."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        // Whatever the algorithm does with the dangling quote, the total
        // text must round-trip — every character of the input ends up in
        // some segment.
        let joined = segs.map(\.text).joined()
        try expectEqual(joined, #"Sage said "hi but the rest is narration."#)
    }

    // MARK: - Tagged

    s.test("tagged: line with matching name attributes the whole line content") {
        let segs = SpeakerAttribution.split(
            text: #"Sage: "Hello.""#,
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.count, 1)
        try expectEqual(segs[0].entityId, sage.id)
        try expectTrue(segs[0].text.contains("Hello."))
    }

    s.test("tagged: case-insensitive match against name") {
        let segs = SpeakerAttribution.split(
            text: "sage: hi.",
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, sage.id)
    }

    s.test("tagged: name match wins over alias") {
        // Both "Sage" and the alias "the mage" exist; line tagged with name.
        let segs = SpeakerAttribution.split(
            text: "Sage: hi.",
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, sage.id)
    }

    s.test("tagged: alias also matches") {
        let segs = SpeakerAttribution.split(
            text: "the mage: hi.",
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, sage.id)
    }

    s.test("tagged: untagged line is narrator") {
        let segs = SpeakerAttribution.split(
            text: "The room is silent.",
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, nil)
    }

    s.test("tagged: unknown name is narrator") {
        let segs = SpeakerAttribution.split(
            text: "Stranger: hello.",
            entities: [sage, kira],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, nil)
    }

    s.test("tagged: multi-line preserves per-line attribution") {
        let text = """
        Sage: Welcome.
        The lights flicker.
        Kira: Are you ready?
        """
        let segs = SpeakerAttribution.split(text: text, entities: [sage, kira], mode: .tagged)
        try expectEqual(segs.count, 3)
        try expectEqual(segs[0].entityId, sage.id)
        try expectEqual(segs[1].entityId, nil)
        try expectEqual(segs[2].entityId, kira.id)
    }

    s.test("tagged: no entities → everything is narrator") {
        let segs = SpeakerAttribution.split(
            text: "Sage: hi.",
            entities: [],
            mode: .tagged
        )
        try expectEqual(segs.first?.entityId, nil)
    }

    return s
}
