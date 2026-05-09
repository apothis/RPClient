import Foundation

// Phase 10 §10.a — per-EXACT-model capability cache + chat-path
// override store. Consumes the empirical findings from the §10.0
// smoke harness suite and exposes them to the chat path so model-
// specific quirks get model-specific fixes.
//
// The per-EXACT-model invariant (V2_PHASE10_SMOKE_HARNESS_RUNBOOK.md):
// every storage layer keys by `/api/v1/model` exact string. Different
// fine-tunes / quants of the "same" model — e.g.
// `Qwen3.6-…-Q4_K_M` vs `Qwen3.6-…-Q5_K_M` — get separate records.
// Family-level inference is a render-time projection, never a
// storage layer. Substring-matching on model name to "share" a fix
// is forbidden at this layer.
//
// What lands in §10.a (this file):
//   - The `ModelCapabilities` data model
//   - The per-EXACT-model store at
//     `~/Library/Application Support/RPClient/model_capabilities/<sanitised>.json`
//   - A `lookupOrDefault` convenience for the chat path's eventual
//     consumption (§10.c) — returns an empty-overrides record so
//     callers can `?? globalDefault` without special-casing missing
//
// What does NOT land in §10.a:
//   - Active probing logic (§10.a's own "ServerProbe" sub-step;
//     scoped separately because probing requires network calls
//     and a coordinated runner)
//   - Chat-path consumption points (§10.c — PromptBuilder etc.
//     read `ChatPathOverrides` and apply per-call)
//   - Settings UI (§10.b)

// MARK: - Domain enums

public enum ThinkingPrefill: String, Codable, Equatable {
    /// Empty `<think></think>` pre-fill is needed (Qwen3+) — the
    /// model expects it and emits cleanly when present.
    case needed
    /// Pre-fill is harmless but wasted bytes (Gemma / Llama / Mistral
    /// don't use thinking blocks — they ignore the empty pre-fill).
    case harmless
    /// Not yet probed for this model — chat path uses the global default.
    case unknown
}

/// One of the candidate fixes validated by the §10.0.f
/// nudge-variant probe pass. See V2_PHASE10_CHAT_TUNING_RESEARCH.md
/// for the empirical reliability data per variant per model.
public enum GroupNudgeStyle: String, Codable, Equatable {
    /// Production default — `[Write the next reply only as X.]`.
    case standard
    /// `[X speaks now. Other cast members are silent for this turn.]`
    /// — stronger directive aimed at models that treat the standard
    /// nudge as a soft hint.
    case strong
    /// Detect the X→X case (last assistant turn was the active
    /// speaker) and use `[Continuing as X.]` to disambiguate
    /// "next reply" from "next speaker." Validated as the best
    /// stand-alone fix for `koboldcpp/Qwen3.6-…-Q4_K_M` (2/3 clean
    /// on group-chat vs standard's 1/3). Fall back to standard in
    /// the X→Y case.
    case continuing
    /// Standard nudge plus `\n<other>:` augmentation of stop
    /// sequences. Bullet-proof on plain group chats but brittle on
    /// prose-heavy fixtures where the model legitimately leads with
    /// `Name:` (truncates response to zero tokens).
    case stopAugment = "stop-augment"
    /// `strong` text + `stop-augment` stops. Best on simple group
    /// chats; same brittleness as `stop-augment` on prose-heavy
    /// fixtures.
    case strongStop = "strong-stop"
}

public enum RefusalPosture: String, Codable, Equatable {
    /// Model produces NSFW content with the bundled license phrase.
    case permissive
    /// Model refuses; soften nothing, surface server-switch.
    case aligned
    /// Not yet probed.
    case unknown
}

// MARK: - Records

/// Detected (probe-derived) capabilities. Distinct from
/// `ChatPathOverrides`: this section describes what the server CAN
/// do; overrides describe what the chat path SHOULD do.
public struct DetectedCapabilities: Codable, Equatable {
    /// Substring-derived family hint ("qwen", "gemma", "llama"…).
    /// Recorded for diagnostic value only; the chat path lookups
    /// must NEVER match on this — only on `ModelCapabilities.modelName`.
    public var modelFamilyHint: String?
    /// `/api/extra/true_max_context_length`.
    public var maxCtx: Int?
    /// `/v1/chat/completions` with `response_format: json_schema`
    /// returned valid output → `true`.
    public var supportsJsonSchema: Bool?
    /// `/v1/embeddings` returned non-empty vectors → `true`.
    public var supportsEmbeddings: Bool?
    /// `/api/extra/version` body.
    public var koboldVersion: String?

