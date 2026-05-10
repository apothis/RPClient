import Foundation
@testable import RPClientCore

/// Tests for `KokoroStoragePaths` — pure URL layout helper for the on-disk
/// model + voice files. Phase 6 §7.1d.
func kokoroStoragePathsTests() -> TestSuite {
    let s = TestSuite("KokoroStoragePaths")

    let root = URL(fileURLWithPath: "/Volumes/SSD1/voice-models")
    let paths = KokoroStoragePaths(root: root)

    s.test("modelURL is <root>/kokoro/model.onnx") {
        try expectEqual(paths.modelURL.path, "/Volumes/SSD1/voice-models/kokoro/model.onnx")
    }

    s.test("voicesDirURL is <root>/kokoro/voices") {
        try expectEqual(paths.voicesDirURL.path, "/Volumes/SSD1/voice-models/kokoro/voices")
    }

    s.test("manifestURL is <root>/kokoro/manifest.json") {
        try expectEqual(paths.manifestURL.path, "/Volumes/SSD1/voice-models/kokoro/manifest.json")
    }

    s.test("voiceFileURL builds <root>/kokoro/voices/<id>.pt") {
        try expectEqual(
            paths.voiceFileURL(id: "af_bella").path,
            "/Volumes/SSD1/voice-models/kokoro/voices/af_bella.pt"
        )
    }

    s.test("kokoroDirURL is <root>/kokoro") {
        try expectEqual(paths.kokoroDirURL.path, "/Volumes/SSD1/voice-models/kokoro")
    }

    s.test("trailing slashes in root don't double up in derived paths") {
        let trailingRoot = URL(fileURLWithPath: "/Volumes/SSD1/voice-models/")
        let p = KokoroStoragePaths(root: trailingRoot)
        try expect(!p.modelURL.path.contains("//"), "double slash leaked: \(p.modelURL.path)")
        try expectEqual(p.modelURL.lastPathComponent, "model.onnx")
    }

    return s
}
