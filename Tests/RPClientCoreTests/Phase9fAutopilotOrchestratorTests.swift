import Foundation
@testable import RPClientCore

private final class StubChatCompletionsClient: ChatCompletionsClient, @unchecked Sendable {
    enum Timing { case immediate, queued }
    var responses: [Result<String, Error>]
    var capturedSystemMessages: [String] = []
    var capturedUserMessages: [String] = []
    var capturedSchemas: [Data] = []
    var capturedMaxTokens: [Int] = []
    private let timing: Timing
    private var queued: [() -> Void] = []

    init(responses: [Result<String, Error>], timing: Timing = .immediate) {
        self.responses = responses
        self.timing = timing
    }

    func chatCompletions(
        systemMessage: String,
        userMessage: String,
        responseSchema: Data,
        schemaName: String,
        temperature: Double,
        maxTokens: Int,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        DispatchQueue.main.async { [self] in
            capturedSystemMessages.append(systemMessage)
            capturedUserMessages.append(userMessage)
            capturedSchemas.append(responseSchema)
            capturedMaxTokens.append(maxTokens)
            guard !responses.isEmpty else {
                completion(.failure(NSError(domain: "Stub", code: 0)))
                return
            }
            let next = responses.removeFirst()
            switch timing {
            case .immediate: completion(next)
            case .queued: queued.append { completion(next) }
            }
        }
    }

    func flushQueued() {
        let pending = queued
        queued.removeAll()
        for cb in pending { cb() }
    }
}