    public init(
        modelFamilyHint: String? = nil,
        maxCtx: Int? = nil,
        supportsJsonSchema: Bool? = nil,
        supportsEmbeddings: Bool? = nil,
        koboldVersion: String? = nil
    ) {
        self.modelFamilyHint = modelFamilyHint
        self.maxCtx = maxCtx
        self.supportsJsonSchema = supportsJsonSchema
        self.supportsEmbeddings = supportsEmbeddings
        self.koboldVersion = koboldVersion
    }
}

/// Per-EXACT-model overrides applied to the chat path. EVERY field
/// is optional; a `nil` value means "use the global default." This
/// way a record with one targeted override doesn't accidentally
/// regress every other knob on the chat path.
public struct ChatPathOverrides: Codable, Equatable {
    public var thinkingPrefill: ThinkingPrefill?
    /// SamplerPreset id ("balanced", "creative", "precise").
    /// Resolved against `SamplerPreset.presets` at consumption time.
    public var recommendedSamplerId: String?
    /// Extra stop sequences appended (NOT replacing) the template's
    /// default set. Used by the `groupNudgeStyle = .stopAugment`
    /// candidate and also writable independently.
    public var stopSequenceAugmentation: [String]?
    public var groupNudgeStyle: GroupNudgeStyle?
    /// Hard cap on `effectiveCtx`. When set, the chat path uses
    /// `min(configured, capabilities.maxCtxCap)`. Useful for the
    /// Llama 4 Scout chunked-attention case (cap at 8192 even if
    /// the model card claims 10M).
    public var maxCtxCap: Int?
    public var refusalPostureOverride: RefusalPosture?

    public init(
        thinkingPrefill: ThinkingPrefill? = nil,
        recommendedSamplerId: String? = nil,
        stopSequenceAugmentation: [String]? = nil,
        groupNudgeStyle: GroupNudgeStyle? = nil,
        maxCtxCap: Int? = nil,
        refusalPostureOverride: RefusalPosture? = nil
    ) {
        self.thinkingPrefill = thinkingPrefill
        self.recommendedSamplerId = recommendedSamplerId
        self.stopSequenceAugmentation = stopSequenceAugmentation
        self.groupNudgeStyle = groupNudgeStyle
        self.maxCtxCap = maxCtxCap
        self.refusalPostureOverride = refusalPostureOverride
    }

    /// Are any overrides set? Useful for the chat path to short-
    /// circuit lookup when nothing's in the record.
    public var isEmpty: Bool {
        thinkingPrefill == nil
            && recommendedSamplerId == nil
            && stopSequenceAugmentation == nil
            && groupNudgeStyle == nil
            && maxCtxCap == nil
            && refusalPostureOverride == nil
    }
}

/// One full record per EXACT model name. Persisted at
/// `<model_capabilities>/<sanitised(modelName)>.json`.
public struct ModelCapabilities: Codable, Equatable {
    /// EXACT `/api/v1/model` string. The primary key for the store.
    /// MUST be byte-identical to the model name returned by the
    /// server when this record is consulted; substring matching is
    /// forbidden.
    public let modelName: String
    /// When this record was last written. Updated on every save.
    public var recordedAt: Date
    /// Bumped when the schema (any field's shape) changes; consumers
    /// can refuse to load records with a higher version than they
    /// understand.
    public var schemaVersion: Int
    /// Free-text human note — typically the reasoning behind the
    /// encoded overrides ("validated 2/3 clean on group-chat per
    /// V2_PHASE10_CHAT_TUNING_RESEARCH.md §10.0.f"). Shown in the
    /// §10.b Settings UI.
    public var notes: String?
    public var detected: DetectedCapabilities
    public var overrides: ChatPathOverrides

