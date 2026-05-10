import Foundation
@testable import RPClientCore

/// Tests for `KokoroModelStore` — live state queries + atomic manifest
/// writes against a real filesystem (per-test tmpdir). Phase 6 §7.1e.
func kokoroModelStoreTests() -> TestSuite {
    let s = TestSuite("KokoroModelStore")

    func makeTmpRoot() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpclient-test-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    s.test("baseModelState is .missing on a fresh root") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: root))
        try expectEqual(store.baseModelState(), .missing)
    }

    s.test("voiceState(id:) is .missing on a fresh root") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: root))
        try expectEqual(store.voiceState(id: "af_bella"), .missing)
        try expectEqual(store.installedVoiceIds(), [])
    }

    s.test("recordModelDownloaded creates the kokoro/ + voices/ dirs and writes manifest") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)
        let store = KokoroModelStore(paths: paths)

        try store.recordModelDownloaded(sha256: "abc", bytes: 325_532_387)
        try expect(FileManager.default.fileExists(atPath: paths.manifestURL.path))
        try expect(FileManager.default.fileExists(atPath: paths.voicesDirURL.path))

        // State after recording: model is `.ready` only if the file is also on
        // disk. The record alone is bookkeeping — physical presence still
        // matters.
        let beforePhysical = store.baseModelState()
        try expectEqual(beforePhysical, .missing)

        // Drop a placeholder file in the model location — now state flips.
        try Data("placeholder".utf8).write(to: paths.modelURL)
        let after = store.baseModelState()
        guard case .ready(let url, let sha) = after else {
            try expect(false, "expected .ready, got \(after)")
            return
        }
        try expectEqual(url, paths.modelURL)
        try expectEqual(sha, "abc")
    }

    s.test("recordVoiceDownloaded + physical file → voiceState is .ready, listed in installedVoiceIds") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)
        let store = KokoroModelStore(paths: paths)

        try store.recordVoiceDownloaded(id: "af_bella", sha256: "feedface", bytes: 523_425)
        // Bookkeeping alone isn't enough — file must also exist.
        try expectEqual(store.voiceState(id: "af_bella"), .missing)

        try Data("voice-blob".utf8).write(to: paths.voiceFileURL(id: "af_bella"))
        let after = store.voiceState(id: "af_bella")
        guard case .ready(let url, let sha) = after else {
            try expect(false, "expected .ready, got \(after)")
            return
        }
        try expectEqual(url, paths.voiceFileURL(id: "af_bella"))
        try expectEqual(sha, "feedface")
        try expectEqual(store.installedVoiceIds(), ["af_bella"])
    }

    s.test("removeVoice deletes the file + manifest entry") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)
        let store = KokoroModelStore(paths: paths)

        try store.recordVoiceDownloaded(id: "af_bella", sha256: "x", bytes: 1)
        try Data("v".utf8).write(to: paths.voiceFileURL(id: "af_bella"))

        try store.removeVoice(id: "af_bella")

        try expect(!FileManager.default.fileExists(atPath: paths.voiceFileURL(id: "af_bella").path))
        try expectEqual(store.voiceState(id: "af_bella"), .missing)
        try expectEqual(store.installedVoiceIds(), [])
    }

    s.test("removeVoice on an absent id is a no-op (idempotent)") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: root))
        try store.removeVoice(id: "never_downloaded")  // doesn't throw
        try expectEqual(store.voiceState(id: "never_downloaded"), .missing)
    }

    s.test("removeModel deletes the file + manifest entry") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)
        let store = KokoroModelStore(paths: paths)
        try store.recordModelDownloaded(sha256: "x", bytes: 1)
        try Data("m".utf8).write(to: paths.modelURL)

        try store.removeModel()
        try expect(!FileManager.default.fileExists(atPath: paths.modelURL.path))
        try expectEqual(store.baseModelState(), .missing)
    }

    s.test("orphan voice file with no manifest entry still reads as .ready (file presence wins)") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)
        let store = KokoroModelStore(paths: paths)
        try FileManager.default.createDirectory(at: paths.voicesDirURL, withIntermediateDirectories: true)
        try Data("orphan".utf8).write(to: paths.voiceFileURL(id: "am_eric"))

        let after = store.voiceState(id: "am_eric")
        guard case .ready(_, let sha) = after else {
            try expect(false, "expected .ready for orphan file, got \(after)")
            return
        }
        try expectNil(sha)  // no manifest record yet → sha is nil
    }

    s.test("manifest persists across two store instances against the same root") {
        let root = makeTmpRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = KokoroStoragePaths(root: root)

        let s1 = KokoroModelStore(paths: paths)
        try s1.recordVoiceDownloaded(id: "bf_emma", sha256: "deadbeef", bytes: 523_420)

        let s2 = KokoroModelStore(paths: paths)
        try expectEqual(s2.currentManifest().voices["bf_emma"]?.sha256, "deadbeef")
    }

    s.test("stateForVolume is .volumeUnavailable when the configured root is on a missing volume") {
        // Synthesises a path under a non-existent /Volumes/Phantom — the parent
        // doesn't exist and we can't create it (no permissions on /Volumes for
        // arbitrary names).
        let phantom = URL(fileURLWithPath: "/Volumes/Phantom-\(UUID().uuidString)/voice-models")
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: phantom))
        // Model state must be .volumeUnavailable, not .missing — the
        // distinction matters for the AVKit fallback decision.
        try expectEqual(store.baseModelState(), .volumeUnavailable)
        try expectEqual(store.voiceState(id: "af_bella"), .volumeUnavailable)
    }

    return s
}
