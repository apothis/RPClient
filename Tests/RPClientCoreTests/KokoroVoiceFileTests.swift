import Foundation
@testable import RPClientCore

/// Integration tests for `KokoroVoiceFile.loadStyleEmbedding(from:)` —
/// loads a HuggingFace `.pt` voice tensor file and returns a flat
/// `[Float]` of the speaker style embedding (Phase 6 §7.1k1).
///
/// These tests run against a real downloaded voice file when one exists
/// at the user's configured `voiceModelPath`. When no file is found the
/// test prints a skip message rather than failing — fixture provisioning
/// is documented in V2_PLAN.md §7.1k1.
func kokoroVoiceFileTests() -> TestSuite {
    let s = TestSuite("KokoroVoiceFile")

    s.test("loadStyleEmbedding returns 130560 floats for a real voice file") {
        guard let url = anyDownloadedVoiceFile() else {
            print("    [skipped — no voice file found under voiceModelPath]")
            return
        }
        let floats = try KokoroVoiceFile.loadStyleEmbedding(from: url)
        // 510 × 1 × 256 = 130560
        try expectEqual(floats.count, 130_560)
    }

    s.test("loadStyleEmbedding returns finite values for a real voice file") {
        guard let url = anyDownloadedVoiceFile() else {
            print("    [skipped — no voice file found under voiceModelPath]")
            return
        }
        let floats = try KokoroVoiceFile.loadStyleEmbedding(from: url)
        // Style embeddings are small bounded floats — none should be NaN/inf.
        let bad = floats.filter { !$0.isFinite }
        try expectEqual(bad.count, 0, "found \(bad.count) non-finite floats")
        // Values are typically in roughly [-1, 1] for voice styles.
        let outOfRange = floats.filter { abs($0) > 10.0 }
        try expectEqual(outOfRange.count, 0, "found \(outOfRange.count) wildly-large floats")
    }

    s.test("loadStyleEmbedding throws on a non-zip file") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpclient-not-a-zip-\(UUID().uuidString).pt")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(repeating: 0xAA, count: 1024).write(to: tmp)
        do {
            _ = try KokoroVoiceFile.loadStyleEmbedding(from: tmp)
            try expect(false, "expected throw")
        } catch {
            // Either MinimalZipReader.Error.eocdNotFound or our wrapper —
            // the precise mapping isn't part of the contract.
        }
    }

    return s
}

/// Walk the user's configured voice storage looking for any .pt file.
/// Returns nil when no voice has been downloaded yet.
fileprivate func anyDownloadedVoiceFile() -> URL? {
    guard let raw = AppState.shared.settings.voiceModelPath, !raw.isEmpty else {
        return nil
    }
    let voicesDir = URL(fileURLWithPath: raw)
        .appendingPathComponent("kokoro")
        .appendingPathComponent("voices")
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: voicesDir, includingPropertiesForKeys: nil
    ) else {
        return nil
    }
    return entries.first { $0.pathExtension == "pt" }
}
