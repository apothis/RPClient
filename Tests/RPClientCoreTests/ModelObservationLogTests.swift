import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.b+ — tests for the per-exact-model observation log.
// Keying is by EXACT model name so different variants of the same
// family (Qwen3.6-A3B-Q4_K_M vs Qwen3.6-A3B-Q5_K_M) get separate
// stores — fixes that work for one quant don't necessarily work
// for another. See plan note in ModelObservationLog.swift.
//
// Covered:
//   - filename sanitisation handles slashes / unsafe chars + caps length
//   - append round-trips through encode/decode
//   - re-appending the same dedupeKey updates seenCount + lastSeen,
//     does not duplicate the observation
//   - distinct model names get distinct store files
func modelObservationLogTests() -> TestSuite {
    let s = TestSuite("ModelObservationLog")

    s.test("sanitize replaces slashes and unsafe chars") {
        let raw = "koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M"
        let safe = ModelObservationStore.sanitize(modelName: raw)
        try expectFalse(safe.contains("/"))
        try expectTrue(safe.contains("Qwen3.6"))
        // Sanitised name must round-trip: same input → same output.
        try expectEqual(safe, ModelObservationStore.sanitize(modelName: raw))
    }

    s.test("sanitize caps long names") {
        let long = String(repeating: "x", count: 400)
        let safe = ModelObservationStore.sanitize(modelName: long)
        try expectLessThan(safe.count, 220)
    }

    s.test("sanitize preserves variant suffixes") {
        // Two models that share a family prefix but differ on the
        // quant suffix MUST yield distinct sanitised filenames.
        let a = "koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M"
        let b = "koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q5_K_M"
        try expectFalse(ModelObservationStore.sanitize(modelName: a) == ModelObservationStore.sanitize(modelName: b))
    }

    s.test("append round-trips") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsLog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = "test/ModelA-v1"
        let obs = ModelObservation(
            smoke: "ChatSmoke",
            fixture: "sfw-short",
            timestamp: Date(),
            kind: "short-reply",
            details: "55 chars / 1100 expected",
            remediationHint: "ChatSmoke should auto-set continuation:true on assistant-trailing fixtures."
        )
        try ModelObservationStore.append([obs], modelName: model, in: tmp)
        let log = try expectNotNil(ModelObservationStore.load(modelName: model, in: tmp))
        try expectEqual(log.modelName, model)
        try expectEqual(log.observations.count, 1)
        try expectEqual(log.runCount, 1)
        try expectEqual(log.observations[0].smoke, "ChatSmoke")
        try expectEqual(log.observations[0].fixture, "sfw-short")
        try expectEqual(log.observations[0].kind, "short-reply")
        try expectEqual(log.observations[0].seenCount, 1)
    }

    s.test("re-append same dedupeKey updates seenCount + lastSeen") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsLog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let model = "test/ModelB-v1"
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let t1 = Date(timeIntervalSince1970: 1_700_000_010)
        let obs0 = ModelObservation(smoke: "ChatSmoke", fixture: "sfw-short", timestamp: t0,
                                    kind: "short-reply", details: "first hit", remediationHint: nil)
        let obs1 = ModelObservation(smoke: "ChatSmoke", fixture: "sfw-short", timestamp: t1,
                                    kind: "short-reply", details: "second hit", remediationHint: nil)
        try ModelObservationStore.append([obs0], modelName: model, in: tmp)
        try ModelObservationStore.append([obs1], modelName: model, in: tmp)

        let log = try expectNotNil(ModelObservationStore.load(modelName: model, in: tmp))
        // Same dedupeKey → still ONE entry, not two.
        try expectEqual(log.observations.count, 1)
        try expectEqual(log.observations[0].seenCount, 2)
        // The retained details should be the LATEST observation's details
        // — newer information about the same kind of failure usually beats
        // the first-seen description.
        try expectEqual(log.observations[0].details, "second hit")
        try expectEqual(log.observations[0].timestamp, t1)
        try expectEqual(log.runCount, 2)
    }

    s.test("distinct model names get distinct files") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("ObsLog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let a = "test/ModelA-v1"
        let b = "test/ModelA-v2"  // different exact name; same family
        let obs = ModelObservation(smoke: "ChatSmoke", fixture: "x", timestamp: Date(),
                                   kind: "short-reply", details: "", remediationHint: nil)
        try ModelObservationStore.append([obs], modelName: a, in: tmp)
        try ModelObservationStore.append([obs], modelName: b, in: tmp)
        let logA = try expectNotNil(ModelObservationStore.load(modelName: a, in: tmp))
        let logB = try expectNotNil(ModelObservationStore.load(modelName: b, in: tmp))
        try expectEqual(logA.modelName, a)
        try expectEqual(logB.modelName, b)
        // Two separate files on disk:
        let urlA = ModelObservationStore.reportPath(forModelName: a, in: tmp)
        let urlB = ModelObservationStore.reportPath(forModelName: b, in: tmp)
        try expectFalse(urlA == urlB)
    }

    return s
}
