import Foundation
@testable import RPClientCore

// Phase 10 §10.a — tests for the per-EXACT-model ModelCapabilities
// data model and store.
//
// The invariant the tests enforce:
//   - Distinct exact model names ALWAYS get distinct records on disk.
//   - Saving a record for model B never reads, mutates, or removes
//     any record for model A.
//   - Lookup-by-exact-name with no record returns a default-overrides
//     value (so chat-path callers can `?? globalDefault` without
//     special-casing missing records).
//   - All fields round-trip through encode/decode without loss.
func modelCapabilitiesTests() -> TestSuite {
    let s = TestSuite("ModelCapabilities")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    s.test("ChatPathOverrides default is all-nil") {
        let o = ChatPathOverrides()
        try expectNil(o.thinkingPrefill)
        try expectNil(o.recommendedSamplerId)
        try expectNil(o.stopSequenceAugmentation)
        try expectNil(o.groupNudgeStyle)
        try expectNil(o.maxCtxCap)
        try expectNil(o.refusalPostureOverride)
    }

    s.test("ModelCapabilities round-trips with full overrides") {
        let now = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var caps = ModelCapabilities(
            modelName: "test/example-v1",
            recordedAt: now,
            schemaVersion: 1,
            notes: "round-trip test",
            detected: DetectedCapabilities(
                modelFamilyHint: "qwen",
                maxCtx: 16384,
                supportsJsonSchema: true,
                supportsEmbeddings: true,
                koboldVersion: "1.111.2"
            ),
            overrides: ChatPathOverrides()
        )
        caps.overrides.thinkingPrefill = .needed
        caps.overrides.recommendedSamplerId = "balanced"
        caps.overrides.stopSequenceAugmentation = ["\nOther:"]
        caps.overrides.groupNudgeStyle = .continuing
        caps.overrides.maxCtxCap = 8192
        caps.overrides.refusalPostureOverride = .permissive

        let data = try encoder.encode(caps)
        let decoded = try decoder.decode(ModelCapabilities.self, from: data)
        try expectEqual(decoded, caps)
    }

    s.test("store sanitises model name to filesystem-safe filename") {
        let raw = "koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M"
        let url = ModelCapabilitiesStore.reportPath(forModelName: raw)
        try expectFalse(url.lastPathComponent.contains("/"))
        try expectTrue(url.lastPathComponent.hasSuffix(".json"))
    }

    s.test("save then load round-trips through disk") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date()
        var caps = ModelCapabilities(
            modelName: "test/save-load-A",
            recordedAt: now,
            schemaVersion: 1,
            notes: nil,
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
        caps.overrides.groupNudgeStyle = .strongStop

        _ = try ModelCapabilitiesStore.save(caps, in: tmp)
        let loaded = try expectNotNil(ModelCapabilitiesStore.load(modelName: "test/save-load-A", in: tmp))
        try expectEqual(loaded.overrides.groupNudgeStyle, .strongStop)
    }

    s.test("save for one model NEVER mutates another model's record") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let modelA = "test/Qwen3.6-Q4-variant"
        let modelB = "test/Qwen3.6-Q5-variant"   // same family, different exact

        var capsA = ModelCapabilities(
            modelName: modelA, recordedAt: Date(), schemaVersion: 1,
            notes: "model A — applied fix",
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
        capsA.overrides.groupNudgeStyle = .continuing
        capsA.overrides.thinkingPrefill = .needed

        // Save A first.
        _ = try ModelCapabilitiesStore.save(capsA, in: tmp)

        // Now save B with completely different overrides.
        var capsB = ModelCapabilities(
            modelName: modelB, recordedAt: Date(), schemaVersion: 1,
            notes: "model B — different fix",
            detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
        capsB.overrides.groupNudgeStyle = .strongStop
        capsB.overrides.thinkingPrefill = .harmless
        _ = try ModelCapabilitiesStore.save(capsB, in: tmp)

        // Load both back. A's record must be EXACTLY what we saved
        // — no fields touched, no sharing with B.
        let loadedA = try expectNotNil(ModelCapabilitiesStore.load(modelName: modelA, in: tmp))
        try expectEqual(loadedA.overrides.groupNudgeStyle, .continuing)
        try expectEqual(loadedA.overrides.thinkingPrefill, .needed)
        try expectEqual(loadedA.notes, "model A — applied fix")

        let loadedB = try expectNotNil(ModelCapabilitiesStore.load(modelName: modelB, in: tmp))
        try expectEqual(loadedB.overrides.groupNudgeStyle, .strongStop)
        try expectEqual(loadedB.overrides.thinkingPrefill, .harmless)
    }

    s.test("listAll enumerates every saved record") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        for name in ["test/m1", "test/m2", "test/m3-different-quant"] {
            let c = ModelCapabilities(
                modelName: name, recordedAt: Date(), schemaVersion: 1,
                notes: nil, detected: DetectedCapabilities(),
                overrides: ChatPathOverrides()
            )
            _ = try ModelCapabilitiesStore.save(c, in: tmp)
        }
        let all = try ModelCapabilitiesStore.listAll(in: tmp)
        try expectEqual(all.count, 3)
        let names = Set(all.map(\.modelName))
        try expectTrue(names.contains("test/m1"))
        try expectTrue(names.contains("test/m2"))
        try expectTrue(names.contains("test/m3-different-quant"))
    }

    s.test("lookupOrDefault returns a defaults-only record when no file exists") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let result = ModelCapabilitiesStore.lookupOrDefault(modelName: "test/never-saved", in: tmp)
        try expectEqual(result.modelName, "test/never-saved")
        try expectNil(result.overrides.thinkingPrefill)
        try expectNil(result.overrides.groupNudgeStyle)
    }

    s.test("lookupOrDefault returns the saved record when one exists") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let name = "test/exists"
        var caps = ModelCapabilities(
            modelName: name, recordedAt: Date(), schemaVersion: 1,
            notes: nil, detected: DetectedCapabilities(),
            overrides: ChatPathOverrides()
        )
        caps.overrides.groupNudgeStyle = .strong
        _ = try ModelCapabilitiesStore.save(caps, in: tmp)

        let result = ModelCapabilitiesStore.lookupOrDefault(modelName: name, in: tmp)
        try expectEqual(result.overrides.groupNudgeStyle, .strong)
    }

    s.test("delete removes a single model's file without touching others") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerCaps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let nameA = "test/keep-me"
        let nameB = "test/delete-me"
        for n in [nameA, nameB] {
            let c = ModelCapabilities(
                modelName: n, recordedAt: Date(), schemaVersion: 1,
                notes: nil, detected: DetectedCapabilities(),
                overrides: ChatPathOverrides()
            )
            _ = try ModelCapabilitiesStore.save(c, in: tmp)
        }
        try ModelCapabilitiesStore.delete(modelName: nameB, in: tmp)
        try expectNotNil(try ModelCapabilitiesStore.load(modelName: nameA, in: tmp))
        try expectNil(try ModelCapabilitiesStore.load(modelName: nameB, in: tmp))
    }

    return s
}
