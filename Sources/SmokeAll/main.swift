import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.e — aggregate smoke runner. Invokes each per-surface
// smoke as a sub-process (sub-process for isolation per the plan;
// each smoke owns its own stdout / observation-log writes), captures
// timing + exit code, then snapshots the per-EXACT-model observation
// log to `smoke-reports/<sanitised>-<ts>.json`.
//
// Snapshots are the input shape ServerCapabilities (§10.a) consumes
// — they're a frozen view of "this is what we knew about model X
// after running the suite at time T," diff-able against prior
// snapshots to identify regressions across runs.
//
// usage:
//   swift run SmokeAll [--server URL] [--skip NAME[,NAME...]]
//                       [--diff PATH]
//
// defaults: server = http://192.168.1.201:5001
//           --skip empty (run every smoke)
//           --diff omitted (no comparison; just write a fresh snapshot)
//
// `--diff <path>` reads a prior snapshot JSON and prints a quirk-
// delta after the run: NEW (in current, not in prior), GONE (in
// prior, not in current), CHANGED (same key, different details).

struct Args {
    var server: URL = URL(string: "http://192.168.1.201:5001")!
    var skip: Set<String> = []
    var diffPath: String? = nil
}

func parseArgs() -> Args {
    var args = Args()
    var it = CommandLine.arguments.dropFirst().makeIterator()
    while let a = it.next() {
        switch a {
        case "--server":
            if let v = it.next(), let u = URL(string: v) { args.server = u }
        case "--skip":
            if let v = it.next() {
                args.skip = Set(v.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) })
            }
        case "--diff":
            if let v = it.next() { args.diffPath = v }
        case "-h", "--help":
            FileHandle.standardError.write(Data("""
            usage: swift run SmokeAll [--server URL] \
            [--skip NAME[,NAME...]] [--diff PATH]
            """.utf8))
            exit(0)
        default:
            FileHandle.standardError.write(Data("warning: ignoring unknown arg '\(a)'\n".utf8))
        }
    }
    return args
}

/// One sub-process invocation: target name + args. SmokeAll always
/// passes the user's `--server` through; per-smoke flags (e.g.
/// `--repeats` for DirectorSmoke) come from the smoke's own defaults.
struct SmokeInvocation: Codable {
    let name: String
    let args: [String]
}

struct SmokeResult: Codable {
    let name: String
    let args: [String]
    let exitCode: Int32
    let wallMs: Int
    let stdoutBytes: Int
    let stderrBytes: Int
}

/// Snapshot of one full-suite run. Frozen for diffing + future
/// ServerCapabilities consumption.
struct SmokeSnapshot: Codable {
    let modelName: String
    let ranAt: Date
    let smokes: [SmokeResult]
    let observations: [ModelObservation]
    let logRunCount: Int
}

let cliArgs = parseArgs()

// SmokeAll's print() output and sub-process output share our stdout
// fd. When stdout is a pipe (e.g. `swift run SmokeAll | tail`), Swift's
// print() falls back to fully-buffered mode while sub-processes write
// line-buffered — so without this, our headers/banners appear AFTER
// the sub-process output instead of before it. Force line-buffering so
// the per-smoke banners print in the correct interleaved order.
setlinebuf(stdout)

print("--- SmokeAll ---")
print("server: \(cliArgs.server.absoluteString)")
if !cliArgs.skip.isEmpty {
    print("skip:   \(cliArgs.skip.sorted().joined(separator: ", "))")
}
if let dp = cliArgs.diffPath {
    print("diff:   \(dp)")
}
print("--------------------")

// Probe model name once at the top — every sub-process probes
// independently too, but we want our snapshot key to match.
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

guard let model = probedModelName else {
    FileHandle.standardError.write(Data("error: model probe failed — SmokeAll requires a known model name to key its snapshot.\n".utf8))
    exit(2)
}
print("model:  \(model)")
print("--------------------")

