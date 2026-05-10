import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.d — context-blurber smoke. Drives `ContextBlurber.run`
// against a synthetic Chunk built from a SmokeFixtures chat. The
// blurber is the contextual-retrieval recipe — it asks the model to
// describe a chunk's place in the story (1–2 short factual sentences)
// so the embedding picks up scene/setting context, not just the
// chunk's literal words.
//
// usage:
//   swift run BlurberSmoke [--server URL] [--fixture NAME|all]
//                           [--chat ID] [--ctx N] [--verbose]
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
            usage: swift run BlurberSmoke [--server URL] \
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
        // Skip cold-start (only one turn — no meaningful chunk).
        return SyntheticChats.all
            .filter { $0.chat.turns.count >= 3 }
            .map { FixtureRun(name: $0.name, chat: $0.chat) }
    }
    if let one = SyntheticChats.byName(args.fixture) {
        return [FixtureRun(name: args.fixture, chat: one)]
    }
    FileHandle.standardError.write(Data("error: unknown fixture '\(args.fixture)' — try 'all' or one of: \(SyntheticChats.all.map(\.name).joined(separator: ", "))\n".utf8))
    exit(2)
}

/// Build a synthetic Chunk covering the middle third of the chat's
/// active turns. Mid-chat slices are the realistic shape — chunks
/// near the head haven't accrued context, chunks at the tail are the
/// active scene (cheap to retrieve from `verbatimTurns` directly).
private func makeMidChunk(_ chat: Chat) -> Chunk? {
    let turns = chat.activeTurns
    guard turns.count >= 3 else { return nil }
    let mid = turns.count / 2
    let startIdx = max(0, mid - 1)
    let endIdx = min(turns.count - 1, mid + 1)
    let body = (startIdx...endIdx).map { i -> String in
        let role = turns[i].role == .user ? "User" : "Assistant"
        return "\(role): \(turns[i].text)"
    }.joined(separator: "\n\n")
    return Chunk(
        chatId: chat.id,
        firstTurnId: turns[startIdx].id,
        lastTurnId: turns[endIdx].id,
        firstTurnIdx: startIdx,
        lastTurnIdx: endIdx,
        text: body
    )
}

@MainActor
func runBlurber(_ run: FixtureRun, args: Args, kobold: KoboldClient) -> [ModelObservation] {
    guard let chunk = makeMidChunk(run.chat) else {
        print("(skipped — chat too short)")
        return []
    }
    print("chunk:     turns \(chunk.firstTurnIdx)–\(chunk.lastTurnIdx) (\(chunk.text.count) chars)")
    if args.verbose {
        print("--- chunk text ---")
        print(chunk.text)
    }
    print("--- blurber side-call ---")

    let semaphore = DispatchSemaphore(value: 0)
    var resultBox: Result<String, Error>?
    let started = Date()

    ContextBlurber.run(chunk: chunk, chat: run.chat, kobold: kobold,
                       effectiveCtx: args.effectiveCtx) { r in
        resultBox = r
        semaphore.signal()
    }

    let timeoutDeadline = Date().addingTimeInterval(60)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if Date() > timeoutDeadline {
            print("[timeout]")
            kobold.cancel()
            break
        }
    }
    let totalMs = Int(Date().timeIntervalSince(started) * 1000)
    var observations: [ModelObservation] = []
    let now = Date()

    switch resultBox {
    case .none:
        print("[no result — timeout]")
        observations.append(ModelObservation(
            smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.timedOut,
            details: "blurber exceeded the 60s outer timeout",
            remediationHint: "Blurber output is capped at 160 tokens; a 60s timeout should be plenty. Check server health, or whether the model is generating very slowly on this prompt shape."
        ))
    case .failure(let err):
        print("[blurber failed] \(err)")
        observations.append(ModelObservation(
            smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.noTokens,
            details: "blurber failed: \(err)",
            remediationHint: "Check server logs; blurber is a thin wrapper around generate."
        ))
    case .success(let blurb):
        print("[blurb] \(blurb)")
        print("[total: \(totalMs)ms, blurb: \(blurb.count) chars]")

        if blurb.isEmpty {
            observations.append(ModelObservation(
                smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.noTokens,
                details: "blurb is empty after Markdown.stripThinking + trim",
                remediationHint: "Model returned only a thinking trace — Markdown.stripThinking removed it, leaving nothing. Either thinking-prefill isn't suppressing thinking on this model, or the model is treating the blurb prompt as a thinking-required task. Consider injecting an explicit `[no thinking]` directive or use a non-thinking model on the blurber-role server."
            ))
        }
        // The blurb is supposed to be 1-2 sentences. Anything over
        // ~400 chars is the model losing the format directive and
        // producing prose summary instead.
        if blurb.count > 400 {
            observations.append(ModelObservation(
                smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
                kind: "blurb-too-long",
                details: "blurb \(blurb.count)c — directive said 1-2 short sentences",
                remediationHint: "Model lost the 'short factual' instruction. Tighten blurber prompt or use a smaller model on the blurber-role server (small models are usually MORE compliant on length directives)."
            ))
        }
        if QuirkDetectors.containsUnstrippedThinkBlock(blurb) {
            observations.append(ModelObservation(
                smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.thinkingTraceLeak,
                details: "blurb contains <think>…</think> after stripThinking",
                remediationHint: "Markdown.stripThinking failed to remove the trace — likely an unbalanced or nested tag. Either harden the regex or call ThinkBlockFilter post-stream."
            ))
        }
        let refusal = CardGenRefusalDetector.detect(candidate: blurb, expectedLengthChars: 200)
        if refusal.isRefusal {
            observations.append(ModelObservation(
                smoke: "BlurberSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.refusal,
                details: "matched pattern: \(refusal.pattern?.rawValue ?? "?")",
                remediationHint: "Blurber asks for a factual context description, not generation. A refusal here means the model balked at describing the snippet (NSFW content most likely). Bind the blurber-role to a permissive small model in production rather than the chat-role server."
            ))
        }
    }
    return observations
}

let cliArgs = parseArgs()
print("--- BlurberSmoke ---")
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
        let obs = runBlurber(run, args: cliArgs, kobold: kobold)
        if !obs.isEmpty {
            print("quirks:    \(obs.count) observation(s)")
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
