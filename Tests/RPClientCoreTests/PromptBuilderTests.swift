import Foundation
@testable import RPClientCore

func promptBuilderTests() -> TestSuite {
    let s = TestSuite("PromptBuilder")

    func makeChat(turns: [Turn] = [], summary: String = "", summarizedThrough: Int = 0) -> Chat {
        var c = Chat()
        c.turns = turns
        c.summary = summary
        c.summarizedThrough = summarizedThrough
        return c
    }

    s.test("verbatim returns all turns when summary is empty") {
        let chat = makeChat(
            turns: [Turn(role: .user, text: "a"), Turn(role: .assistant, text: "b")],
            summary: "",
            summarizedThrough: 5
        )
        try expectEqual(PromptBuilder.verbatimTurns(chat).map(\.text), ["a", "b"])
    }

    s.test("verbatim slices after summarizedThrough when summary present") {
        let chat = makeChat(
            turns: (0..<6).map { Turn(role: .user, text: "t\($0)") },
            summary: "rolled-up",
            summarizedThrough: 4
        )
        try expectEqual(PromptBuilder.verbatimTurns(chat).map(\.text), ["t4", "t5"])
    }

    s.test("verbatim clamps out-of-range summarizedThrough") {
        let chat = makeChat(
            turns: [Turn(role: .user, text: "a")],
            summary: "x",
            summarizedThrough: 99
        )
        try expectTrue(PromptBuilder.verbatimTurns(chat).isEmpty)
    }

    s.test("tail digest is nil when flag disabled") {
        var chat = makeChat()
        chat.memory = "facts"
        chat.tailReinforceMemory = false
        try expectNil(PromptBuilder.tailMemoryDigest(chat: chat))
    }

    s.test("tail digest is nil during continuation") {
        var chat = makeChat()
        chat.memory = "facts"
        chat.tailReinforceMemory = true
        try expectNil(PromptBuilder.tailMemoryDigest(chat: chat, continuation: true))
    }

    s.test("tail digest returns body for short memory") {
        var chat = makeChat()
        chat.memory = "alpha"
        chat.tailReinforceMemory = true
        let d = try expectNotNil(PromptBuilder.tailMemoryDigest(chat: chat))
        try expectTrue(d.contains("alpha"))
    }

    s.test("tail digest truncates long memory") {
        var chat = makeChat()
        chat.memory = String(repeating: "x", count: 5000)
        chat.tailReinforceMemory = true
        let d = try expectNotNil(PromptBuilder.tailMemoryDigest(chat: chat))
        try expectTrue(d.hasPrefix("[Reminder"))
        try expectLessThan(d.count, 1500)
    }

    s.test("formatRelevantMemories returns nil for empty hits") {
        try expectNil(PromptBuilder.formatRelevantMemories([]))
    }

    s.test("formatRelevantMemories emits blurb-only when contextual blurb is present") {
        // The contextual-retrieval payoff: with a blurb available, the
        // prompt receives the SUMMARY of the snippet, not the dialog
        // itself. The dialog is only used for embedding-time matching.
        // This kills the "wall of past dialog right before the gen marker
        // makes the model continue from inside it" failure mode.
        var chunk = Chunk(chatId: UUID(), firstTurnIdx: 4, lastTurnIdx: 7,
                          text: "User: hi there pal\n\nAssistant: hello yourself")
        chunk.contextBlurb = "Sarah and the user are at the stadium gate before the show."
        let formatted = try expectNotNil(PromptBuilder.formatRelevantMemories([
            VectorStore.Hit(chunk: chunk, score: 0.9)
        ]))
        try expectTrue(formatted.contains("Sarah and the user are at the stadium"),
                       "blurb must be present")
        try expectTrue(formatted.contains("turns 4–7"),
                       "turn range must be in the bullet")
        // The dialog must NOT reach the prompt when a blurb summarises it.
        try expectFalse(formatted.contains("hi there pal"),
                        "dialog must not be injected when a blurb covers the chunk")
        try expectFalse(formatted.contains("hello yourself"))
    }

    s.test("formatRelevantMemories falls back to capped dialog when blurb is missing") {
        // Legacy chunks (indexed before contextual retrieval shipped) still
        // have to render *something* — but capped so they can't dominate
        // the prompt the way the un-fixed flow did.
        let cap = PromptBuilder.legacyChunkInjectionCap
        let chunkText = "User: hello there\n\nAssistant: " + String(repeating: "lots of words ", count: 200)
        let chunk = Chunk(chatId: UUID(), firstTurnIdx: 0, lastTurnIdx: 3, text: chunkText)
        let formatted = try expectNotNil(PromptBuilder.formatRelevantMemories([
            VectorStore.Hit(chunk: chunk, score: 0.9)
        ]))
        // Line-start role prefixes are stripped (the chunker emits one role
        // per line), but the test only asserts on the strip — not on the
        // absence of every "User: " substring (which a long dialog can
        // contain via line continuation).
        try expectFalse(formatted.contains("User: hello"),
                        "User: line-start prefix must be stripped from legacy retrieved chunks")
        try expectFalse(formatted.contains("Assistant: lots"),
                        "Assistant: line-start prefix must be stripped from legacy retrieved chunks")
        try expectTrue(formatted.contains("turns 0–3"))
        try expectTrue(formatted.contains("…"),
                       "long legacy chunks must be truncated with an ellipsis")
        try expectLessThan(formatted.count, cap + 200)
    }

    s.test("formatRelevantMemories uses the new 'Recall' header") {
        let chunk = Chunk(chatId: UUID(), firstTurnIdx: 0, lastTurnIdx: 3, text: "x")
        let formatted = try expectNotNil(PromptBuilder.formatRelevantMemories([
            VectorStore.Hit(chunk: chunk, score: 0.9)
        ]))
        try expectTrue(formatted.contains("Recall —"),
                       "header must signal 'past, for continuity, not for continuation'")
    }

    // MARK: - Topic supersession (MEMORY_AUDIT §4.3-E)

    s.test("supersedeStaleFactsByTopic keeps newest clothing fact and drops older topless/wearing/etc") {
        let facts = [
            Fact(text: "Sarah is 25", addedTurn: 1, lastReinforcedTurn: 1),
            Fact(text: "Sarah is topless", addedTurn: 20, lastReinforcedTurn: 22),
            Fact(text: "Sarah is wearing only panties", addedTurn: 25, lastReinforcedTurn: 25),
            Fact(text: "Sarah is naked", addedTurn: 30, lastReinforcedTurn: 30),
        ]
        let kept = PromptBuilder.supersedeStaleFactsByTopic(facts)
        let texts = kept.map(\.text)
        try expectTrue(texts.contains("Sarah is 25"), "timeless attribute must survive")
        try expectTrue(texts.contains("Sarah is naked"), "newest clothing fact must survive")
        try expectFalse(texts.contains("Sarah is topless"), "older clothing fact must be superseded")
        try expectFalse(texts.contains("Sarah is wearing only panties"), "older clothing fact must be superseded")
    }

    s.test("supersedeStaleFactsByTopic keeps pinned older facts even when newer ones exist") {
        let facts = [
            Fact(text: "Sarah is topless", addedTurn: 20, lastReinforcedTurn: 20, pinnedByUser: true),
            Fact(text: "Sarah is naked", addedTurn: 30, lastReinforcedTurn: 30),
        ]
        let kept = PromptBuilder.supersedeStaleFactsByTopic(facts)
        let texts = kept.map(\.text)
        try expectTrue(texts.contains("Sarah is topless"), "user pinned the older fact — must survive")
        try expectTrue(texts.contains("Sarah is naked"))
    }

    s.test("supersedeStaleFactsByTopic preserves input order for kept facts") {
        let facts = [
            Fact(text: "Sarah is 25", addedTurn: 1, lastReinforcedTurn: 1),
            Fact(text: "Sarah likes Metallica", addedTurn: 2, lastReinforcedTurn: 2),
            Fact(text: "Sarah is naked", addedTurn: 30, lastReinforcedTurn: 30),
        ]
        let kept = PromptBuilder.supersedeStaleFactsByTopic(facts)
        try expectEqual(kept.map(\.text), facts.map(\.text))
    }

    s.test("factTopic detects clothing keywords and ignores timeless attributes") {
        try expectEqual(PromptBuilder.factTopic(of: "Sarah is naked"), "clothing")
        try expectEqual(PromptBuilder.factTopic(of: "Sarah is topless"), "clothing")
        try expectEqual(PromptBuilder.factTopic(of: "Sarah is wearing only panties"), "clothing")
        try expectEqual(PromptBuilder.factTopic(of: "Emily took off her shirt"), "clothing")
        try expectNil(PromptBuilder.factTopic(of: "Sarah is 25 years old"))
        try expectNil(PromptBuilder.factTopic(of: "Sarah works as a barista"))
        try expectNil(PromptBuilder.factTopic(of: "Sarah likes Metallica"))
    }

    s.test("entitiesBlock applies topic supersession end-to-end") {
        var chat = Chat()
        chat.entities = [
            Entity(name: "Sarah", type: .character, facts: [
                Fact(text: "Sarah is 25", addedTurn: 1, lastReinforcedTurn: 1),
                Fact(text: "Sarah is topless", addedTurn: 20, lastReinforcedTurn: 20),
                Fact(text: "Sarah is naked", addedTurn: 30, lastReinforcedTurn: 30),
            ])
        ]
        chat.turns = [Turn(role: .user, text: "I run my hands over Sarah")]
        let block = try expectNotNil(PromptBuilder.entitiesBlock(chat: chat))
        try expectTrue(block.contains("naked"))
        try expectFalse(block.contains("topless"))
        try expectTrue(block.contains("25"))
    }

    s.test("build returns the template's stop sequences") {
        var chat = makeChat(turns: [Turn(role: .user, text: "hi")])
        chat.templateId = "gemma"
        let (_, stops) = PromptBuilder.build(chat: chat)
        try expectEqual(stops, GemmaTemplate().stopSequences)
    }

    s.test("worldInfoHits returns header plus labelled matched entries' content") {
        var chat = makeChat(turns: [Turn(role: .user, text: "I draw the Mournbringer.")])
        chat.worldInfo = [
            WorldInfoEntry(name: "Mournbringer", keys: ["Mournbringer"], content: "humming blade"),
            WorldInfoEntry(name: "Dragon", keys: ["dragon"], content: "fire-breather"),
        ]
        let hits = PromptBuilder.worldInfoHits(chat: chat)
        try expectEqual(hits.count, 2)
        try expectEqual(hits[0], PromptBuilder.worldInfoHeader)
        try expectEqual(hits[1], "[Mournbringer]\nhumming blade")
    }

    s.test("worldInfoHits truncates content past entry's tokenCap") {
        var chat = makeChat(turns: [Turn(role: .user, text: "Mournbringer.")])
        let longContent = String(repeating: "alpha beta ", count: 50) // ~550 chars
        chat.worldInfo = [
            WorldInfoEntry(name: "M", keys: ["Mournbringer"], content: longContent, tokenCap: 10),
        ]
        let hits = PromptBuilder.worldInfoHits(chat: chat)
        // [header, "[M]\n<truncated body>"]
        try expectEqual(hits.count, 2)
        try expectTrue(hits[1].hasSuffix("…"), "expected ellipsis suffix")
        // body length excluding the "[M]\n" label
        let body = hits[1].split(separator: "\n", maxSplits: 1).last.map(String.init) ?? ""
        try expectTrue(body.count <= 10 * 4 + 1, "expected ≤ 41 chars, got \(body.count)")
    }

    s.test("worldInfoHits returns [] when no entries match") {
        var chat = makeChat(turns: [Turn(role: .user, text: "totally unrelated text")])
        chat.worldInfo = [WorldInfoEntry(name: "M", keys: ["sword"], content: "x")]
        try expectTrue(PromptBuilder.worldInfoHits(chat: chat).isEmpty)
    }

    s.test("build injects matched world-info into the prompt") {
        var chat = makeChat(turns: [Turn(role: .user, text: "Tell me about the Mournbringer.")])
        chat.templateId = "gemma"
        chat.worldInfo = [
            WorldInfoEntry(name: "Mournbringer", keys: ["Mournbringer"], content: "An ancient humming blade."),
            WorldInfoEntry(name: "Dragon", keys: ["dragon"], content: "Fire-breathing menace."),
        ]
        let (prompt, _) = PromptBuilder.build(chat: chat)
        try expectTrue(prompt.contains("An ancient humming blade."), "matched entry should be in the prompt")
        try expectTrue(!prompt.contains("Fire-breathing menace."), "non-matching entry should be absent")
    }

    s.test("truncateToCharCap leaves short text alone") {
        try expectEqual(PromptBuilder.truncateToCharCap("hi there", capChars: 100), "hi there")
    }

    s.test("truncateToCharCap word-aligns and adds ellipsis") {
        let out = PromptBuilder.truncateToCharCap("the quick brown fox", capChars: 12)
        try expectTrue(out.hasSuffix("…"))
        try expectTrue(out.count <= 13)
        try expectTrue(!out.contains("brown"), "should not include the word that crossed the cap")
    }

    s.test("truncateToCharCap returns empty for cap 0") {
        try expectEqual(PromptBuilder.truncateToCharCap("anything", capChars: 0), "")
    }

    // MARK: - composeMemoryBlock (Phase 3 §4.4 step 4b)

    s.test("composeMemoryBlock returns nil when nothing to inject") {
        let chat = Chat()
        try expectNil(PromptBuilder.composeMemoryBlock(chat: chat, character: nil, userName: ""))
    }

    s.test("composeMemoryBlock with no character returns chat.memory + userName line") {
        var chat = Chat()
        chat.memory = "Sarah loves Metallica."
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: nil, userName: "Kev"))
        try expectTrue(block.contains("The user's name is Kev."))
        try expectTrue(block.contains("Sarah loves Metallica."))
        // userName line must come before chat.memory.
        let nameRange = try expectNotNil(block.range(of: "The user's name is Kev."))
        let memRange = try expectNotNil(block.range(of: "Sarah loves Metallica."))
        try expectTrue(nameRange.lowerBound < memRange.lowerBound)
    }

    s.test("composeMemoryBlock with character but no system_prompt keeps chat.memory in both modes") {
        var chat = Chat()
        chat.memory = "user memory"
        var card = Character(name: "Nyx")
        card.description = "Mysterious."
        // override mode (default) — no system_prompt means nothing to override; memory rides through.
        let overrideBlock = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        try expectTrue(overrideBlock.contains("Description: Mysterious."))
        try expectTrue(overrideBlock.contains("user memory"))

        chat.systemPromptMode = .merge
        let mergeBlock = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        try expectTrue(mergeBlock.contains("Description: Mysterious."))
        try expectTrue(mergeBlock.contains("user memory"))
    }

    s.test("composeMemoryBlock override mode + system_prompt suppresses chat.memory") {
        var chat = Chat()
        chat.memory = "USER NOTES"
        chat.systemPromptMode = .override
        var card = Character(name: "Nyx")
        card.systemPrompt = "You are Nyx, a witch of the moor."
        card.description = "Quiet."
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        try expectTrue(block.contains("You are Nyx, a witch of the moor."))
        try expectTrue(block.contains("Description: Quiet."), "biographical prefix should still ride along")
        try expectFalse(block.contains("USER NOTES"), "override mode hides chat.memory when system_prompt present")
    }

    s.test("composeMemoryBlock merge mode + system_prompt keeps both chat.memory and system_prompt") {
        var chat = Chat()
        chat.memory = "USER NOTES"
        chat.systemPromptMode = .merge
        var card = Character(name: "Nyx")
        card.systemPrompt = "You are Nyx."
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        try expectTrue(block.contains("You are Nyx."))
        try expectTrue(block.contains("USER NOTES"))
        // system_prompt above chat.memory.
        let spRange = try expectNotNil(block.range(of: "You are Nyx."))
        let memRange = try expectNotNil(block.range(of: "USER NOTES"))
        try expectTrue(spRange.lowerBound < memRange.lowerBound)
    }

    s.test("composeMemoryBlock card prefix ordering: description, personality, scenario") {
        var chat = Chat()
        var card = Character(name: "Nyx")
        card.description = "DESC"
        card.personality = "PERS"
        card.scenario = "SCEN"
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        let d = try expectNotNil(block.range(of: "Description: DESC"))
        let p = try expectNotNil(block.range(of: "Personality: PERS"))
        let s = try expectNotNil(block.range(of: "Scenario: SCEN"))
        try expectTrue(d.lowerBound < p.lowerBound)
        try expectTrue(p.lowerBound < s.lowerBound)
        try expectTrue(block.contains(PromptBuilder.cardPrefixHeader))
    }

    s.test("composeMemoryBlock omits empty card fields without leaving stray separators") {
        var chat = Chat()
        var card = Character(name: "Nyx")
        card.description = "Just a desc."
        // personality + scenario both empty
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        try expectTrue(block.contains("Description: Just a desc."))
        try expectFalse(block.contains("Personality:"))
        try expectFalse(block.contains("Scenario:"))
    }

    s.test("composeMemoryBlock whitespace-only system_prompt is treated as absent") {
        var chat = Chat()
        chat.memory = "USER NOTES"
        chat.systemPromptMode = .override
        var card = Character(name: "Nyx")
        card.systemPrompt = "   \n  "
        let block = try expectNotNil(PromptBuilder.composeMemoryBlock(chat: chat, character: card, userName: ""))
        // Override is a no-op when the card has nothing to override with — chat.memory must survive.
        try expectTrue(block.contains("USER NOTES"))
    }

    s.test("build injects card system_prompt and biographical prefix into the prompt") {
        var chat = Chat()
        chat.templateId = "gemma"
        chat.turns = [Turn(role: .user, text: "hello")]
        var card = Character(name: "Nyx")
        card.systemPrompt = "You are Nyx."
        card.description = "Witch of the moor."
        let (prompt, _) = PromptBuilder.build(chat: chat, character: card)
        try expectTrue(prompt.contains("You are Nyx."))
        try expectTrue(prompt.contains("Description: Witch of the moor."))
    }

    return s
}
