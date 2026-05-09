import Foundation
@testable import RPClientCore

// Phase 10 §10.a — admin CLI for the per-EXACT-model
// ModelCapabilities store. Read / write / delete records keyed by
// the model's exact `/api/v1/model` string. Used by Claude (or the
// user, solo) to encode validated fix recommendations from the
// smoke harness into ChatPathOverrides records that the chat path
// will eventually read (§10.c).
//
// The runbook (V2_PHASE10_SMOKE_HARNESS_RUNBOOK.md) is the
// procedural source of truth. This binary is the convenience
// surface — a thin wrapper around ModelCapabilitiesStore so the
// per-EXACT-model invariant is enforced by the only path that
// writes records.
//
// usage:
//   swift run ModelCapsAdmin list
//       — print every saved record (one per exact model name)
//   swift run ModelCapsAdmin show MODEL_NAME
//       — pretty-print one record
//   swift run ModelCapsAdmin delete MODEL_NAME
//       — remove ONE record. Other models' records untouched.
//   swift run ModelCapsAdmin set MODEL_NAME KEY=VALUE [KEY=VALUE ...]
//                            [--note "..."]
//       — create or update a record. Each KEY=VALUE sets one
//         override field. Unrecognised keys exit non-zero.
//
//   Recognised KEYs:
//     thinking-prefill       needed | harmless | unknown
//     sampler                <preset id> ("balanced" | "creative" | "precise")
//     stop-augment           comma-separated stop sequences
//     group-nudge            standard | strong | continuing | stop-augment | strong-stop
//     max-ctx-cap            <int>
//     refusal-posture        permissive | aligned | unknown
//
// example:
//   swift run ModelCapsAdmin set \
//     "koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M" \
//     group-nudge=continuing thinking-prefill=needed \
//     --note "validated 2/3 clean on group-chat per V2_PHASE10_CHAT_TUNING_RESEARCH.md"

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else {
    FileHandle.standardError.write(Data("usage: list | show MODEL | delete MODEL | set MODEL KEY=VAL...\n".utf8))
    exit(2)
}

func parseSet(_ rest: [String]) -> (modelName: String, fields: [(String, String)], note: String?) {
    guard let modelName = rest.first else {
        FileHandle.standardError.write(Data("error: set requires MODEL_NAME\n".utf8))
        exit(2)
    }
    var fields: [(String, String)] = []
    var note: String? = nil
    var i = 1
    while i < rest.count {
        let a = rest[i]
        if a == "--note" {
            i += 1
            if i < rest.count { note = rest[i] }
        } else if let eq = a.firstIndex(of: "=") {
            let k = String(a[a.startIndex..<eq])
            let v = String(a[a.index(after: eq)...])
            fields.append((k, v))
        } else {
            FileHandle.standardError.write(Data("error: unrecognised arg '\(a)' (expected KEY=VALUE or --note)\n".utf8))
            exit(2)
        }
        i += 1
    }
    return (modelName, fields, note)
}

/// Apply one KEY=VALUE override field. Returns `false` if the key
/// is unrecognised (caller exits non-zero); `true` on success.
func applyField(_ key: String, _ value: String, into overrides: inout ChatPathOverrides) -> Bool {
    switch key {
    case "thinking-prefill":
        guard let v = ThinkingPrefill(rawValue: value) else {
            FileHandle.standardError.write(Data("error: unknown thinking-prefill '\(value)' (try needed/harmless/unknown)\n".utf8))
            exit(2)
        }
        overrides.thinkingPrefill = v
    case "sampler":
        // Validate against the bundled preset list so a typo doesn't
        // ship a broken record.
        guard SamplerPreset.presets.contains(where: { $0.id == value }) else {
            FileHandle.standardError.write(Data("error: unknown sampler id '\(value)'; valid: \(SamplerPreset.presets.map(\.id).joined(separator: ", "))\n".utf8))
            exit(2)
        }
        overrides.recommendedSamplerId = value
    case "stop-augment":
        // Comma-separated; allow `\n` escapes for newline-prefixed
        // stop sequences (the common case for role-prefix stops).
        let parts = value
            .split(separator: ",")
            .map { String($0).replacingOccurrences(of: "\\n", with: "\n") }
        overrides.stopSequenceAugmentation = parts
    case "group-nudge":
        guard let v = GroupNudgeStyle(rawValue: value) else {
            FileHandle.standardError.write(Data("error: unknown group-nudge '\(value)' (try standard/strong/continuing/stop-augment/strong-stop)\n".utf8))
            exit(2)
        }
        overrides.groupNudgeStyle = v
    case "max-ctx-cap":
        guard let n = Int(value), n > 0 else {
            FileHandle.standardError.write(Data("error: max-ctx-cap must be a positive integer (got '\(value)')\n".utf8))
            exit(2)
        }
        overrides.maxCtxCap = n
    case "refusal-posture":
        guard let v = RefusalPosture(rawValue: value) else {
            FileHandle.standardError.write(Data("error: unknown refusal-posture '\(value)' (try permissive/aligned/unknown)\n".utf8))
            exit(2)
        }
        overrides.refusalPostureOverride = v
    default:
        return false
    }
    return true
}

