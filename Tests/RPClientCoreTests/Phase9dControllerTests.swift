import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — `CardSuggestionsController` state machine for the
/// §4.1 strip. Tests use a synchronous-completion stub
/// `KoboldGenerating` so the state machine can be driven
/// deterministically without spinning up URLSession.
private final class StubKoboldGenerating: KoboldGenerating, @unchecked Sendable {
    enum CompletionTiming { case immediate, queued }
    var responses: [Result<String, Error>]
    var capturedPrompts: [String] = []
    var capturedPresets: [SamplerPreset] = []
    private let timing: CompletionTiming
    private var queued: [() -> Void] = []

    init(responses: [Result<String, Error>], timing: CompletionTiming = .immediate) {
        self.responses = responses
        self.timing = timing
    }

    func generate(
        prompt: String,
        stopSequences: [String],
        preset: SamplerPreset,
        maxContextLength: Int,
        grammar: String?,
        maxLengthOverride: Int?,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async { [self] in
            capturedPrompts.append(prompt)
            capturedPresets.append(preset)
            guard !responses.isEmpty else {
                completion(.failure(NSError(domain: "Stub", code: 0)))
                return
            }
            let next = responses.removeFirst()
            switch timing {
            case .immediate:
                completion(next)
            case .queued:
                queued.append { completion(next) }
            }
        }
    }

    func flushQueued() {
        let pending = queued
        queued.removeAll()
        for cb in pending { cb() }
    }
}

