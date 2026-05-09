import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.b — chat-path smoke runner. Drives
// `KoboldClient.generateStream` against prompts assembled by
// `PromptBuilder` from the SmokeFixtures catalogue. Exercises the
// most load-bearing model-facing surface in the app: template
// selection, stop sequences, system prompt, persona, world-info
// injection, memory prefix, multi-cast assembly, group-nudge.
//
// usage:
//   swift run ChatSmoke [--server URL] [--template ID] [--fixture NAME|all]
//                        [--chat ID] [--verbose]
//
// defaults:
//   server   = http://192.168.1.201:5001
//   template = qwen
//   fixture  = all (every SyntheticChats entry, in catalogue order)
//
// Output mirrors CardGenSmoke: header per fixture, prompt preview
// (head + tail with the middle elided when long), streaming response,
// refusal flag, timing, total chars. `--verbose` adds a token-by-token
// stream rather than a final blob — useful for catching mid-stream
// stalls / chunk-cadence issues that aren't visible in the final text.

// MARK: - CLI parsing

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var templateId: String = "qwen"
    var fixture: String = "all"   // "all", a fixture name, or unused when chatId set
    var chatId: String? = nil
    var verbose: Bool = false
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--server":
            if let v = it.next(), let u = URL(string: v) { args.server = u }
        case "--template":
            if let v = it.next() { args.templateId = v }
        case "--fixture":
            if let v = it.next() { args.fixture = v }
        case "--chat":
            if let v = it.next() { args.chatId = v }
        case "--verbose":
            args.verbose = true
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run ChatSmoke [--server URL] [--template ID] \
            [--fixture NAME|all] [--chat ID] [--verbose]
            """.utf8))
            exit(0)
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown arg '\(a)'\n".utf8))
        }
    }
    return args
}

// MARK: - Fixture resolution

struct FixtureRun {
    let name: String
    let chat: Chat
    /// Resolved active speaker's character (solo: bound character;
    /// multi-cast: first cast member). Nil for free-form chats.
    let activeCharacter: Character?
    /// All characters in the cast, used for multi-cast PromptBuilder
    /// assembly (cohabitant briefs + history name-prefixing).
    let cast: [Character]
}

func resolveFixtures(args: Args) -> [FixtureRun] {
    if let chatId = args.chatId {
        do {
            let chat = try RealChatLoader.loadChat(id: chatId)
            // Real chats: best-effort character lookup against the
            // synthetic catalogue (smoke users typically point this at
            // a chat that does NOT match a synthetic character; the
            // `nil` fallback is the right call — PromptBuilder skips
            // the card prefix and we still exercise the rest of the
            // chat-path).
            let activeChar: Character? = chat.characterId
                .flatMap { cid in SyntheticCharacters.all.first(where: { $0.character.id == cid })?.character }
            return [FixtureRun(name: "real:\(chatId)", chat: chat, activeCharacter: activeChar, cast: activeChar.map { [$0] } ?? [])]
        } catch {
            FileHandle.standardError.write(Data("error: failed to load real chat '\(chatId)' — \(error)\n".utf8))
            exit(2)
        }
    }
    let entries: [SyntheticChats.Entry] = {
        if args.fixture == "all" { return SyntheticChats.all }
        if let one = SyntheticChats.all.first(where: { $0.name == args.fixture }) { return [one] }
        FileHandle.standardError.write(Data("error: unknown fixture '\(args.fixture)' — try 'all' or one of: \(SyntheticChats.all.map(\.name).joined(separator: ", "))\n".utf8))
        exit(2)
    }()
    return entries.map { entry -> FixtureRun in
        let chat = entry.chat
        let castChars = chat.cast.compactMap { id in
            SyntheticCharacters.all.first(where: { $0.character.id == id })?.character
        }
        let active: Character? = chat.characterId.flatMap { cid in
            castChars.first(where: { $0.id == cid }) ?? SyntheticCharacters.all.first(where: { $0.character.id == cid })?.character
        }
        return FixtureRun(name: entry.name, chat: chat, activeCharacter: active, cast: castChars)
    }
}

// MARK: - Prompt assembly + streaming

@MainActor
func runFixture(_ run: FixtureRun, args: Args, kobold: KoboldClient) -> (response: String, ms: Int, refusal: RefusalDetection, observations: [ModelObservation]) {
    let template = Templates.byId(args.templateId, qwenThinking: false)
    // Multi-cast: pick the first cast member as active speaker (no
    // SpeakerPicker in the smoke path; we want determinism so
    // KV-cache prefixes are byte-stable across runs). Solo: nil.
    let speakerId: UUID? = run.chat.cast.count > 1 ? run.chat.cast.first : nil

    // Track whether the last verbatim turn is an assistant turn — the
    // QuirkDetector uses this to refine its "shortReply" hint (the
    // doubled-prefill case behaves differently from a model that
    // genuinely emits end-of-turn early). We do NOT auto-set
    // `continuation: true` here: an earlier attempt to do so made
    // things worse because the model interpreted the open assistant
    // turn as already complete (Qwen3.6 emitted end-token immediately
    // on closed-feeling trailing prose). Production fixtures should
    // end on user turns; that's the chat-send invariant. Fixtures
    // that don't are intentionally probing the doubled-prefill
    // behaviour — the QuirkDetector flags it but we don't suppress.
    let lastVerbatimRole = PromptBuilder.verbatimTurns(run.chat).last?.role
    let promptEndsOnAssistant = lastVerbatimRole == .assistant

    let assembled = PromptBuilder.build(
        chat: run.chat,
        character: run.activeCharacter,
        persona: nil,
        relevantMemories: nil,
        continuation: false,
        qwenThinking: false,
        speakerId: speakerId,
        cast: run.cast
    )
    // Override the chat's templateId for the actual stop sequences if
    // the user passed --template — otherwise the assembled stops
    // match `chat.templateId`. We use whichever the user picked at
    // the CLI for both prompt assembly and stop sequences.
    let stops = template.stopSequences
    print(promptPreview(assembled.prompt))
    let promptChars = assembled.prompt.count
    print("[prompt: \(promptChars) chars, ~\(promptChars / 4) tokens]")
    print("--- response \(args.verbose ? "(streaming)" : "")---")

    let request = GenerateRequest(
        prompt: assembled.prompt,
        stopSequences: stops,
        preset: .balanced,
        maxContextLength: 16384,
        maxLengthOverride: 512
    )

    let semaphore = DispatchSemaphore(value: 0)
    let started = Date()
    var collected = ""
    var firstTokenAt: Date?
    var finalError: Error?

    kobold.generateStream(request: request, onToken: { tok in
        if firstTokenAt == nil { firstTokenAt = Date() }
        collected += tok
        if args.verbose {
            // Print tokens as they arrive without buffering.
            FileHandle.standardOutput.write(Data(tok.utf8))
        }
    }, onFinish: { err in
        finalError = err
        semaphore.signal()
    })

    let timeoutDeadline = Date().addingTimeInterval(180)
    while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        if Date() > timeoutDeadline {
            print("\n[timeout] >180s elapsed, cancelling")
            kobold.cancel()
            break
        }
    }

    let ttft = firstTokenAt.map { Int($0.timeIntervalSince(started) * 1000) } ?? -1
    let totalMs = Int(Date().timeIntervalSince(started) * 1000)
    if !args.verbose {
        // In non-verbose mode we hadn't printed anything yet.
        print(collected.isEmpty ? "(no tokens received)" : collected)
    } else {
        // Newline so the next "[" line lands clean.
        print("")
    }
    if let err = finalError {
        print("[error] \(err)")
    }
    print("[ttft: \(ttft)ms, total: \(totalMs)ms, response: \(collected.count) chars]")
    let refusal = CardGenRefusalDetector.detect(candidate: collected, expectedLengthChars: 400)

    // Run the rule-based detector against the fixture result. The
    // observations are returned to the caller for batched append to
    // the per-model log at the end of the run.
    let activeName: String? = {
        if let sid = speakerId {
            return run.cast.first(where: { $0.id == sid })?.name
        }
        return run.activeCharacter?.name
    }()
    let cohabitantNames: [String] = run.cast
        .filter { $0.name != activeName }
        .map(\.name)
    let observations = QuirkDetectors.detectChat(
        smoke: "ChatSmoke",
        fixture: run.name,
        response: collected,
        expectedLengthChars: 400,
        promptEndsOnAssistant: promptEndsOnAssistant,
        castNamesOtherThanActive: cohabitantNames
    )
    return (collected, totalMs, refusal, observations)
}

func promptPreview(_ prompt: String) -> String {
    let maxHead = 600
    let maxTail = 400
    if prompt.count <= maxHead + maxTail + 64 {
        return "--- prompt ---\n\(prompt)"
    }
    let headEnd = prompt.index(prompt.startIndex, offsetBy: maxHead)
    let tailStart = prompt.index(prompt.endIndex, offsetBy: -maxTail)
    let head = String(prompt[..<headEnd])
    let tail = String(prompt[tailStart...])
    let elided = prompt.count - maxHead - maxTail
    return "--- prompt (head + tail; \(elided) chars elided in middle) ---\n\(head)\n\n…[\(elided) chars elided]…\n\n\(tail)"
}

// MARK: - Server probe + entry

let cliArgs = parseArgs()
print("--- ChatSmoke ---")
print("server:    \(cliArgs.server.absoluteString)")
print("template:  \(cliArgs.templateId)")
if let cid = cliArgs.chatId {
    print("chat:      \(cid) (real)")
} else {
    print("fixture:   \(cliArgs.fixture)")
}
print("verbose:   \(cliArgs.verbose)")
print("--------------------")

// Probe server reachability so a wrong URL fails fast with a clear
// message instead of a 30s URLSession timeout per fixture.
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

let runs = resolveFixtures(args: cliArgs)
let kobold = KoboldClient(baseURL: cliArgs.server)

struct Summary {
    let name: String
    let ms: Int
    let chars: Int
    let refusal: RefusalDetection
    let observationCount: Int
}

let exitCode: Int32 = MainActor.assumeIsolated {
    var summaries: [Summary] = []
    var allObservations: [ModelObservation] = []
    for (i, run) in runs.enumerated() {
        print("")
        print("====================================================")
        print("--- fixture \(i + 1)/\(runs.count): \(run.name) ---")
        print("====================================================")
        let bound = run.activeCharacter.map { $0.name } ?? "(none)"
        let castNames = run.cast.map(\.name).joined(separator: ", ")
        print("character: \(bound)")
        if !castNames.isEmpty && run.cast.count > 1 {
            print("cast:      \(castNames) (\(run.cast.count))")
        }
        print("turns:     \(run.chat.turns.count) (active path: \(run.chat.activePath.count))")
        let result = runFixture(run, args: cliArgs, kobold: kobold)
        if result.refusal.isRefusal {
            print("refusal:   ⚠ \(result.refusal.pattern?.rawValue ?? "?")")
        } else {
            print("refusal:   none detected")
        }
        if !result.observations.isEmpty {
            print("quirks:    \(result.observations.count) observation(s) recorded")
            for obs in result.observations {
                print("  • [\(obs.kind)] \(obs.details)")
                if let hint = obs.remediationHint, !hint.isEmpty {
                    // Keep hint on its own indented line so it's visually
                    // separable from the observation's details.
                    print("    → \(hint)")
                }
            }
        }
        summaries.append(Summary(name: run.name, ms: result.ms, chars: result.response.count,
                                 refusal: result.refusal, observationCount: result.observations.count))
        allObservations.append(contentsOf: result.observations)
    }

    print("")
    print("==================== summary ====================")
    let totalMs = summaries.reduce(0) { $0 + $1.ms }
    let refusals = summaries.filter { $0.refusal.isRefusal }.count
    let nameWidth = max(22, summaries.map { $0.name.count }.max() ?? 22)
    for s in summaries {
        let flag = s.refusal.isRefusal ? "⚠" : " "
        let qFlag = s.observationCount > 0 ? "Q\(s.observationCount)" : "  "
        let pad = String(repeating: " ", count: max(0, nameWidth - s.name.count))
        print(String(format: " %@ %@ %@%@  %5dms  %5d chars", flag, qFlag, s.name, pad, s.ms, s.chars))
    }
    print(String(format: "total: %d fixtures, %dms, %d refusal-flagged, %d observations recorded",
                 summaries.count, totalMs, refusals, allObservations.count))

    // Persist observations to the per-EXACT-model log. Model name
    // here is whatever `/api/v1/model` returned at startup. Skipped
    // when the probe failed (no model name to key on).
    if let model = probedModelName {
        if !allObservations.isEmpty {
            do {
                let url = try ModelObservationStore.append(allObservations, modelName: model)
                print("observations: written \(allObservations.count) to \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("warning: failed to write observation log — \(error)\n".utf8))
            }
        } else {
            // Still bump the runCount on a clean run so the log
            // reflects "we exercised this model N times, no quirks
            // surfaced." This is the difference between
            // "well-explored model with no issues" vs "never tested."
            do {
                let url = try ModelObservationStore.append([], modelName: model)
                print("observations: clean run recorded at \(url.path)")
            } catch {
                FileHandle.standardError.write(Data("warning: failed to write observation log — \(error)\n".utf8))
            }
        }
    } else {
        FileHandle.standardError.write(Data("warning: model probe failed at startup — observation log NOT written (model-name keying requires a known name).\n".utf8))
    }

    return summaries.isEmpty ? 1 : 0
}

exit(exitCode)