func renderRecord(_ caps: ModelCapabilities) {
    print("--- \(caps.modelName) ---")
    print("recordedAt:    \(ISO8601DateFormatter().string(from: caps.recordedAt))")
    print("schemaVersion: \(caps.schemaVersion)")
    if let n = caps.notes, !n.isEmpty {
        print("notes:         \(n)")
    }
    print("detected:")
    if let h = caps.detected.modelFamilyHint { print("  modelFamilyHint:    \(h)") }
    if let m = caps.detected.maxCtx { print("  maxCtx:             \(m)") }
    if let j = caps.detected.supportsJsonSchema { print("  supportsJsonSchema: \(j)") }
    if let e = caps.detected.supportsEmbeddings { print("  supportsEmbeddings: \(e)") }
    if let v = caps.detected.koboldVersion { print("  koboldVersion:      \(v)") }
    print("overrides: \(caps.overrides.isEmpty ? "(none — falls back to global defaults)" : "")")
    if let v = caps.overrides.thinkingPrefill { print("  thinking-prefill:   \(v.rawValue)") }
    if let v = caps.overrides.recommendedSamplerId { print("  sampler:            \(v)") }
    if let v = caps.overrides.stopSequenceAugmentation { print("  stop-augment:       \(v)") }
    if let v = caps.overrides.groupNudgeStyle { print("  group-nudge:        \(v.rawValue)") }
    if let v = caps.overrides.maxCtxCap { print("  max-ctx-cap:        \(v)") }
    if let v = caps.overrides.refusalPostureOverride { print("  refusal-posture:    \(v.rawValue)") }
    print("file:          \(ModelCapabilitiesStore.reportPath(forModelName: caps.modelName).path)")
}

switch cmd {
case "list":
    let all = (try? ModelCapabilitiesStore.listAll()) ?? []
    if all.isEmpty {
        print("(no records — directory is empty or doesn't exist)")
        exit(0)
    }
    for r in all.sorted(by: { $0.modelName < $1.modelName }) {
        renderRecord(r)
        print("")
    }
case "show":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: show MODEL_NAME\n".utf8))
        exit(2)
    }
    do {
        let r = try ModelCapabilitiesStore.load(modelName: args[1])
        if let r {
            renderRecord(r)
        } else {
            print("(no record for \(args[1]))")
            exit(1)
        }
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
case "delete":
    guard args.count >= 2 else {
        FileHandle.standardError.write(Data("usage: delete MODEL_NAME\n".utf8))
        exit(2)
    }
    do {
        try ModelCapabilitiesStore.delete(modelName: args[1])
        print("deleted record for \(args[1]) (other models' records untouched).")
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
case "set":
    let parsed = parseSet(Array(args.dropFirst()))
    // Load existing record (if any) so we MERGE the new fields in
    // rather than overwriting the whole record. This lets the user
    // / Claude apply one override at a time without erasing prior
    // ones — e.g. "set thinking-prefill" followed later by "set
    // group-nudge" leaves both set.
    let existing = (try? ModelCapabilitiesStore.load(modelName: parsed.modelName)) ?? nil
    var caps: ModelCapabilities
    if let e = existing {
        caps = e
    } else {
        caps = ModelCapabilities(
            modelName: parsed.modelName,
            recordedAt: Date(),
            schemaVersion: ModelCapabilities.currentSchemaVersion,
            notes: nil,
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
    }
    if let n = parsed.note { caps.notes = n }
    for (k, v) in parsed.fields {
        if !applyField(k, v, into: &caps.overrides) {
            FileHandle.standardError.write(Data("error: unknown override key '\(k)'\n".utf8))
            exit(2)
        }
    }
    do {
        let url = try ModelCapabilitiesStore.save(caps)
        print("saved record for \(parsed.modelName) → \(url.path)")
        renderRecord(caps)
    } catch {
        FileHandle.standardError.write(Data("error: \(error)\n".utf8))
        exit(1)
    }
default:
    FileHandle.standardError.write(Data("error: unknown command '\(cmd)' (try list | show | delete | set)\n".utf8))
    exit(2)
}
