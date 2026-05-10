import CryptoKit
import Foundation

/// SHA-256 helpers used by the Kokoro download manager (Phase 6 §7.1j1) to
/// stamp downloaded asset files with a checksum recorded in `manifest.json`.
/// Kept Core-side so the hashing logic is unit-testable and can be reused
/// later if we ever want to verify on-disk integrity at launch.
public enum Sha256 {
    /// Hex-encoded SHA-256 of `data`. Used by tests and by small in-memory
    /// payloads; large files should prefer `hex(ofFileAt:)` to avoid loading
    /// the whole asset into RAM.
    public static func hex(of data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return Self.hexString(digest)
    }

    /// Streamed SHA-256 of the file at `url`. Reads in 256 KB chunks so a
    /// 325 MB model file hashes in ~1300 reads with bounded memory.
    public static func hex(ofFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        let chunkSize = 256 * 1024
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return Self.hexString(hasher.finalize())
    }

    private static func hexString<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