// Suite definition. Order matters only for deterministic stdout —
// each smoke writes to the per-model observation log independently
// and the dedupe is order-insensitive.
let suite: [SmokeInvocation] = [
    SmokeInvocation(name: "ChatSmoke",        args: ["--server", cliArgs.server.absoluteString]),
    SmokeInvocation(name: "SummariserSmoke",  args: ["--server", cliArgs.server.absoluteString]),
    SmokeInvocation(name: "DirectorSmoke",    args: ["--server", cliArgs.server.absoluteString, "--repeats", "3"]),
    SmokeInvocation(name: "ExtractorSmoke",   args: ["--server", cliArgs.server.absoluteString]),
    SmokeInvocation(name: "BlurberSmoke",     args: ["--server", cliArgs.server.absoluteString]),
    SmokeInvocation(name: "EmbedSmoke",       args: ["--server", cliArgs.server.absoluteString]),
]

/// Resolve the path to a built smoke binary. We invoke `.build/debug/<name>`
/// directly rather than `swift run <name>` because `swift run` does an
/// incremental rebuild on every call — adds 1-3s of overhead per smoke
/// to a suite that takes ~30-60s total. The binaries are expected to
/// exist (run `swift build` once before SmokeAll).
func smokeBinaryURL(_ name: String) -> URL {
    URL(fileURLWithPath: ".build/debug/\(name)")
}

func runSubprocess(_ inv: SmokeInvocation) -> SmokeResult {
    let url = smokeBinaryURL(inv.name)
    if !FileManager.default.isExecutableFile(atPath: url.path) {
        print("[skip] \(inv.name) — binary not found at \(url.path) — run `swift build` first.")
        return SmokeResult(name: inv.name, args: inv.args, exitCode: 127, wallMs: 0, stdoutBytes: 0, stderrBytes: 0)
    }
    print("")
    print("====================================================")
    print("=== \(inv.name) \(inv.args.joined(separator: " "))")
    print("====================================================")
    // Inherit our stdout/stderr directly so the sub-process writes
    // straight to the terminal — no Pipe()/readabilityHandler dance.
    // Inheritance gives true real-time streaming (no buffering layer
    // to drain after exit) at the cost of byte-count instrumentation;
    // we recover the byte counts by stat'ing the post-run log size
    // delta, but that's coarse — reported counts for SmokeAll are
    // 'unknown' (-1) under inheritance, set in the snapshot below.
    let p = Process()
    p.executableURL = url
    p.arguments = inv.args
    p.standardOutput = FileHandle.standardOutput
    p.standardError = FileHandle.standardError
    let started = Date()

    do {
        try p.run()
    } catch {
        FileHandle.standardError.write(Data("error: failed to launch \(inv.name) — \(error)\n".utf8))
        return SmokeResult(name: inv.name, args: inv.args, exitCode: 126, wallMs: 0, stdoutBytes: 0, stderrBytes: 0)
    }
    p.waitUntilExit()
    let wallMs = Int(Date().timeIntervalSince(started) * 1000)
    // Byte counts are -1 under inheritance; SmokeAll's snapshot
    // doesn't actually need them for ServerCapabilities consumption,
    // but they're left in the schema for future capture mode.
    return SmokeResult(name: inv.name, args: inv.args, exitCode: p.terminationStatus,
                       wallMs: wallMs, stdoutBytes: -1, stderrBytes: -1)
}

var results: [SmokeResult] = []
for inv in suite {
    if cliArgs.skip.contains(inv.name) {
        print("\n--- skipping \(inv.name) per --skip ---")
        continue
    }
    results.append(runSubprocess(inv))
}

// Read the per-model log AFTER all smokes have written to it; the
// snapshot's `observations` field is the post-run state. If the log
// doesn't exist yet (first ever run, all smokes failed cleanly), we
// snapshot an empty array.
let log = (try? ModelObservationStore.load(modelName: model)) ?? ModelObservationLog(
    modelName: model, firstSeen: Date(), lastSeen: Date(), runCount: 0, observations: []
)
let snapshot = SmokeSnapshot(
    modelName: model,
    ranAt: Date(),
    smokes: results,
    observations: log.observations,
    logRunCount: log.runCount
)

let reportsDir = FileManager.default
    .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    .appendingPathComponent("RPClient", isDirectory: true)
    .appendingPathComponent("smoke-reports", isDirectory: true)
