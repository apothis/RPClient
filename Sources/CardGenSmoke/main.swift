import Foundation
@testable import RPClientCore

// Phase 9 §5.4.a — first-light smoke runner for the AI-assist
// Mode 1 backend. Drives a real `CardSuggestionsController` against
// a real KoboldCPP server with a representative card draft, and
// prints state transitions + final candidates with timing.
//
// usage:
//   swift run CardGenSmoke [serverURL] [templateId] [field] [tag1,tag2,...]
//   swift run CardGenSmoke --multi [serverURL] [tag1,tag2,...] [field1,field2,...]
//
// Mode 1 (default): drives a 3-candidate triad against one field
// (description by default).
// Mode 2 (--multi): drives a single-call json_schema fill across the
// listed target fields (defaults to description+personality+scenario).
//
// defaults match the user's typical setup:
//   serverURL = http://192.168.1.201:5001
//   templateId = qwen
//   field = description
//   tags = nsfw,fantasy,monstergirl,dom

var rawArgs = Array(CommandLine.arguments.dropFirst())
let multiMode = rawArgs.first == "--multi"
if multiMode { rawArgs.removeFirst() }
let args = rawArgs

let serverURLString: String
let templateId: String
let fieldName: String
let tagListRaw: String
let multiTargetsRaw: String

if multiMode {
    // --multi shape: [serverURL] [tags] [fields]
    serverURLString = args.count >= 1 ? args[0] : "http://192.168.1.201:5001"
    templateId = "qwen"
    fieldName = "description"  // unused in multi mode
    tagListRaw = args.count >= 2 ? args[1] : "nsfw,fantasy,monstergirl,dom"
    multiTargetsRaw = args.count >= 3 ? args[2] : "description,personality,scenario,first_message,message_example"
} else {
    serverURLString = args.count >= 1 ? args[0] : "http://192.168.1.201:5001"
    templateId      = args.count >= 2 ? args[1] : "qwen"
    fieldName       = args.count >= 3 ? args[2] : "description"
    tagListRaw      = args.count >= 4 ? args[3] : "nsfw,fantasy,monstergirl,dom"
    multiTargetsRaw = ""
}

guard let serverURL = URL(string: serverURLString) else {
    FileHandle.standardError.write(Data("error: bad server URL: \(serverURLString)\n".utf8))
    exit(2)
}
guard let field = CardField(rawValue: fieldName) else {
    let valid = CardField.allCases.map(\.rawValue).joined(separator: ", ")
    FileHandle.standardError.write(Data("error: unknown field '\(fieldName)' — valid: \(valid)\n".utf8))
    exit(2)
}

let tags = tagListRaw
    .split(separator: ",")
    .map { $0.trimmingCharacters(in: .whitespaces) }
    .filter { !$0.isEmpty }

print("--- CardGenSmoke ---")
print("server:    \(serverURLString)")
print("template:  \(templateId)")
print("field:     \(field.rawValue)")
print("tags:      \(tags.joined(separator: ", "))")
print("--------------------")

// Representative draft. For Mode 1 the exemplar is selected from
// tag overlap; the field-being-generated picks its upstreams from
// the §4.4 dep graph and pulls those values from .fields.
let draft = CardDraftSnapshot(
    tags: tags,
    fields: [
        .name: "Vexara",
        .description: "An ancient Lamia matriarch who keeps a stone hall at the river's bend.",
        .personality: "Patient, watchful, indulgent of mortals; speaks softly.",
        .scenario: "{{user}} arrives at the river hall with a request that requires Vexara's permission.",
    ]
)

let kobold = KoboldClient(baseURL: serverURL)
let template = Templates.byId(templateId, qwenThinking: false)

// Probe server reachability so a wrong URL fails fast with a clear
// message instead of a 30s URLSession timeout per candidate.
let probeURL = serverURL.appendingPathComponent("api/v1/model")
let probeSemaphore = DispatchSemaphore(value: 0)
var probedModelName: String?
URLSession.shared.dataTask(with: probeURL) { data, _, error in
    defer { probeSemaphore.signal() }
    if let error {
        FileHandle.standardError.write(Data("error: probe to \(probeURL.absoluteString) failed — \(error)\n".utf8))
        return
    }
    if let data,
       let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let result = obj["result"] as? String {
        probedModelName = result
    }
}.resume()
_ = probeSemaphore.wait(timeout: .now() + 10)

if let probedModelName {
    print("model:     \(probedModelName)")
    let permissive = CardGenRefusalDetector.isLikelyUncensored(modelName: probedModelName)
    print("uncensored-marker: \(permissive)")
} else {
    print("model:     (probe failed — proceeding anyway)")
}
print("--------------------")

// Build + run the controller. CardSuggestionsController is @MainActor;
// main.swift's top-level isn't actor-isolated by default, so
// MainActor.assumeIsolated lets us drive it from here. Synchronous
// wait via DispatchSemaphore — the controller fires its callbacks
// off the main thread (via KoboldClient's URLSession delegate queue
// hopping back to main), so we run a runloop pump until the state
// settles.

