import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.c — summariser smoke runner. Drives `Summarizer.run`
// against the long-history SmokeFixtures (`sfw-long`) plus any
// fixture you point at via `--fixture <name>`. Side-call shape:
// the summariser counts tokens for every unsummarized turn, picks
// a slice that fits ~25% of effectiveCtx, and asks the model for
// a paragraph-long summary; second call merges with any existing
// summary if present.
//
// Surfaces this exercises:
//   - the prompt template's "wrap a single user turn through
//     PromptBuilder" pattern that side-calls all share
//   - the empty `<think></think>` pre-fill on Qwen3 (does the
//     summariser response leak a thinking trace into the output?)
//   - the "stop on plain text" path — summariser doesn't use json
//     schema, just expects a clean paragraph
//
// usage:
//   swift run SummariserSmoke [--server URL] [--fixture NAME|all]
//                              [--chat ID] [--ctx N] [--verbose]
//
// defaults: server = http://192.168.1.201:5001, fixture = sfw-long,
//           ctx = 16384.

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var fixture: String = "sfw-long"
    var chatId: String? = nil
    var effectiveCtx: Int = 16384
    var verbose: Bool = false
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--server":
            if let v = it.next(), let u = URL(string: v) { args.server = u }
        case "--fixture":
            if let v = it.next() { args.fixture = v }
        case "--chat":
            if let v = it.next() { args.chatId = v }
        case "--ctx":
            if let v = it.next(), let n = Int(v) { args.effectiveCtx = n }
        case "--verbose":
            args.verbose = true
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run SummariserSmoke [--server URL] \
            [--fixture NAME|all] [--chat ID] [--ctx N] [--verbose]
            """.utf8))
            exit(0)
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown arg '\(a)'\n".utf8))
        }
    }
    return args
}

struct FixtureRun {
    let name: String
    let chat: Chat
}

func resolveFixtures(_ args: Args) -> [FixtureRun] {
    if let chatId = args.chatId {
        do {
            let chat = try RealChatLoader.loadChat(id: chatId)
            return [FixtureRun(name: "real:\(chatId)", chat: chat)]
        } catch {
            FileHandle.standardError.write(Data("error: failed to load real chat '\(chatId)' — \(error)\n".utf8))
            exit(2)
        }
    }
    if args.fixture == "all" {
        return SyntheticChats.all.map { FixtureRun(name: $0.name, chat: $0.chat) }
    }
    if let one = SyntheticChats.byName(args.fixture) {
        return [FixtureRun(name: args.fixture, chat: one)]
    }
    FileHandle.standardError.write(Data("error: unknown fixture '\(args.fixture)' — try 'all' or one of: \(SyntheticChats.all.map(\.name).joined(separator: ", "))\n".utf8))
    exit(2)
}

@MainActor
func runSummariser(_ run: FixtureRun, args: Args, kobold: KoboldClient) -> (summary: String, ms: Int, observations: [ModelObservation]) {
    let started = Date()
    let semaphore = DispatchSemaphore(value: 0)
    var resultSummary = ""
    var failureNote: String?

    print("turns:     \(run.chat.turns.count) (active path: \(run.chat.activePath.count))")
    print("ctx:       \(args.effectiveCtx)")
    print("--- summariser side-call ---")

    Summarizer.run(chat: run.chat, kobold: kobold, effectiveCtx: args.effectiveCtx) { result in
        switch result {
        case .success(let s):
            resultSummary = s.summary
            print("summarizedThrough: \(s.summarizedThrough) of \(run.chat.turns.count)")
        case .failure(let err):
            failureNote = String(describing: err)
            print("[summariser failed] \(err)")
        }
        semaphore.signal()
    }

    let timeoutDeadline = Date().addingTimeInterval(180)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if Date() > timeoutDeadline {
            failureNote = "timeout >180s"
            print("[timeout]")
            kobold.cancel()
            break
        }
    }

    let totalMs = Int(Date().timeIntervalSince(started) * 1000)
    if !resultSummary.isEmpty {
        print("--- summary text ---")
        print(resultSummary)
    }
    print("[total: \(totalMs)ms, summary: \(resultSummary.count) chars]")

    // QuirkDetectors: a side-call summariser shares two of the chat-
    // path categories (refusal, thinking-trace-leak) and adds two of
    // its own (no-summary-on-non-empty-history, suspiciously long).
    var observations: [ModelObservation] = []
    let now = Date()
    if let note = failureNote {
        observations.append(ModelObservation(
            smoke: "SummariserSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.noTokens,
            details: "summariser failed: \(note)",
            remediationHint: "If the failure was 'nothingToSummarize', the chat is too short — pick a longer fixture (sfw-long is the canonical one). Otherwise check server logs for the underlying generate error."
        ))
    } else if resultSummary.isEmpty {
        observations.append(ModelObservation(
            smoke: "SummariserSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.noTokens,
            details: "non-empty history but empty summary",
            remediationHint: "Model returned tokens that were stripped to empty after trim — check whether the response is pure whitespace or pure thinking-trace (thinking-trace-leak detector covers the latter)."
        ))
    } else {
        if QuirkDetectors.containsUnstrippedThinkBlock(resultSummary) {
            observations.append(ModelObservation(
                smoke: "SummariserSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.thinkingTraceLeak,
                details: "summary contains <think>…</think>",
                remediationHint: "Summarizer.generateText already wraps the prompt through Templates.assemble, which emits the empty think pre-fill on Qwen. If a leak still appears, the model is generating a SECOND think block after the empty one — flag for §10.a sampler/template review."
            ))
        }
        let refusal = CardGenRefusalDetector.detect(candidate: resultSummary, expectedLengthChars: 400)
        if refusal.isRefusal {
            observations.append(ModelObservation(
                smoke: "SummariserSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.refusal,
                details: "matched pattern: \(refusal.pattern?.rawValue ?? "?")",
                remediationHint: "Summariser is asking for a factual recap; a refusal means the model balked at recapping the content (typical on heavily-aligned models when the chat contains explicit prose). Surface to the user as 'this server can't summarise NSFW chats' rather than silently storing a refusal as the summary."
            ))
        }
        // A summary is supposed to compress, not regurgitate. If it's
        // longer than ~25% of the input verbatim text, the model is
        // copying the dialog rather than summarising — sometimes the
        // failure mode on small models.
        let inputChars = run.chat.turns.map(\.text).joined(separator: " ").count
        if inputChars > 0 {
            let ratio = Double(resultSummary.count) / Double(inputChars)
            if ratio > 0.5 {
                observations.append(ModelObservation(
                    smoke: "SummariserSmoke", fixture: run.name, timestamp: now,
                    kind: "summary-too-long",
                    details: "summary \(resultSummary.count)c / input \(inputChars)c = ratio \(String(format: "%.2f", ratio))",
                    remediationHint: "Model copied the dialog rather than summarising. Reduce summariser prompt to be more directive about brevity, or use a smaller-context model that's forced to compress."
                ))
            }
        }
    }
    return (resultSummary, totalMs, observations)
}

// MARK: - Entry

let cliArgs = parseArgs()
print("--- SummariserSmoke ---")
print("server:    \(cliArgs.server.absoluteString)")
print("fixture:   \(cliArgs.chatId ?? cliArgs.fixture)")
print("ctx:       \(cliArgs.effectiveCtx)")
print("--------------------")

let probeURL = cliArgs.server.appendingPathComponent("api/v1/model")
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
} else {
    print("model:     (probe failed — proceeding anyway)")
}
print("--------------------")

let runs = resolveFixtures(cliArgs)
let kobold = KoboldClient(baseURL: cliArgs.server)

let exitCode: Int32 = MainActor.assumeIsolated {
    var allObservations: [ModelObservation] = []
    for (i, run) in runs.enumerated() {
        print("")
        print("====================================================")
        print("--- fixture \(i + 1)/\(runs.count): \(run.name) ---")
        print("====================================================")
        let (_, _, obs) = runSummariser(run, args: cliArgs, kobold: kobold)
        if !obs.isEmpty {
            print("quirks:    \(obs.count) observation(s) recorded")
            for o in obs {
                print("  • [\(o.kind)] \(o.details)")
                if let hint = o.remediationHint, !hint.isEmpty {
                    print("    → \(hint)")
                }
            }
        }
        allObservations.append(contentsOf: obs)
    }
    if let model = probedModelName {
        do {
            let url = try ModelObservationStore.append(allObservations, modelName: model)
            print("")
            print("observations: written \(allObservations.count) to \(url.path)")
        } catch {
            FileHandle.standardError.write(Data("warning: failed to write observation log — \(error)\n".utf8))
        }
    } else {
        FileHandle.standardError.write(Data("warning: model probe failed at startup — observation log NOT written.\n".utf8))
    }
    return runs.isEmpty ? 1 : 0
}

exit(exitCode)