try? FileManager.default.createDirectory(at: reportsDir, withIntermediateDirectories: true)

let ts = ISO8601DateFormatter().string(from: snapshot.ranAt)
    .replacingOccurrences(of: ":", with: "-")  // file-safe
let safeName = ModelObservationStore.sanitize(modelName: model)
let snapshotURL = reportsDir.appendingPathComponent("\(safeName)-\(ts).json")

let encoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = [.prettyPrinted, .sortedKeys]
    e.dateEncodingStrategy = .iso8601
    return e
}()
let decoder: JSONDecoder = {
    let d = JSONDecoder()
    d.dateDecodingStrategy = .iso8601
    return d
}()

do {
    try encoder.encode(snapshot).write(to: snapshotURL, options: .atomic)
    print("")
    print("snapshot: \(snapshotURL.path)")
} catch {
    FileHandle.standardError.write(Data("warning: failed to write snapshot — \(error)\n".utf8))
}

// Diff. Compare current snapshot's observations against a prior
// snapshot's observations, keyed by `dedupeKey` (smoke|fixture|kind).
if let priorPath = cliArgs.diffPath {
    let priorURL = URL(fileURLWithPath: priorPath)
    do {
        let priorData = try Data(contentsOf: priorURL)
        let prior = try decoder.decode(SmokeSnapshot.self, from: priorData)
        let priorByKey: [String: ModelObservation] = Dictionary(uniqueKeysWithValues: prior.observations.map { ($0.dedupeKey, $0) })
        let currByKey: [String: ModelObservation] = Dictionary(uniqueKeysWithValues: snapshot.observations.map { ($0.dedupeKey, $0) })

        var newKeys: [String] = []
        var goneKeys: [String] = []
        var changedKeys: [String] = []
        for k in currByKey.keys where priorByKey[k] == nil { newKeys.append(k) }
        for k in priorByKey.keys where currByKey[k] == nil { goneKeys.append(k) }
        for (k, c) in currByKey {
            if let p = priorByKey[k], p.details != c.details { changedKeys.append(k) }
        }
        print("")
        print("==================== diff vs \(priorPath) ====================")
        if newKeys.isEmpty && goneKeys.isEmpty && changedKeys.isEmpty {
            print("no observation deltas — same quirks present in both snapshots.")
        } else {
            for k in newKeys.sorted() {
                let o = currByKey[k]!
                print("  NEW    [\(k)] — \(o.details)")
            }
            for k in goneKeys.sorted() {
                let o = priorByKey[k]!
                print("  GONE   [\(k)] (was: \(o.details))")
            }
            for k in changedKeys.sorted() {
                let p = priorByKey[k]!, c = currByKey[k]!
                print("  CHANGED [\(k)]")
                print("           was: \(p.details)")
                print("           now: \(c.details)")
            }
        }
        print("model: prior=\(prior.modelName) current=\(snapshot.modelName)")
        if prior.modelName != snapshot.modelName {
            print("  ⚠ different exact model names — diffing across model swaps is informative but per-model fix decisions stay isolated. See V2_PHASE10_SMOKE_HARNESS_RUNBOOK.md.")
        }
    } catch {
        FileHandle.standardError.write(Data("warning: --diff failed — \(error)\n".utf8))
    }
}

// Top-level summary table.
print("")
print("==================== run summary ====================")
let totalMs = results.reduce(0) { $0 + $1.wallMs }
let failures = results.filter { $0.exitCode != 0 }.count
let nameWidth = max(18, results.map { $0.name.count }.max() ?? 18)
for r in results {
    let pad = String(repeating: " ", count: max(0, nameWidth - r.name.count))
    let flag = r.exitCode == 0 ? " " : "✗"
    print(String(format: " %@ %@%@  exit=%d  %5dms",
                 flag, r.name, pad, r.exitCode, r.wallMs))
}
print("total: \(results.count) smokes, \(totalMs)ms, \(failures) failure(s)")
print("model: \(model)")
print("observations in log: \(snapshot.observations.count) (runCount: \(snapshot.logRunCount))")

exit(failures == 0 ? 0 : 1)
