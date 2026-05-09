import Foundation
@testable import RPClientCore

// Phase 10 §10.0.b+ — per-EXACT-model observation log. Captures
// "weirdness" (refusals, length anomalies, thinking-trace leaks,
// unparseable side-call output, role confusion in multi-cast, etc.)
// from any smoke run, keyed by the exact `/api/v1/model` string.
//
// Why exact, not family: the user explicitly called out that fine-
// tunes / quants of the "same" model can behave differently
// (`Qwen3.6-…-Q4_K_M` vs `Qwen3.6-…-Q5_K_M` are separate stores).
// Family-level grouping is a future analysis layer that reads from
// these exact-keyed files.
//
// What this layer does:
//   1. Records observations to a JSON file at
//      `~/Library/Application Support/RPClient/smoke-observations/<sanitised>.json`.
//   2. Dedupes by `(smoke, fixture, kind)` so a re-run that hits
//      the same quirk increments `seenCount` rather than duplicating.
//   3. Tracks `firstSeen` / `lastSeen` per observation for "is this
//      a regression or a long-standing quirk?" triage.
//
// What this layer does NOT do (deferred to §10.a / §10.c):
//   - Auto-apply remediations to the chat path.
//   - Resolve `ServerCapabilities` from observations.
//   - Diff across model variants ("did Q5 fix a Q4 issue?").
//
// The §10.a `ServerProbe` consumer will read these logs as one of
// its inputs — the smokes write empirical observations, ServerProbe
// (eventually) writes the inferred capabilities, and the chat path
// reads the capabilities. See `V2_PHASE10_CHAT_TUNING_SCOPING.md` §3.

/// One recorded weirdness from a smoke run. `kind` is intentionally
/// a free-form string (not an enum) so smokes can register new
/// detector categories without coordinating an enum-add — the
/// catalogue lives in `ObservationKind` constants below as guidance,
/// not enforcement.
struct ModelObservation: Codable, Equatable {
    /// The smoke binary that recorded this — e.g. "ChatSmoke",
    /// "SummariserSmoke". One observation belongs to exactly one
    /// smoke; cross-smoke aggregation is a render-time concern.
    let smoke: String
    /// Fixture name (e.g. "sfw-long") or "real:<chat-id>" for the
    /// `--chat` path; the smoke decides this string.
    let fixture: String
    /// Most-recent observation timestamp. Initial append sets this
    /// to `now`; re-appends with the same dedupeKey overwrite to
    /// the new timestamp (lastSeen semantics).
    var timestamp: Date
    /// Observation category — one of `ObservationKind`'s constants
    /// when applicable, or any string for new categories.
    let kind: String
    /// Human-readable specifics: the relevant numeric ratio, the
    /// matched regex pattern, the snippet of the offending output,
    /// etc. Kept short; large bodies belong in a transcript file
    /// pointed to by `transcriptHint`.
    var details: String
    /// Suggested fix the smoke runner thinks would address the
    /// observation. Text only — never auto-applied at this layer.
    /// Picked up by §10.a's ServerCapabilities consumer.
    var remediationHint: String?
    /// Number of times this `(smoke, fixture, kind)` triple has been
    /// observed. Bumped on every re-append.
    var seenCount: Int
    /// Earliest observation timestamp. Persisted across re-appends.
    var firstSeen: Date

    init(smoke: String, fixture: String, timestamp: Date, kind: String,
         details: String, remediationHint: String?,
         seenCount: Int = 1, firstSeen: Date? = nil) {
        self.smoke = smoke
        self.fixture = fixture
        self.timestamp = timestamp
        self.kind = kind
        self.details = details
        self.remediationHint = remediationHint
        self.seenCount = seenCount
        self.firstSeen = firstSeen ?? timestamp
    }

    /// Dedupe key — append() collapses entries with the same key.
    /// Different fixtures / smokes hitting the "same kind of
    /// weirdness" stay distinct; that's intentional — fixture-
    /// specific reproduction notes are useful triage.
    var dedupeKey: String { "\(smoke)|\(fixture)|\(kind)" }
}

