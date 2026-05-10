import Foundation
@testable import RPClientCore

/// Phase 8 §4.4 — DirectorPicker async LLM router for `.director` mode.
///
/// Pure tests with a stub `KoboldGenerating` that returns canned response
/// strings. Verifies the parse path handles common LLM response shapes
/// (bare name, name with trailing punctuation, name embedded in a longer
/// reply) plus the failure-mode fallback contract (unparseable text /
/// network error / empty cast all return nil so AppState falls back to
/// round-robin).
func directorPickerTests() -> TestSuite {
    let s = TestSuite("DirectorPicker")

    // MARK: - Stub kobold for sync result delivery

    final class StubKobold: KoboldGenerating {
        var nextResult: Result<String, Error>
        var lastPrompt: String?
        init(_ result: Result<String, Error>) { self.nextResult = result }
        func generate(
            prompt: String,
            stopSequences: [String],
            preset: SamplerPreset,
            maxContextLength: Int,
            grammar: String?,
            maxLengthOverride: Int?,
            completion: @escaping (Result<String, Error>) -> Void
        ) {
            lastPrompt = prompt
            completion(nextResult)
        }
    }

    enum StubError: Error { case mock }

    func twoCast() -> (Chat, [Character]) {
        let anna = Character(name: "Anna", description: "scholar")
        let sarah = Character(name: "Sarah", description: "diplomat")
        var chat = Chat(title: "test")
        chat.cast = [anna.id, sarah.id]
        chat.speakerSelection = .director
        var u = Turn(role: .user, text: "Sarah, what do you think?")
        chat.turns = [u]
        chat.activePath = [u.id]
        return (chat, [anna, sarah])
    }

    // MARK: - Parse cases

    s.test("director picks the cast member named in a clean LLM response") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("Sarah"))
        var picked: UUID?
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectEqual(picked, cast[1].id)
    }

    s.test("director tolerates trailing punctuation and whitespace") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("  Anna.\n"))
        var picked: UUID?
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectEqual(picked, cast[0].id)
    }

    s.test("director extracts a cast name from a verbose response") {
        // Models occasionally narrate their pick rather than emit just
        // the name. Word-boundary substring match against cast names is
        // good enough for the common case.
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("I think Sarah should reply next."))
        var picked: UUID?
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectEqual(picked, cast[1].id)
    }

    s.test("director returns nil when response names no cast member") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("Bob the stranger"))
        var picked: UUID? = UUID()  // sentinel — should be overwritten with nil
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectNil(picked)
    }

    s.test("director returns nil on generation error") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.failure(StubError.mock))
        var picked: UUID? = UUID()
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectNil(picked)
    }

    s.test("director returns nil on empty cast") {
        var chat = Chat(title: "empty")
        chat.cast = []
        let kobold = StubKobold(.success("anything"))
        var picked: UUID? = UUID()
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: [], kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectNil(picked)
    }

    s.test("director prefers a later substring match over an earlier one") {
        // When the response mentions both names ("Anna asked Sarah to
        // speak"), the later (closer to the verb-of-speaking) wins —
        // matches the natural reading of "X said Y should speak".
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("Anna asked Sarah to speak"))
        var picked: UUID?
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectEqual(picked, cast[1].id)
    }

    s.test("director substring match is case-insensitive") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("sarah"))
        var picked: UUID?
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { p in
            picked = p
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        try expectEqual(picked, cast[1].id)
    }

    s.test("director prompt includes cast names and conversation tail") {
        let (chat, cast) = twoCast()
        let kobold = StubKobold(.success("Anna"))
        let done = DispatchSemaphore(value: 0)
        DirectorPicker.next(chat: chat, cast: cast, kobold: kobold, effectiveCtx: 4096) { _ in
            done.signal()
        }
        _ = done.wait(timeout: .now() + 1)
        let prompt = kobold.lastPrompt ?? ""
        try expectTrue(prompt.contains("Anna"), "prompt missing Anna: \(prompt)")
        try expectTrue(prompt.contains("Sarah"), "prompt missing Sarah: \(prompt)")
        try expectTrue(prompt.contains("what do you think"),
                       "prompt missing user-turn tail: \(prompt)")
    }

    return s
}
