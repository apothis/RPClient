import Foundation

/// Loader for the per-voice tensor archives shipped under
/// `huggingface.co/hexgrad/Kokoro-82M/voices/<id>.pt` (Phase 6 §7.1k1).
///
/// Each `.pt` is a PyTorch v3 save format archive — a ZIP with the
/// following entries (verified against `af_alloy.pt` 2026-05-05):
///
/// ```
/// <voice>/data.pkl                  (~165 bytes, pickle metadata)
/// <voice>/byteorder                 (6 bytes, "little\n")
/// <voice>/data/0                    (522240 bytes, raw float32 tensor)
/// <voice>/version                   (2 bytes, "3\n")
/// <voice>/.data/serialization_id    (40 bytes)
/// ```
///
/// We deliberately skip pickle parsing — every Kokoro voice has the same
/// known shape (510 × 1 × 256 floats, little-endian), so reading
/// `data/0` and reinterpreting as `[Float]` is sufficient. We validate
/// length and trust the byte order matches the expected `little`
/// declaration. If a future voice ships in a different shape this loader
/// throws `unexpectedTensorSize` and we'd need to fall back to actual
/// pickle parsing.
public enum KokoroVoiceFile {
    /// 510 frames × 1 batch × 256 embedding-dim, all Float32.
    public static let expectedFloatCount = 510 * 1 * 256
    public static let expectedTensorBytes = expectedFloatCount * MemoryLayout<Float>.size

    public enum Error: Swift.Error, Equatable {
        case missingTensorEntry
        case unexpectedTensorSize(actual: Int, expected: Int)
    }

    public static func loadStyleEmbedding(from url: URL) throws -> [Float] {
        let archive = try Data(contentsOf: url, options: .mappedIfSafe)
        let reader = try MinimalZipReader(data: archive)
        let entry = reader.entries.first { $0.name.hasSuffix("/data/0") }
        guard let entry = entry else {
            throw Error.missingTensorEntry
        }
        let tensorBytes = try reader.read(entry)
        guard tensorBytes.count == expectedTensorBytes else {
            throw Error.unexpectedTensorSize(
                actual: tensorBytes.count,
                expected: expectedTensorBytes
            )
        }
        return tensorBytes.withUnsafeBytes { raw in
            let buffer = raw.bindMemory(to: Float.self)
            return Array(buffer)
        }
    }
}