@MainActor
func runMultiMode(draft: CardDraftSnapshot, kobold: KoboldClient, targets targetsRaw: String) -> Int32 {
    let targets: [CardField] = targetsRaw
        .split(separator: ",")
        .compactMap { CardField(rawValue: String($0).trimmingCharacters(in: .whitespaces)) }
    guard !targets.isEmpty else {
        print("error: no valid target fields in '\(targetsRaw)'")
        return 2
    }
    print("[multi] targets: \(targets.map(\.rawValue).joined(separator: ", "))")

    let semaphore = DispatchSemaphore(value: 0)
    var finalState: CardMultiFieldOrchestrator.State = .idle

    let orch = CardMultiFieldOrchestrator(generator: kobold)
    let started = Date()
    orch.onStateChange = { state in
        let elapsed = Date().timeIntervalSince(started)
        switch state {
        case .idle:
            print(String(format: "[%5.2fs] idle", elapsed))
        case .fetching(let n):
            print(String(format: "[%5.2fs] fetching %d-field json_schema…", elapsed, n))
        case .ready(let proposals):
            print(String(format: "[%5.2fs] ready (%d proposals)", elapsed, proposals.count))
            finalState = state
            semaphore.signal()
        case .failed(let m):
            print(String(format: "[%5.2fs] failed: %@", elapsed, m))
            finalState = state
            semaphore.signal()
        }
    }

    print("[ 0.00s] firing multi-field fill…")
    orch.fill(fields: targets, draft: draft)

    let timeoutDeadline = Date().addingTimeInterval(120)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if Date() > timeoutDeadline {
            print("[timeout] >120s elapsed, giving up")
            return 1
        }
    }

    print("--- final state ---")
    switch finalState {
    case .ready(let proposals):
        for (i, p) in proposals.enumerated() {
            let header = "[\(i + 1)] \(p.field.rawValue) — exemplar=\(p.exemplarId)"
                + (p.refusal.isRefusal ? " ⚠ refusal=\(p.refusal.pattern?.rawValue ?? "?")" : "")
                + " (\(p.text.count) chars)"
            print(header)
            print(p.text)
            print("---")
        }
        return 0
    case .failed(let m):
        print("FAILED: \(m)")
        return 1
    default:
        return 1
    }
}

let exitCode: Int32 = MainActor.assumeIsolated {
    if multiMode {
        return runMultiMode(draft: draft, kobold: kobold, targets: multiTargetsRaw)
    }

    let semaphore = DispatchSemaphore(value: 0)
    var finalState: CardSuggestionsController.State = .idle

    let controller = CardSuggestionsController(
        field: field,
        generator: kobold,
        templateAssemble: { body in
            let promptTurns = [Turn(role: .user, text: body)]
            return template.assemble(
                memoryBlock: nil, summary: nil, worldInfoHits: [],
                authorsNote: nil, turns: promptTurns
            )
        },
        effectiveCtx: 16384,
        stopSequences: template.stopSequences
    )

    let started = Date()
    controller.onStateChange = { state in
        let elapsed = Date().timeIntervalSince(started)
        switch state {
        case .idle:
            print(String(format: "[%5.2fs] idle", elapsed))
        case .generating(let n, let total):
            print(String(format: "[%5.2fs] generating %d/%d", elapsed, n, total))
        case .ready(let candidates):
            print(String(format: "[%5.2fs] ready (%d candidates)", elapsed, candidates.count))
            finalState = state
            semaphore.signal()
        case .stale(let candidates):
            print(String(format: "[%5.2fs] stale (%d candidates)", elapsed, candidates.count))
            finalState = state
            semaphore.signal()
        case .failed(let message):
            print(String(format: "[%5.2fs] failed: %@", elapsed, message))
            finalState = state
            semaphore.signal()
        }
    }

    print("[ 0.00s] firing triad…")
    controller.generate(draft: draft)

    // Pump the runloop while we wait. Time out at 90s — three
    // candidates × ~30s research-spec timeout per candidate.
    let timeoutDeadline = Date().addingTimeInterval(90)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if Date() > timeoutDeadline {
            print("[timeout] >90s elapsed, giving up")
            return 1
        }
    }

    print("--- final state ---")
    switch finalState {
    case .ready(let candidates), .stale(let candidates):
        for (i, c) in candidates.enumerated() {
            let header = "[\(i + 1)] \(c.style.rawValue) — exemplar=\(c.exemplarId)"
                + (c.refusal.isRefusal ? " ⚠ refusal=\(c.refusal.pattern?.rawValue ?? "?")" : "")
                + " (\(c.text.count) chars)"
            print(header)
            print(c.text)
            print("---")
        }
        return 0
    case .failed(let m):
        print("FAILED: \(m)")
        return 1
    default:
        print("UNEXPECTED: \(finalState)")
        return 1
    }
}

exit(exitCode)
