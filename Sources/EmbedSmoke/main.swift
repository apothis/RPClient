import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.d — embeddings smoke. Smallest harness in the
// suite: confirms the server's `/v1/embeddings` endpoint is reachable
// and returns vectors of consistent dimensionality. Uses the synthetic
// fixture turn texts as the input batch — real-shaped content,
// determinism without needing a real chat.
//
// usage:
//   swift run EmbedSmoke [--server URL] [--fixture NAME|all] [--chat ID]
//
// defaults: server = http://192.168.1.201:5001, fixture = sfw-short
//           (a small batch is enough to confirm the endpoint shape;
//           --fixture all batches every fixture's first 3 turns).

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var fixture: String = "sfw-short"
    var chatId: String? = nil
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
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run EmbedSmoke [--server URL] \
            [--fixture NAME|all] [--chat ID]
            """.utf8))
            exit(0)
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown arg '\(a)'\n".utf8))
        }
    }
    return args
}

/// Build the input batch. Pick representative turn texts from the
/// chosen fixture(s) to exercise the endpoint with real-shaped content.
func resolveBatch(_ args: Args) -> [(label: String, text: String)] {
    if let chatId = args.chatId {
        do {
            let chat = try RealChatLoader.loadChat(id: chatId)
            return chat.turns.prefix(5).enumerated().map { i, t in
                (label: "real:\(chatId)/turn\(i)", text: t.text)
            }
        } catch {
            FileHandle.standardError.write(Data("error: failed to load real chat '\(chatId)' — \(error)\n".utf8))
            exit(2)
        }
    }
    if args.fixture == "all" {
        var out: [(String, String)] = []
        for entry in SyntheticChats.all {
            for (i, t) in entry.chat.turns.prefix(3).enumerated() {
                out.append((label: "\(entry.name)/turn\(i)", text: t.text))
            }
        }
        return out
    }
    if let one = SyntheticChats.byName(args.fixture) {
        return one.turns.prefix(8).enumerated().map { i, t in
            (label: "\(args.fixture)/turn\(i)", text: t.text)
        }
    }
    FileHandle.standardError.write(Data("error: unknown fixture '\(args.fixture)' — try 'all' or one of: \(SyntheticChats.all.map(\.name).joined(separator: ", "))\n".utf8))
    exit(2)
}

let cliArgs = parseArgs()
let batch = resolveBatch(cliArgs)
print("--- EmbedSmoke ---")
print("server:    \(cliArgs.server.absoluteString)")
print("fixture:   \(cliArgs.chatId ?? cliArgs.fixture)")
print("inputs:    \(batch.count)")
print("--------------------")

// Probe model name (for the observation log key).
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

let kobold = KoboldClient(baseURL: cliArgs.server)
let started = Date()
let semaphore = DispatchSemaphore(value: 0)
var resultBox: Result<[[Float]], Error>?

kobold.embed(texts: batch.map { $0.text }) { r in
    resultBox = r
    semaphore.signal()
}

let timeoutDeadline = Date().addingTimeInterval(120)
while semaphore.wait(timeout: .now() + 0.05) == .timedOut {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
    if Date() > timeoutDeadline {
        print("[timeout]")
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
        smoke: "EmbedSmoke", fixture: cliArgs.fixture, timestamp: now,
        kind: ObservationKind.timedOut,
        details: "embed exceeded 120s outer timeout (\(batch.count) inputs)",
        remediationHint: "Either no embedding model is loaded (--embeddingsmodel <gguf> on KoboldCPP startup), or the batch is too large for the embedding model's context. Reduce --fixture scope and retry."
    ))
case .failure(let err):
    let s = String(describing: err)
    print("[embed failed] \(err)")
    let needsEmbeddings = s.lowercased().contains("embed") || s.contains("404") || s.contains("not found")
    observations.append(ModelObservation(
        smoke: "EmbedSmoke", fixture: cliArgs.fixture, timestamp: now,
        kind: needsEmbeddings ? "no-embedding-model" : ObservationKind.noTokens,
        details: "embed failed: \(err)",
        remediationHint: needsEmbeddings
            ? "Server is missing an embedding model. Start KoboldCPP with `--embeddingsmodel <gguf>` to enable /v1/embeddings. Until then, Phase 7 vector retrieval is unavailable on this server — bind that role elsewhere."
            : "Check server logs for the underlying error; possibly an HTTP-level / auth issue."
    ))
case .success(let vecs):
    print("[got] \(vecs.count) vectors in \(totalMs)ms")
    if vecs.count != batch.count {
        observations.append(ModelObservation(
            smoke: "EmbedSmoke", fixture: cliArgs.fixture, timestamp: now,
            kind: "embed-count-mismatch",
            details: "asked for \(batch.count), got \(vecs.count)",
            remediationHint: "Server dropped one or more inputs. Check whether any input was empty or exceeded the embedding model's max context."
        ))
    }
    let dims = Set(vecs.map(\.count))
    if dims.count > 1 {
        observations.append(ModelObservation(
            smoke: "EmbedSmoke", fixture: cliArgs.fixture, timestamp: now,
            kind: "embed-dim-inconsistent",
            details: "vectors have varying dimensionality: \(dims.sorted())",
            remediationHint: "An embedding model should always produce same-dim vectors regardless of input length. Inconsistent dims = server bug or model mis-config; do NOT store these in the vector index."
        ))
    } else if let dim = dims.first {
        print("dimensionality: \(dim)")
    }
    if vecs.contains(where: { $0.isEmpty }) {
        observations.append(ModelObservation(
            smoke: "EmbedSmoke", fixture: cliArgs.fixture, timestamp: now,
            kind: "embed-empty-vector",
            details: "at least one returned vector is zero-length",
            remediationHint: "Server returned an empty vector — likely caused by an empty / whitespace-only input. Filter empties before sending."
        ))
    }
    print("--- per-input ---")
    for (i, label) in batch.map(\.label).enumerated() where i < vecs.count {
        let v = vecs[i]
        let head = v.prefix(4).map { String(format: "%.3f", $0) }.joined(separator: ", ")
        print(String(format: "  [%2d] %@  dim=%d  head=[%@…]", i, label, v.count, head))
    }
}

if let model = probedModelName {
    do {
        let url = try ModelObservationStore.append(observations, modelName: model)
        print("")
        print("observations: written \(observations.count) to \(url.path)")
    } catch {
        FileHandle.standardError.write(Data("warning: failed to write observation log — \(error)\n".utf8))
    }
} else {
    FileHandle.standardError.write(Data("warning: model probe failed at startup — observation log NOT written.\n".utf8))
}

exit(observations.isEmpty ? 0 : (observations.contains(where: { $0.kind == "no-embedding-model" }) ? 0 : 1))
