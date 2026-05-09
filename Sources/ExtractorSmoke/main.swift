import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.d — extractor smoke. Drives `FactExtractor.run`
// against the long-history SmokeFixtures (defaults to `sfw-long`)
// plus any fixture you point at via `--fixture <name>`. The
// extractor is the GBNF-grammar JSON-mode side call; smoke checks:
//
//   - server actually honours the grammar (returns parseable JSON)
//   - the fact set is non-empty when the transcript contains real
//     character/place/event content
//   - the response shape matches the schema (entity_type ∈ allowed
//     set; entity_name/fact non-empty)
//
// usage:
//   swift run ExtractorSmoke [--server URL] [--fixture NAME|all]
//                             [--chat ID] [--ctx N] [--last-n N]
//                             [--verbose]
//
// defaults: server = http://192.168.1.201:5001, fixture = sfw-long,
//           ctx = 16384, last-n = 15.

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var fixture: String = "sfw-long"
    var chatId: String? = nil
    var effectiveCtx: Int = 16384
    var lastN: Int = 15
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
        case "--last-n":
            if let v = it.next(), let n = Int(v), n > 0 { args.lastN = n }
        case "--verbose":
            args.verbose = true
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run ExtractorSmoke [--server URL] \
            [--fixture NAME|all] [--chat ID] [--ctx N] [--last-n N] [--verbose]
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
func runExtractor(_ run: FixtureRun, args: Args, kobold: KoboldClient) -> [ModelObservation] {
    print("turns:     \(run.chat.turns.count)")
    print("ctx:       \(args.effectiveCtx)")
    print("last-n:    \(args.lastN) user-turns")
    print("--- extractor side-call ---")

    let semaphore = DispatchSemaphore(value: 0)
    var resultBox: Result<FactExtractionResult, Error>?
    let started = Date()

    FactExtractor.run(chat: run.chat, kobold: kobold, effectiveCtx: args.effectiveCtx,
                      lastN: args.lastN, prioritiesOverride: nil) { r in
        resultBox = r
        semaphore.signal()
    }

    let timeoutDeadline = Date().addingTimeInterval(180)
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
            smoke: "ExtractorSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.timedOut,
            details: "extractor exceeded the 180s outer timeout",
            remediationHint: "Either the model is slow on a long-prompt extraction, the GBNF grammar is bottlenecking sampling, or the server is unhealthy. Check server-side latency and consider --last-n with a smaller N to shrink the prompt."
        ))
    case .failure(let err):
        print("[extractor failed] \(err)")
        observations.append(ModelObservation(
            smoke: "ExtractorSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.noTokens,
            details: "extractor failed: \(err)",
            remediationHint: "If the failure mentions grammar/GBNF, the server build doesn't support sampling-time grammars — fall back to plain JSON mode (no grammar) and parse defensively. Otherwise check server logs."
        ))
    case .success(let r):
        print("[extracted] facts=\(r.facts.count) latencyMs=\(r.latencyMs) parseError=\(r.parseError ?? "-") rawChars=\(r.rawText.count)")
        if args.verbose {
            print("--- raw response ---")
            print(r.rawText)
            print("--- facts ---")
            for f in r.facts {
                print("  [\(f.entityType)] \(f.entityName) — \(f.fact)")
            }
        } else {
            for f in r.facts.prefix(5) {
                print("  [\(f.entityType)] \(f.entityName) — \(f.fact)")
            }
            if r.facts.count > 5 {
                print("  … (\(r.facts.count - 5) more)")
            }
        }

        if let err = r.parseError {
            observations.append(ModelObservation(
                smoke: "ExtractorSmoke", fixture: run.name, timestamp: now,
                kind: ObservationKind.schemaDeviation,
                details: "JSON parse failed: \(err) (raw \(r.rawText.count)c)",
                remediationHint: "GBNF grammar is supposed to make this impossible — if it fails, the server isn't applying the grammar (older KoboldCPP build / different backend). Check server version + grammar support; consider falling back to a permissive JSON parser that recovers from common shape drift."
            ))
        } else {
            // Validate every emitted fact's entity_type against the
            // closed alternation set in `FactExtractor.grammar`. The
            // grammar should make this impossible too — flag deviations
            // that slip through.
            let allowed: Set<String> = ["character", "location", "item", "relationship", "event"]
            let unknownTypes = r.facts.map(\.entityType).filter { !allowed.contains($0) }
            if !unknownTypes.isEmpty {
                observations.append(ModelObservation(
                    smoke: "ExtractorSmoke", fixture: run.name, timestamp: now,
                    kind: ObservationKind.schemaDeviation,
                    details: "entity_type out of allowed set: \(Set(unknownTypes).sorted().joined(separator: ", "))",
                    remediationHint: "Server isn't enforcing the GBNF type alternation. Either grammar isn't being applied, or the server normalises type values post-sampling. Add a defensive enum-clamp at parse time."
                ))
            }
            // A non-empty transcript that returns ZERO facts on a
            // long fixture means either the model returned `[]` (overly
            // conservative) or the extractor's `--last-n` window is too
            // small. Flag separately so the user can decide.
            if r.facts.isEmpty && run.chat.turns.count >= 10 {
                observations.append(ModelObservation(
                    smoke: "ExtractorSmoke", fixture: run.name, timestamp: now,
                    kind: "extractor-no-facts",
                    details: "long transcript (\(run.chat.turns.count) turns) produced 0 facts",
                    remediationHint: "Either the model is too conservative on this content (model preference for `[]` over surfacing state changes — common on heavily-aligned models when content is sensitive) or the prompt's `--last-n` window dropped the introduction turns. Try --last-n with a larger N, or bind the chat to a different role-server in production."
                ))
            }
        }
    }

    print("[total: \(totalMs)ms]")
    return observations
}

let cliArgs = parseArgs()
print("--- ExtractorSmoke ---")
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
        let obs = runExtractor(run, args: cliArgs, kobold: kobold)
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
