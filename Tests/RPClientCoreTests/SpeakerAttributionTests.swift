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

    // MARK: - Dialogue-verb subject detection

    s.test("heuristic: post-quote dialogue verb attributes to the named subject") {
        // Quote-first pattern with no preceding context — without dialogue-verb
        // detection, this would fall to narrator.
        let segs = SpeakerAttribution.split(
            text: #""Hello," Sage said."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, sage.id)
    }

    s.test("heuristic: pre-quote dialogue verb attributes to the named subject") {
        let segs = SpeakerAttribution.split(
            text: #"Sage said, "Hello.""#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, sage.id)
    }

    s.test("heuristic: dialogue verb 'I said' attributes to first-person entity") {
        let segs = SpeakerAttribution.split(
            text: #""Hello," I said."#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, kira.id)
    }

    s.test("heuristic: 'I asked' before quote attributes to first-person entity") {
        let segs = SpeakerAttribution.split(
            text: #"I asked, "Are you ready?""#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, kira.id)
    }

    s.test("heuristic: dialogue verb beats most-recent mention rule") {
        // Sage was named most recently before the quote, but "Kira said"
        // immediately after tells us Kira is actually speaking.
        let segs = SpeakerAttribution.split(
            text: #"Sage walked over. "Hello," Kira said."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, kira.id)
    }

    s.test("heuristic: pronoun subject (she/he/they) falls through to most-recent rule") {
        // No name attached to "said" — fall back to most-recent rule, which
        // picks Sage from the preceding narration.
        let segs = SpeakerAttribution.split(
            text: #"Sage walked over. "Hello," she said."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, sage.id)
    }

    s.test("heuristic: a variety of dialogue verbs are recognised") {
        for verb in ["said", "asked", "replied", "whispered", "shouted", "exclaimed", "murmured", "answered"] {
            let segs = SpeakerAttribution.split(
                text: "\"Hi,\" Sage \(verb).",
                entities: [sage, kira],
                mode: .heuristic
            )
            let attributed = segs.first { $0.entityId != nil }
            try expectEqual(attributed?.entityId, sage.id, "verb='\(verb)'")
        }
    }

    s.test("heuristic: unknown subject after dialogue verb falls through") {
        // 'Stranger' isn't an entity. Ignore the dialogue verb and apply
        // most-recent rule — which picks Sage from the preceding text.
        let segs = SpeakerAttribution.split(
            text: #"Sage was nearby. "Hello," Stranger said."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, sage.id)
    }

    s.test("heuristic: bare 'I' after a quote attributes to first-person regardless of verb") {
        // English capitalisation makes bare `I` an unambiguous first-person
        // subject — when it appears as the first word right after a close
        // quote, the speaker is the AI character regardless of the action
        // verb that follows. Catches `"...," I begin / murmur / sigh / huff
        // / chuckle / ...` — verbs we'd otherwise have to enumerate in the
        // dialogue-verb list one by one.
        let segs = SpeakerAttribution.split(
            text: #""Hello," I begin, looking around."#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: kira.id
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, kira.id)
    }

    s.test("heuristic: 'I' short-circuit requires a first-person hint") {
        let segs = SpeakerAttribution.split(
            text: #""Hello," I begin, looking around."#,
            entities: [sage, kira],
            mode: .heuristic,
            firstPersonEntityId: nil
        )
        // No first-person hint → no attribution at all (no third-person
        // mention either, so it falls all the way to narrator).
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, nil)
    }

    s.test("heuristic: lookback caps at ~200 chars so far-earlier mentions don't dominate") {
        // Sage at the very start, then 600+ chars of narration with no
        // entity name, then a quote. The cap ensures the closer (no-name)
        // narration is what the attribution sees, not the long-stale Sage
        // mention. Without a hint or a third-person name in scope, the
        // attribution should fall through to narrator (entityId == nil).
        let earlyContext = "Sage walked into the room. "
            + String(repeating: "Time passed quietly without anyone speaking. ", count: 20)
        let segs = SpeakerAttribution.split(
            text: earlyContext + "\"Hello.\"",
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, nil)
    }

    s.test("heuristic: paragraph break scopes lookback to the current paragraph") {
        // Sage in paragraph 1; nothing identifying in paragraph 2. The
        // quote in paragraph 2 should not pick up Sage from across the
        // break. (Without scoping, Sage would still be the only mention
        // and would win.)
        let segs = SpeakerAttribution.split(
            text: "Sage waved goodbye and walked off.\n\nA pause. \"So long.\"",
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, nil)
    }

    s.test("heuristic: alias also matches as dialogue-verb subject") {
        // Sage's alias is "the mage". "the mage said" should attribute to Sage.
        let segs = SpeakerAttribution.split(
            text: #""Hello," the mage said."#,
            entities: [sage, kira],
            mode: .heuristic
        )
        let attributed = segs.first { $0.entityId != nil }
        try expectEqual(attributed?.entityId, sage.id)
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

    // MARK: - Phase 8 deferred polish — carry-forward attribution

    s.test("carry-forward: second quote with no nearby entity inherits from previous attributed quote") {
        // The bug case from a real user reproduction: long turn, two
        // Lyra quotes separated by an action beat (`*A dry, faint smile…*`)
        // that doesn't name her. The 200-char `scopedLookback` window
        // doesn't reach back to the original "Lyra rolls the wax seal"
        // narration → second quote falls to narrator default. With
        // carry-forward, the second quote inherits from the first's
        // Lyra attribution.
        let lyra = Entity(id: UUID(), name: "Lyra", type: .character)
        // First quote: Lyra is named directly before, so it attributes.
        // Then a long action beat (>200 chars) without naming Lyra so
        // the second quote's lookback window doesn't reach back to her
        // name. Carry-forward should fill that gap.
        let padding = String(repeating: "Action beat narration about the wind and waves and tide and channel. ", count: 4)
        let text = """
        Lyra rolls the wax seal flat against the damp wood, tracing a new benchmark with deliberate strokes. \
        "Fifty meters left before the channel straightens." \(padding)\
        "We'll drop anchor by moonrise."
        """
        let segs = SpeakerAttribution.split(
            text: text, entities: [lyra], mode: .heuristic, firstPersonEntityId: nil
        )
        // Both quotes should attribute to Lyra. Adjacent same-entity
        // segments coalesce, so we count distinct attributed regions
        // by walking the segments directly.
        let lyraSegments = segs.filter { $0.entityId == lyra.id }
        try expectGreaterThan(lyraSegments.count, 0)
        let firstQuoteRange = text.range(of: "\"Fifty meters")!
        let secondQuoteRange = text.range(of: "\"We'll drop anchor")!
        // The substrings of both quotes should appear in some Lyra segment.
        let lyraText = lyraSegments.map(\.text).joined()
        try expectTrue(lyraText.contains("Fifty meters left"),
                       "first quote not attributed to Lyra: \(segs.map { ($0.entityId == lyra.id ? "L" : "n") + ":" + $0.text.prefix(40) })")
        try expectTrue(lyraText.contains("We'll drop anchor"),
                       "second quote not carried forward to Lyra: \(segs.map { ($0.entityId == lyra.id ? "L" : "n") + ":" + $0.text.prefix(40) })")
        _ = firstQuoteRange; _ = secondQuoteRange  // shut up Swift's unused-let warning
    }

    s.test("carry-forward: explicit attribution beats carry-forward") {
        // If the second quote DOES have an entity in scope, that
        // attribution wins — carry-forward is fallback only, not
        // override. Two-character dialog must still attribute correctly.
        let alice = Entity(id: UUID(), name: "Alice", type: .character)
        let bob = Entity(id: UUID(), name: "Bob", type: .character)
        let text = """
        Alice spoke first. "Hello, Bob."
        Bob waved. "Hi there."
        """
        let segs = SpeakerAttribution.split(
            text: text, entities: [alice, bob], mode: .heuristic, firstPersonEntityId: nil
        )
        let aliceSegs = segs.filter { $0.entityId == alice.id }
        let bobSegs = segs.filter { $0.entityId == bob.id }
        try expectTrue(aliceSegs.map(\.text).joined().contains("Hello, Bob"))
        try expectTrue(bobSegs.map(\.text).joined().contains("Hi there"),
                       "Bob's quote should attribute to Bob via own lookback, not carry-forward Alice")
    }

    s.test("carry-forward: doesn't fire when no prior quote was attributed") {
        // First quote unattributed (no entity in lookback at all) → no
        // anchor for carry-forward → second quote also unattributed.
        // Carry-forward is "carry the LAST KNOWN speaker", not "carry
        // any nearby noun."
        let lyra = Entity(id: UUID(), name: "Lyra", type: .character)
        let text = """
        Someone walked into the room. "Quiet, please."
        Then someone else replied. "Sure thing."
        """
        let segs = SpeakerAttribution.split(
            text: text, entities: [lyra], mode: .heuristic, firstPersonEntityId: nil
        )
        // No entity in scope ever → all narrator (entityId nil), and
        // since they all share entityId, they coalesce into one big
        // segment.
        try expectEqual(segs.count, 1)
        try expectNil(segs[0].entityId)
    }

    return s
}