    public init(
        modelName: String,
        recordedAt: Date,
        schemaVersion: Int,
        notes: String? = nil,
        detected: DetectedCapabilities,
        overrides: ChatPathOverrides
    ) {
        self.modelName = modelName
        self.recordedAt = recordedAt
        self.schemaVersion = schemaVersion
        self.notes = notes
        self.detected = detected
        self.overrides = overrides
    }

    /// Schema version for new records written by this build. Bump
    /// when adding/removing/renaming a field; older readers will
    /// still decode (Codable tolerance) but should treat the higher
    /// version as a "may not understand" hint.
    public static let currentSchemaVersion: Int = 1
}

// MARK: - Store

public enum ModelCapabilitiesStore {
    /// Production directory:
    /// `~/Library/Application Support/RPClient/model_capabilities/`.
    public static func directory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("model_capabilities", isDirectory: true)
    }

    /// Map an EXACT model-name string to a filesystem-safe filename.
    /// Same rule as `ModelObservationStore.sanitize` (per the runbook
    /// — both stores share the per-EXACT-model keying).
    public static func sanitize(modelName: String) -> String {
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-")
        var out = ""
        out.reserveCapacity(modelName.count)
        for ch in modelName {
            if allowed.contains(ch) { out.append(ch) } else { out.append("_") }
        }
        if out.count > 200 { out = String(out.prefix(200)) }
        return out
    }

    public static func reportPath(forModelName modelName: String, in directory: URL? = nil) -> URL {
        let dir = directory ?? Self.directory()
        return dir.appendingPathComponent("\(sanitize(modelName: modelName)).json")
    }

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

    /// Read the record for `modelName`, or `nil` when no file exists.
    /// Throws on I/O / decode error (caller decides whether to treat
    /// as "missing" or as a real failure).
    public static func load(modelName: String, in directory: URL? = nil) throws -> ModelCapabilities? {
        let url = reportPath(forModelName: modelName, in: directory)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        return try decoder.decode(ModelCapabilities.self, from: data)
    }

    /// Save a record. Creates the directory if missing. Atomic write
    /// — never leaves a half-written file even on crash. Returns the
    /// final URL for diagnostic logging.
    @discardableResult
    public static func save(_ caps: ModelCapabilities, in directory: URL? = nil) throws -> URL {
        let dir = directory ?? Self.directory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var withTimestamp = caps
        withTimestamp.recordedAt = Date()
        let url = reportPath(forModelName: caps.modelName, in: directory)
        let data = try encoder.encode(withTimestamp)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// Convenience for the chat path's eventual consumption (§10.c):
    /// returns the saved record if one exists, otherwise an empty-
    /// overrides record with the same model name. Either way, callers
    /// can use `result.overrides.thinkingPrefill ?? globalDefault`
    /// without special-casing the missing case.
    ///
    /// `recordedAt` on the synthesised default is the current time —
    /// callers that care about provenance should `load(modelName:)`
    /// directly and check for `nil` themselves.
    public static func lookupOrDefault(modelName: String, in directory: URL? = nil) -> ModelCapabilities {
        if let existing = (try? load(modelName: modelName, in: directory)) ?? nil {
            return existing
        }
        return ModelCapabilities(
            modelName: modelName,
            recordedAt: Date(),
            schemaVersion: ModelCapabilities.currentSchemaVersion,
            notes: nil,
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
    }

    /// Enumerate every saved record. Order is undefined; callers
    /// sort as needed (Settings UI sorts by lastUsed). Skips files
    /// that fail to decode rather than throwing — protects against
    /// one corrupt file blocking the whole listing.
    public static func listAll(in directory: URL? = nil) throws -> [ModelCapabilities] {
        let dir = directory ?? Self.directory()
        guard let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        var out: [ModelCapabilities] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u),
               let r = try? decoder.decode(ModelCapabilities.self, from: data) {
                out.append(r)
            }
        }
        return out
    }

    /// Remove the record for `modelName`. No-op if not present.
    /// Preserves every OTHER record on disk — the per-EXACT-model
    /// invariant guarantees other models are isolated.
    public static func delete(modelName: String, in directory: URL? = nil) throws {
        let url = reportPath(forModelName: modelName, in: directory)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
}