/// Catalogue of well-known observation kinds. Constants, not enums,
/// because smokes can register new categories without coordinating
/// (the registry consumer reads kind strings; unknowns are surfaced
/// to the user verbatim with no special handling).
enum ObservationKind {
    /// Response is implausibly short relative to expected length.
    /// Often a doubled-prefill artifact in chat smokes; sometimes
    /// a refusal that didn't trigger the regex set; sometimes a
    /// model emitting end-of-turn early.
    static let shortReply = "short-reply"
    /// No tokens at all — model returned an empty stream. Network
    /// drop, server crash, or hard refusal silently truncated.
    static let noTokens = "no-tokens"
    /// Output starts with a refusal pattern from `CardGenRefusalDetector`.
    /// `details` carries the matched pattern name.
    static let refusal = "refusal"
    /// Finished output contains an un-stripped `<think>...</think>`
    /// block. Means the runtime didn't filter the thinking trace AND
    /// the model emitted one despite the empty pre-fill (or the empty
    /// pre-fill was missing for this template).
    static let thinkingTraceLeak = "thinking-trace-leak"
    /// In a multi-cast chat with a group-nudge specifying speaker X,
    /// the response begins with a different cast member's name. Tells
    /// us the nudge isn't load-bearing for this model.
    static let roleConfusionInGroup = "role-confusion-in-group"
    /// Model emitted a stop sequence in the middle of its response
    /// (i.e. the streaming layer didn't actually stop on it). Suggests
    /// either a stop-sequence misconfiguration or a server bug.
    static let stopSequenceUnhonored = "stop-sequence-unhonored"
    /// JSON-mode side-call returned something that didn't conform to
    /// the requested schema.
    static let schemaDeviation = "schema-deviation"
    /// Director picker's response can't be matched to any cast member.
    static let unparseableDirectorPick = "unparseable-director-pick"
    /// Transient: the smoke timed out waiting for first token.
    static let timedOut = "timed-out"
}

/// Persisted log of all observations ever recorded for a single
/// exact model name.
struct ModelObservationLog: Codable, Equatable {
    /// EXACT `/api/v1/model` string. Used as the dedupe key for
    /// store lookup. NOT family-derived — Q4 vs Q5 are distinct.
    let modelName: String
    /// First time we recorded any observation for this model.
    var firstSeen: Date
    /// Most recent run that touched this model's log (any append).
    var lastSeen: Date
    /// How many smoke runs have appended to this log. Useful for
    /// "is the model new or well-explored?" triage.
    var runCount: Int
    /// Deduplicated observations. Append order is preserved; new
    /// kinds land at the tail.
    var observations: [ModelObservation]
}

enum ModelObservationStore {
    // MARK: - Paths

    /// Production directory: `~/Library/Application Support/RPClient/smoke-observations/`.
    /// Smokes that don't pass an explicit `in:` directory write here;
    /// tests pass a temp dir.
    static func directory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("smoke-observations", isDirectory: true)
    }

    /// Map an exact model-name string to a filesystem-safe filename.
    /// Replaces `/` with `_`; collapses any non-`[A-Za-z0-9._-]` to
    /// `_`; caps total length at 200 chars (keeps APFS happy and
    /// leaves room for the `.json` suffix). Two distinct model
    /// names that share a 200-char prefix would collide here — if
    /// that ever bites, swap to `<prefix>-<hash>` keying then.
    static func sanitize(modelName: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var out = ""
        out.reserveCapacity(modelName.count)
        for ch in modelName {
            if allowed.contains(ch) {
                out.append(ch)
            } else {
                out.append("_")
            }
        }
        if out.count > 200 {
            out = String(out.prefix(200))
        }
        return out
    }

    static func reportPath(forModelName modelName: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? Self.directory()
        return dir.appendingPathComponent("\(sanitize(modelName: modelName)).json")
    }

    // MARK: - I/O

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Read the existing log for `modelName`, or nil if no file yet.
    static func load(modelName: String, in directory: URL? = nil) throws -> ModelObservationLog? {
        let url = reportPath(forModelName: modelName, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ModelObservationLog.self, from: data)
    }

    /// Append observations to the log for `modelName`. Re-appends
    /// with the same `dedupeKey` increment `seenCount` and update
    /// `details` / `timestamp` / `remediationHint` to the latest
    /// values; `firstSeen` is preserved. Bumps the log's `runCount`
    /// once per call (not once per observation) so the counter
    /// reflects "smoke runs," not "observations recorded."
    @discardableResult
    static func append(_ obs: [ModelObservation], modelName: String, in directory: URL? = nil) throws -> URL {
        let dir = directory ?? Self.directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let now = Date()
        var log = try load(modelName: modelName, in: directory)
            ?? ModelObservationLog(modelName: modelName, firstSeen: now, lastSeen: now, runCount: 0, observations: [])

        log.lastSeen = now
        log.runCount += 1
        for incoming in obs {
            if let idx = log.observations.firstIndex(where: { $0.dedupeKey == incoming.dedupeKey }) {
                var existing = log.observations[idx]
                existing.seenCount += 1
                existing.timestamp = incoming.timestamp
                existing.details = incoming.details
                if let hint = incoming.remediationHint {
                    existing.remediationHint = hint
                }
                log.observations[idx] = existing
            } else {
                var fresh = incoming
                fresh.seenCount = max(1, incoming.seenCount)
                fresh.firstSeen = incoming.firstSeen
                log.observations.append(fresh)
            }
        }

        let url = reportPath(forModelName: modelName, in: directory)
        let data = try encoder.encode(log)
        try data.write(to: url, options: .atomic)
        return url
    }
}
