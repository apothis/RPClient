import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.c — director smoke runner. Drives `DirectorPicker.next`
// against the multi-cast fixtures (group-chat, nsfw-group-scene)
// plus `--chat <id>`. Side-call shape: tail-of-history + cast list
// → "who should speak next?" → one name → parse to a cast UUID.
//
// What this exercises:
//   - the same template-wrapping pattern as Summarizer (single user
//     turn through Templates.assemble)
//   - the substring-match parser (`DirectorPicker.parsePick`)
//     against models that pad / explain / refuse
//   - 5-second timeout fallback (the picker drops to nil so AppState
//     can fall back to round-robin)
//
// usage:
//   swift run DirectorSmoke [--server URL] [--fixture NAME|all]
//                            [--chat ID] [--ctx N] [--repeats N]
//
// defaults: server = http://192.168.1.201:5001, fixture = all
//           multi-cast fixtures, ctx = 16384, repeats = 1.
//
// `--repeats N` runs each fixture N times — director picks SHOULD
// be deterministic at temperature 0.3 but worth verifying when
// diagnosing flap.

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var fixture: String = "all"
    var chatId: String? = nil
    var effectiveCtx: Int = 16384
    var repeats: Int = 1
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
        case "--repeats":
            if let v = it.next(), let n = Int(v), n > 0 { args.repeats = n }
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run DirectorSmoke [--server URL] \
            [--fixture NAME|all] [--chat ID] [--ctx N] [--repeats N]
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
    let cast: [Character]
}

func resolveFixtures(_ args: Args) -> [FixtureRun] {
    if let chatId = args.chatId {
        do {
            let chat = try RealChatLoader.loadChat(id: chatId)
            let cast = chat.cast.compactMap { id in
                SyntheticCharacters.all.first(where: { $0.character.id == id })?.character
            }
            return [FixtureRun(name: "real:\(chatId)", chat: chat, cast: cast)]
        } catch {
            FileHandle.standardError.write(Data("error: failed to load real chat '\(chatId)' — \(error)\n".utf8))
            exit(2)
        }
    }
    let candidates: [SyntheticChats.Entry] = {
        if args.fixture == "all" {
            // Director only makes sense on multi-cast chats; filter
            // synthetic catalogue accordingly so a generic --fixture all
            // doesn't run on solo chats and produce useless "no cast"
            // results.
            return SyntheticChats.all.filter { $0.chat.cast.count > 1 }
        }
        if let one = SyntheticChats.all.first(where: { $0.name == args.fixture }) {
            return [one]
        }
        return []
    }()
    if candidates.isEmpty {
        let multiCast = SyntheticChats.all.filter { $0.chat.cast.count > 1 }.map(\.name).joined(separator: ", ")
        FileHandle.standardError.write(Data("error: no usable fixture (need multi-cast); try one of: \(multiCast)\n".utf8))
        exit(2)
    }
    return candidates.map { entry -> FixtureRun in
        let cast = entry.chat.cast.compactMap { id in
            SyntheticCharacters.all.first(where: { $0.character.id == id })?.character
        }
        return FixtureRun(name: entry.name, chat: entry.chat, cast: cast)
    }
}

@MainActor
func runDirector(_ run: FixtureRun, args: Args, kobold: KoboldClient) -> [ModelObservation] {
    print("cast:      \(run.cast.map(\.name).joined(separator: ", ")) (\(run.cast.count))")
    print("turns:     \(run.chat.turns.count) (active path: \(run.chat.activePath.count))")

    var picks: [(repeat: Int, ms: Int, pick: UUID?, name: String)] = []
    for r in 0..<args.repeats {
        let semaphore = DispatchSemaphore(value: 0)
        var resolved: UUID?
        let started = Date()
        DirectorPicker.next(chat: run.chat, cast: run.cast,
                            kobold: kobold, effectiveCtx: args.effectiveCtx) { pick in
            resolved = pick
            semaphore.signal()
        }
        // Picker has its own 5s internal timeout; give it 8s of slack.
        let timeoutDeadline = Date().addingTimeInterval(8)
        while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
            if Date() > timeoutDeadline {
                print("[outer-timeout]")
                break
            }
        }
        let ms = Int(Date().timeIntervalSince(started) * 1000)
        let pickName = resolved.flatMap { id in run.cast.first(where: { $0.id == id })?.name } ?? "(nil — round-robin fallback)"
        picks.append((r + 1, ms, resolved, pickName))
        print(String(format: "  pick %d/%d: %@  (%dms)", r + 1, args.repeats, pickName, ms))
    }

    var observations: [ModelObservation] = []
    let now = Date()
    let nilPicks = picks.filter { $0.pick == nil }.count
    if nilPicks == picks.count && !picks.isEmpty {
        observations.append(ModelObservation(
            smoke: "DirectorSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.unparseableDirectorPick,
            details: "every one of \(picks.count) repeats returned nil",
            remediationHint: "Either the model timed out (server slow → raise DirectorPicker.timeoutSeconds for this server profile in §10.a ServerCapabilities), or the parser couldn't find any cast name in the response. Check DebugLog 'director:' lines for the raw response."
        ))
    } else if nilPicks > 0 {
        observations.append(ModelObservation(
            smoke: "DirectorSmoke", fixture: run.name, timestamp: now,
            kind: ObservationKind.unparseableDirectorPick,
            details: "intermittent: \(nilPicks)/\(picks.count) returned nil",
            remediationHint: "Director picks should be stable at temperature 0.3 — flap suggests model is producing variable response shapes (sometimes wrapping the name in prose, sometimes not). Consider a stricter system prompt or json-schema enforcement once §10.a wires capability detection."
        ))
    }

    // Pick stability: how many distinct picks across repeats.
    if picks.count > 1 {
        let distinct = Set(picks.compactMap(\.pick))
        if distinct.count > 1 {
            observations.append(ModelObservation(
                smoke: "DirectorSmoke", fixture: run.name, timestamp: now,
                kind: "director-pick-flap",
                details: "\(distinct.count) distinct picks across \(picks.count) repeats",
                remediationHint: "Director's picks are non-deterministic at temp=0.3. Either the model's output varies wildly across repeats or the prompt is genuinely ambiguous. Check whether the recent-dialogue tail contains a clear next-speaker signal."
            ))
        }
    }
    return observations
}

let cliArgs = parseArgs()
print("--- DirectorSmoke ---")
print("server:    \(cliArgs.server.absoluteString)")
print("fixture:   \(cliArgs.chatId ?? cliArgs.fixture)")
print("ctx:       \(cliArgs.effectiveCtx)")
print("repeats:   \(cliArgs.repeats)")
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
        let obs = runDirector(run, args: cliArgs, kobold: kobold)
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