func phase9dControllerTests() -> TestSuite {
    let s = TestSuite("Phase9dController")

    let draft = CardDraftSnapshot(
        tags: ["fantasy", "monstergirl"],
        fields: [.name: "Vexara"]
    )

    /// Drive the runloop briefly so DispatchQueue.main.async work
    /// from the stub kobold reaches the controller. Synchronous-style
    /// state-machine tests use this between actions.
    func pump() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Initial state

    s.test("initial state is .idle") {
        let stub = StubKoboldGenerating(responses: [])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        try expectEqual(ctrl.state, .idle)
    }

    // MARK: - Happy path: triad fires sequentially

    s.test("generate(draft:) walks through .generating(N,3) then lands .ready") {
        let stub = StubKoboldGenerating(responses: [
            .success("Literal candidate text."),
            .success("Creative candidate text."),
            .success("Terse candidate text."),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )

        var observed: [CardSuggestionsController.State] = []
        ctrl.onStateChange = { observed.append($0) }

        ctrl.generate(draft: draft)
        pump()

        // Expected sequence: .generating(0,3) (fired immediately) →
        // .generating(1,3), (2,3), (3,3) interleaved with the kobold
        // completions, then settling at .ready([3 candidates]).
        guard case .ready(let candidates) = ctrl.state else {
            try expectTrue(false, "expected .ready, got \(ctrl.state)")
            return
        }
        try expectEqual(candidates.count, 3)
        try expectEqual(candidates[0].style, .literal)
        try expectEqual(candidates[1].style, .creative)
        try expectEqual(candidates[2].style, .terse)

        // Each candidate's text matches the stub's response.
        try expectEqual(candidates[0].text, "Literal candidate text.")
        try expectEqual(candidates[1].text, "Creative candidate text.")
        try expectEqual(candidates[2].text, "Terse candidate text.")

        // We saw the .generating progression at least once before .ready.
        let sawGenerating = observed.contains(where: {
            if case .generating = $0 { return true }
            return false
        })
        try expectTrue(sawGenerating, "expected at least one .generating(N,3), got \(observed)")
    }

    s.test("templateAssemble wraps each prompt body before kobold sees it") {
        let stub = StubKoboldGenerating(responses: [
            .success("a"), .success("b"), .success("c"),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { body in "[ASSEMBLED]\n\(body)\n[/ASSEMBLED]" },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        try expectEqual(stub.capturedPrompts.count, 3)
        for p in stub.capturedPrompts {
            try expectTrue(p.hasPrefix("[ASSEMBLED]"))
            try expectTrue(p.hasSuffix("[/ASSEMBLED]"))
        }
    }

    s.test("each candidate's preset reflects its style's temperature") {
        let stub = StubKoboldGenerating(responses: [
            .success("a"), .success("b"), .success("c"),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        try expectEqual(stub.capturedPresets.count, 3)
        // Literal < Creative; Terse < Literal in maxLength.
        try expectGreaterThan(stub.capturedPresets[1].temperature, stub.capturedPresets[0].temperature)
        try expectLessThan(stub.capturedPresets[2].maxLength, stub.capturedPresets[0].maxLength)
    }

    // MARK: - Refusal-bearing candidate

    s.test("a refusal-shaped response lands as a candidate with refusal flag set") {
        let stub = StubKoboldGenerating(responses: [
            .success("Vexara coiled in the firelight, watching."),
            .success("As an AI language model, I cannot generate that."),
            .success("Brief candidate."),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        guard case .ready(let candidates) = ctrl.state else {
            try expectTrue(false, "expected .ready, got \(ctrl.state)"); return
        }
        try expectFalse(candidates[0].refusal.isRefusal)
        try expectTrue(candidates[1].refusal.isRefusal)
        try expectEqual(candidates[1].refusal.pattern, .qwenStyle)
        try expectFalse(candidates[2].refusal.isRefusal)
    }

    // MARK: - Failure path

    s.test("kobold error → state is .failed") {
        struct E: Error {}
        let stub = StubKoboldGenerating(responses: [.failure(E())])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        if case .failed = ctrl.state {
            // ok
        } else {
            try expectTrue(false, "expected .failed, got \(ctrl.state)")
        }
    }

    // MARK: - Cancellation

    s.test("cancel() during generation reverts to .idle and ignores late arrivals") {
        let stub = StubKoboldGenerating(
            responses: [
                .success("first"),
                .success("second"),
                .success("third"),
            ],
            timing: .queued
        )
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        // First request is queued; we haven't flushed yet so it's
        // still in flight.
        ctrl.cancel()
        try expectEqual(ctrl.state, .idle)

        // Now flush the queued completion; controller should drop it
        // because the generation id no longer matches.
        stub.flushQueued()
        pump()
        try expectEqual(ctrl.state, .idle, "post-cancel completion must not advance state")
    }

    // MARK: - markStale / refresh

    s.test("markStale on .ready preserves candidates as .stale") {
        let stub = StubKoboldGenerating(responses: [
            .success("a"), .success("b"), .success("c"),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()
        guard case .ready(let candidates) = ctrl.state else {
            try expectTrue(false, "expected .ready"); return
        }
        ctrl.markStale()
        try expectEqual(ctrl.state, .stale(candidates))
    }

    s.test("markStale on .idle is a no-op") {
        let stub = StubKoboldGenerating(responses: [])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.markStale()
        try expectEqual(ctrl.state, .idle)
    }

    s.test("refresh after .ready re-fires the triad with fresh draft") {
        let stub = StubKoboldGenerating(responses: [
            .success("a1"), .success("b1"), .success("c1"),
            .success("a2"), .success("b2"), .success("c2"),
        ])
        let ctrl = CardSuggestionsController(
            field: .description,
            generator: stub,
            templateAssemble: { $0 },
            effectiveCtx: 8192
        )
        ctrl.generate(draft: draft)
        pump()

        let newDraft = CardDraftSnapshot(
            tags: ["fantasy", "monstergirl", "explicit"],
            fields: [.name: "Vexara", .description: "..."]
        )
        ctrl.refresh(draft: newDraft)
        pump()
        guard case .ready(let candidates) = ctrl.state else {
            try expectTrue(false, "expected .ready after refresh"); return
        }
        try expectEqual(candidates.map(\.text), ["a2", "b2", "c2"])
    }

    return s
}