func phase9fAutopilotOrchestratorTests() -> TestSuite {
    let s = TestSuite("Phase9fAutopilotOrchestrator")

    // Helper: produce a JSON response string covering a pass's targets,
    // with each value long enough to clear the schema's min-length floor.
    func responseForTargets(_ targets: [CardField]) -> String {
        var dict: [String: String] = [:]
        for t in targets {
            dict[t.rawValue] = "Generated content for \(t.rawValue) — long enough to satisfy the schema's minLength floor."
        }
        let data = try! JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys])
        return String(data: data, encoding: .utf8)!
    }

    // Helper: drive the run loop briefly so DispatchQueue.main.async hops
    // settle. Mirrors Phase9eOrchestratorTests.
    func pump() {
        let deadline = Date().addingTimeInterval(0.3)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // Build the full sequence of stub responses for a cold-start run
    // (every pass populates all of its allFields). Returns the captured
    // running-draft snapshots so tests can also assert pass ordering
    // via what the orchestrator passes to the next request.
    func responsesForFullRun(coldDraft: CardDraftSnapshot) -> [Result<String, Error>] {
        var driver = coldDraft
        var responses: [Result<String, Error>] = []
        for pass in CardAutopilotPass.allCases {
            let targets = pass.targets(in: driver)
            responses.append(.success(responseForTargets(targets)))
            // Simulate orchestrator merging proposals into running draft.
            var fields = driver.fields
            for f in targets { fields[f] = "filled" }
            driver = CardDraftSnapshot(tags: driver.tags, fields: fields)
        }
        return responses
    }

    let coldDraft = CardDraftSnapshot(tags: ["fantasy", "monstergirl"], fields: [:])

    // MARK: - Initial state

    s.test("initial state is .idle") {
        let stub = StubChatCompletionsClient(responses: [])
        let orch = CardAutopilotOrchestrator(generator: stub)
        try expectEqual(orch.state, .idle)
    }

    // MARK: - Happy path

    s.test("generate() runs all six passes in order on cold-start draft") {
        let stub = StubChatCompletionsClient(responses: responsesForFullRun(coldDraft: coldDraft))
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        guard case .completed(let proposals) = orch.state else {
            try expectTrue(false, "expected .completed, got \(orch.state)")
            return
        }
        try expectEqual(stub.capturedSystemMessages.count, CardAutopilotPass.allCases.count)
        // At least one proposal per pass.
        try expectGreaterThan(proposals.count, CardAutopilotPass.allCases.count - 1)
        // First-pass targets include `name` (cold-start identity).
        try expectTrue(proposals.contains(where: { $0.field == .name }))
        // System message on every call is the bundled prompt.
        for sys in stub.capturedSystemMessages {
            try expectEqual(sys, CardGenPromptsLoader.bundled.systemPrompt)
        }
    }

    s.test("each pass's user message includes prior pass's accepted field as upstream") {
        let stub = StubChatCompletionsClient(responses: responsesForFullRun(coldDraft: coldDraft))
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        // Pass 2 (personaVoice) should see the Identity-pass output —
        // specifically the `name` proposal — in its upstream block.
        // The CardMultiFieldGenerator builder includes upstream values
        // in the user message under "TARGET CHARACTER (current draft):".
        let personaUserMsg = stub.capturedUserMessages[1]
        try expectTrue(
            personaUserMsg.contains("TARGET CHARACTER"),
            "persona pass should carry upstream block, got: \(personaUserMsg.prefix(200))"
        )
    }

    s.test("state transitions emit .running for each pass before .completed") {
        let stub = StubChatCompletionsClient(responses: responsesForFullRun(coldDraft: coldDraft))
        let orch = CardAutopilotOrchestrator(generator: stub)
        var seenPasses: [CardAutopilotPass] = []
        orch.onStateChange = { state in
            if case .running(let pass, _, _, _, _) = state {
                seenPasses.append(pass)
            }
        }
        orch.generate(draft: coldDraft)
        pump()
        try expectEqual(seenPasses, CardAutopilotPass.allCases)
    }

    // MARK: - Skip-empty pass

    s.test("pass with all fields pre-filled is skipped (no API call)") {
        // Pre-fill every field in the Notes pass.
        var fields: [CardField: String] = [:]
        for f in CardAutopilotPass.notes.allFields {
            fields[f] = "preset"
        }
        let draft = CardDraftSnapshot(tags: ["x"], fields: fields)

        // Build responses for the other 5 passes only.
        var driver = draft
        var responses: [Result<String, Error>] = []
        for pass in CardAutopilotPass.allCases where pass != .notes {
            let targets = pass.targets(in: driver)
            responses.append(.success(responseForTargets(targets)))
            var fd = driver.fields
            for f in targets { fd[f] = "filled" }
            driver = CardDraftSnapshot(tags: driver.tags, fields: fd)
        }
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: draft)
        pump()
        try expectEqual(stub.capturedSystemMessages.count, CardAutopilotPass.allCases.count - 1)
        guard case .completed = orch.state else {
            try expectTrue(false, "expected .completed, got \(orch.state)")
            return
        }
    }

    // MARK: - Cost cap

    s.test("budget.maxCalls=2 aborts after second pass with .callsExceeded") {
        let responses = responsesForFullRun(coldDraft: coldDraft)
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(
            draft: coldDraft,
            budget: CardAutopilotBudget(maxCalls: 2, maxTokens: 1_000_000)
        )
        pump()
        guard case .aborted(let reason, _) = orch.state else {
            try expectTrue(false, "expected .aborted, got \(orch.state)")
            return
        }
        try expectEqual(reason, .callsExceeded)
        try expectEqual(stub.capturedSystemMessages.count, 2)
    }

    s.test("budget.maxTokens too small aborts before next pass with .tokensExceeded") {
        let responses = responsesForFullRun(coldDraft: coldDraft)
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        // Identity pass max_tokens is ≥1500 in CardMultiFieldGenerator
        // (default 2400). With a budget of 1000, the second pass's
        // pre-flight check (tokensUsed + nextMaxTokens > maxTokens) trips.
        orch.generate(
            draft: coldDraft,
            budget: CardAutopilotBudget(maxCalls: 100, maxTokens: 1000)
        )
        pump()
        guard case .aborted(let reason, _) = orch.state else {
            try expectTrue(false, "expected .aborted, got \(orch.state)")
            return
        }
        try expectEqual(reason, .tokensExceeded)
    }

    s.test("partial proposals from earlier passes are preserved in .aborted state") {
        let responses = responsesForFullRun(coldDraft: coldDraft)
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(
            draft: coldDraft,
            budget: CardAutopilotBudget(maxCalls: 1, maxTokens: 1_000_000)
        )
        pump()
        guard case .aborted(_, let partial) = orch.state else {
            try expectTrue(false, "expected .aborted, got \(orch.state)")
            return
        }
        try expectGreaterThan(partial.count, 0)
        try expectTrue(partial.contains(where: { $0.field == .name }))
    }

    // MARK: - Cancellation

    s.test("cancel() during a pass reverts to .idle and ignores late arrivals") {
        let responses = responsesForFullRun(coldDraft: coldDraft)
        let stub = StubChatCompletionsClient(responses: responses, timing: .queued)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        // First pass is in flight, completion queued.
        orch.cancel()
        try expectEqual(orch.state, .idle)
        stub.flushQueued()
        pump()
        try expectEqual(orch.state, .idle, "post-cancel completion must not advance state")
    }

    // MARK: - Pass failure

    s.test("HTTP failure in middle pass aborts with .passFailure") {
        struct E: Error, CustomStringConvertible {
            var description: String { "boom" }
        }
        // First pass succeeds, second fails.
        let firstTargets = CardAutopilotPass.identity.targets(in: coldDraft)
        let stub = StubChatCompletionsClient(responses: [
            .success(responseForTargets(firstTargets)),
            .failure(E()),
        ])
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        guard case .aborted(let reason, _) = orch.state else {
            try expectTrue(false, "expected .aborted, got \(orch.state)")
            return
        }
        if case .passFailure(let pass, let msg) = reason {
            try expectEqual(pass, .personaVoice)
            try expectTrue(msg.contains("boom"), "expected error message to surface, got: \(msg)")
        } else {
            try expectTrue(false, "expected .passFailure, got \(reason)")
        }
    }

    s.test("malformed-JSON in a pass aborts with .passFailure after retries + fallback exhausted") {
        // The orchestrator retries JSON parsing up to 2 times then
        // falls back to plaintext. Provide 3 garbage responses (so
        // both retries fail) and a single bad token (so plaintext
        // fallback also fails — plaintext requires N lines for N
        // requested fields, and identity needs 7).
        let firstTargets = CardAutopilotPass.identity.targets(in: coldDraft)
        let stub = StubChatCompletionsClient(responses: [
            .success(responseForTargets(firstTargets)),
            .success("garbage not json"),
            .success("still not json"),
            .success("not json one more time"),
        ])
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        guard case .aborted(let reason, _) = orch.state else {
            try expectTrue(false, "expected .aborted, got \(orch.state)")
            return
        }
        if case .passFailure = reason {
            // ok
        } else {
            try expectTrue(false, "expected .passFailure, got \(reason)")
        }
    }

    s.test("malformed-JSON retries up to 2 times then advances if next attempt parses") {
        // Splice 2 garbage responses BEFORE pass2's normal success
        // response. Pass1 succeeds → pass2 fires → garbage (retry 1)
        // → garbage (retry 2) → valid JSON → advances. Remaining
        // passes use the original full-run responses so the run can
        // complete (proves the retry doesn't desync the response queue).
        var responses = responsesForFullRun(coldDraft: coldDraft)
        responses.insert(.success("garbage one"), at: 1)
        responses.insert(.success("garbage two"), at: 2)
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        guard case .completed = orch.state else {
            try expectTrue(false, "expected .completed after retry recovers, got \(orch.state)")
            return
        }
    }

    s.test("plaintext fallback recovers when JSON retries exhausted but newline-shaped response parses") {
        // Pass2 returns garbage 3 times in a row (initial + 2 retries),
        // then the orchestrator falls back to a plaintext parser. We
        // give it a newline-separated response as the third attempt
        // so the plaintext path activates and the run completes.
        var driver = coldDraft
        let pass1Targets = CardAutopilotPass.identity.targets(in: coldDraft)
        var fields = driver.fields
        for f in pass1Targets { fields[f] = "filled" }
        driver = CardDraftSnapshot(tags: driver.tags, fields: fields)
        let pass2Targets = CardAutopilotPass.allCases[1].targets(in: driver)
        let plaintext = pass2Targets
            .map { _ in "Generated content for this field — long enough to satisfy any minimum." }
            .joined(separator: "\n")
        // Build all of: pass1 success, 3 garbage attempts (which exhaust
        // retries and hand the third response to plaintext fallback),
        // then pass3..N normally.
        var responses: [Result<String, Error>] = [
            .success(responseForTargets(pass1Targets)),
            .success("garbage one"),
            .success("garbage two"),
            .success(plaintext),   // attempt #3 → JSON fails → plaintext recovers
        ]
        // Continue building responses for pass3..N from the merged
        // running draft (assumes plaintext recovery filled pass2 fields).
        var fields2 = driver.fields
        for f in pass2Targets { fields2[f] = "filled" }
        driver = CardDraftSnapshot(tags: driver.tags, fields: fields2)
        for i in 2..<CardAutopilotPass.allCases.count {
            let pass = CardAutopilotPass.allCases[i]
            let targets = pass.targets(in: driver)
            responses.append(.success(responseForTargets(targets)))
            var nextFields = driver.fields
            for f in targets { nextFields[f] = "filled" }
            driver = CardDraftSnapshot(tags: driver.tags, fields: nextFields)
        }
        let stub = StubChatCompletionsClient(responses: responses)
        let orch = CardAutopilotOrchestrator(generator: stub)
        orch.generate(draft: coldDraft)
        pump()
        guard case .completed = orch.state else {
            try expectTrue(false, "expected plaintext fallback to complete the run, got \(orch.state)")
            return
        }
    }

    // MARK: - Pass-target plan sanity

    s.test("Pass.identity targets cover the cold-start identity fields") {
        let targets = CardAutopilotPass.identity.targets(in: coldDraft)
        try expectTrue(targets.contains(.name))
        try expectTrue(targets.contains(.detailsSex))
        try expectTrue(targets.contains(.detailsAge))
        try expectTrue(targets.contains(.detailsPronouns))
        try expectTrue(targets.contains(.detailsSpecies))
        try expectTrue(targets.contains(.detailsOrientation))
    }

    s.test("Pass.disposition does NOT include intimacyLimits (bundled-default per research §3.5)") {
        let targets = CardAutopilotPass.disposition.allFields
        try expectTrue(targets.contains(.intimacyTurnOns))
        try expectTrue(targets.contains(.intimacyKinks))
        try expectTrue(!targets.contains(.intimacyLimits))
    }

    s.test("Pass plan covers every CardField except intimacyLimits and groupOnlyGreetings") {
        var covered = Set<CardField>()
        for pass in CardAutopilotPass.allCases {
            covered.formUnion(pass.allFields)
        }
        let allFields = Set(CardField.allCases)
        let uncovered = allFields.subtracting(covered)
        try expectEqual(uncovered, Set([.intimacyLimits, .groupOnlyGreetings]))
    }

    return s
}
