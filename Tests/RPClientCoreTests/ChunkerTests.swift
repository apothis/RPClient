import Foundation
@testable import RPClientCore

func chunkerTests() -> TestSuite {
    let s = TestSuite("Chunker")

    func chat(turnCount: Int) -> Chat {
        var c = Chat()
        c.turns = (0..<turnCount).map { i in
            Turn(role: i.isMultiple(of: 2) ? .user : .assistant, text: "turn-\(i)")
        }
        return c
    }

    s.test("returns empty for fewer than two turns") {
        try expectTrue(Chunker.chunks(for: chat(turnCount: 0)).isEmpty)
        try expectTrue(Chunker.chunks(for: chat(turnCount: 1)).isEmpty)
    }

    s.test("Chunk.embeddingText returns plain text when no blurb is present") {
        let c = Chunk(chatId: UUID(), firstTurnIdx: 0, lastTurnIdx: 3, text: "User: hi")
        try expectEqual(c.embeddingText, "User: hi")
    }

    s.test("Chunk.embeddingText prepends blurb when present") {
        var c = Chunk(chatId: UUID(), firstTurnIdx: 0, lastTurnIdx: 3, text: "User: hi")
        c.contextBlurb = "Sarah is at the stadium."
        try expectEqual(c.embeddingText, "Sarah is at the stadium.\n\nUser: hi")
    }

    s.test("Chunk.embeddingText ignores whitespace-only blurb") {
        var c = Chunk(chatId: UUID(), firstTurnIdx: 0, lastTurnIdx: 3, text: "User: hi")
        c.contextBlurb = "  \n  "
        try expectEqual(c.embeddingText, "User: hi")
    }

    s.test("windows slide with one-turn overlap (window=4 stride=3)") {
        let chunks = Chunker.chunks(for: chat(turnCount: 8))
        let ranges = chunks.map { "\($0.firstTurnIdx)-\($0.lastTurnIdx)" }
        try expectEqual(ranges, ["0-3", "3-6", "6-7"])
    }

    s.test("trailing partial window emitted when at least 2 turns") {
        let chunks = Chunker.chunks(for: chat(turnCount: 5))
        try expectEqual(chunks.count, 2)
        try expectEqual(chunks.last?.firstTurnIdx, 3)
        try expectEqual(chunks.last?.lastTurnIdx, 4)
    }

    s.test("trailing partial dropped if below minimum") {
        let chunks = Chunker.chunks(for: chat(turnCount: 4))
        try expectEqual(chunks.count, 1)
        try expectEqual(chunks[0].lastTurnIdx, 3)
    }

    s.test("chunk text includes role labels") {
        let chunks = Chunker.chunks(for: chat(turnCount: 2))
        try expectEqual(chunks.count, 1)
        let body = chunks[0].text
        try expectTrue(body.contains("User: turn-0"))
        try expectTrue(body.contains("Assistant: turn-1"))
    }

    return s
}
