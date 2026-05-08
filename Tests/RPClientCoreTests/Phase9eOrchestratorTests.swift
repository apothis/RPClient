import Foundation
@testable import RPClientCore

private final class StubChatCompletionsClient: ChatCompletionsClient, @unchecked Sendable {
    enum CompletionTiming { case immediate, queued }
    var responses: [Result<String, Error>]
    var capturedSchemas: [Data] = []
    var capturedSystemMessages: [String] = []
    var capturedUserMessages: [String] = []
    var capturedTemperatures: [Double] = []
    var capturedMaxTokens: [Int] = []
    private let timing: CompletionTiming
    private var queued: [() -> Void] = []

    init(responses: [Result<String, Error>], timing: CompletionTiming = .immediate) {
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
            capturedTemperatures.append(temperature)
            capturedMaxTokens.append(maxTokens)
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

func phase9eOrchestratorTests() -> TestSuite {
    let s = TestSuite("Phase9eMultiFieldOrchestrator")

    let draft = CardDraftSnapshot(
        tags: ["fantasy", "monstergirl"],
        fields: [.name: "Vexara"]
    )

    func pump() {
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    // MARK: - Initial state + happy path

    s.test("initial state is .idle") {
        let stub = StubChatCompletionsClient(responses: [])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        try expectEqual(orch.state, .idle)
    }

    s.test("fill(...) transitions through .fetching → .ready") {
        let stub = StubChatCompletionsClient(responses: [
            .success("""
                {"description": "A Lamia matriarch.", "personality": "Patient and watchful."}
            """),
        ])
        let orch = CardMultiFieldOrchestrator(generator: stub)

        var observed: [CardMultiFieldOrchestrator.State] = []
        orch.onStateChange = { observed.append($0) }

        orch.fill(fields: [.description, .personality], draft: draft)
        pump()

        guard case .ready(let proposals) = orch.state else {
            try expectTrue(false, "expected .ready, got \(orch.state)")
            return
        }
        try expectEqual(proposals.count, 2)
        try expectEqual(proposals[0].field, .description)
        try expectEqual(proposals[0].text, "A Lamia matriarch.")
        try expectEqual(proposals[1].field, .personality)

        let sawFetching = observed.contains(where: {
            if case .fetching = $0 { return true }
            return false
        })
        try expectTrue(sawFetching, "expected .fetching transition, got \(observed)")
    }

    s.test("empty fields is a no-op (no state change, no kobold call)") {
        let stub = StubChatCompletionsClient(responses: [])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [], draft: draft)
        pump()
        try expectEqual(orch.state, .idle)
        try expectEqual(stub.capturedSystemMessages.count, 0)
    }

    // MARK: - Failure paths

    s.test("HTTP error → state is .failed with the error description") {
        struct E: Error, CustomStringConvertible {
            var description: String { "boom" }
        }
        let stub = StubChatCompletionsClient(responses: [.failure(E())])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [.description], draft: draft)
        pump()
        guard case .failed(let msg) = orch.state else {
            try expectTrue(false, "expected .failed, got \(orch.state)")
            return
        }
        try expectTrue(msg.contains("boom"))
    }

    s.test("malformed-JSON response → state is .failed (parse error path)") {
        let stub = StubChatCompletionsClient(responses: [.success("not json at all")])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [.description], draft: draft)
        pump()
        if case .failed = orch.state {
            // ok
        } else {
            try expectTrue(false, "expected .failed, got \(orch.state)")
        }
    }

    s.test("missing-required-field response → state is .failed with field name") {
        let stub = StubChatCompletionsClient(responses: [
            .success("{\"description\": \"x\"}"),  // personality missing
        ])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [.description, .personality], draft: draft)
        pump()
        guard case .failed(let msg) = orch.state else {
            try expectTrue(false, "expected .failed, got \(orch.state)")
            return
        }
        try expectTrue(msg.contains("personality"))
    }

    // MARK: - Cancellation

    s.test("cancel() during fetch reverts to .idle and ignores late arrivals") {
        let stub = StubChatCompletionsClient(
            responses: [.success("{\"description\": \"x\"}")],
            timing: .queued
        )
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [.description], draft: draft)
        pump()
        // First request is queued, completion not yet fired.
        orch.cancel()
        try expectEqual(orch.state, .idle)
        // Now flush — controller must drop the response.
        stub.flushQueued()
        pump()
        try expectEqual(orch.state, .idle, "post-cancel completion must not advance state")
    }

    // MARK: - Wiring contract

    s.test("orchestrator passes the schema + sampler params from buildRequest to the client") {
        let stub = StubChatCompletionsClient(responses: [
            .success("{\"description\": \"x\"}"),
        ])
        let orch = CardMultiFieldOrchestrator(generator: stub)
        orch.fill(fields: [.description], draft: draft)
        pump()
        try expectEqual(stub.capturedSchemas.count, 1)
        try expectEqual(stub.capturedTemperatures.count, 1)
        try expectGreaterThan(stub.capturedMaxTokens[0], 1000)
        // The system message must be the bundled NSFW-license prompt.
        try expectEqual(stub.capturedSystemMessages[0], CardGenPromptsLoader.bundled.systemPrompt)
    }

    return s
}
