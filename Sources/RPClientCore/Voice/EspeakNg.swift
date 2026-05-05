import Foundation

/// Detection helper for the `espeak-ng` binary that Kokoro G2P depends on
/// (Phase 6 §7.1k-prep). RPClient ships a Swift adapter that pipes
/// text → espeak-ng → phonemes; the binary itself is not vendored to keep
/// GPL-3 out of our build, so the user installs it via Homebrew.
///
/// The voice library window surfaces a persistent status row driven by
/// `find()`: ✓ found at <path> when present, install instructions + a
/// Copy + Re-check pair when absent.
public enum EspeakNg {

    /// Probe order: Apple Silicon Homebrew first, then Intel Homebrew.
    /// Anything else is reachable via `which espeak-ng`, so a non-default
    /// install location still resolves cleanly.
    public static let standardPaths: [String] = [
        "/opt/homebrew/bin/espeak-ng",
        "/usr/local/bin/espeak-ng",
    ]

    /// Pure resolver. Tests inject `fileExists` and `whichLookup`; the live
    /// `find()` wires real implementations.
    static func resolve(
        candidates: [String],
        fileExists: (String) -> Bool,
        whichLookup: () -> String?
    ) -> URL? {
        for path in candidates where fileExists(path) {
            return URL(fileURLWithPath: path)
        }
        if let raw = whichLookup() {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return URL(fileURLWithPath: trimmed)
            }
        }
        return nil
    }

    /// Live detection. Probes the standard paths via `FileManager`, then
    /// falls back to `which espeak-ng`. Returns `nil` when not installed.
    public static func find() -> URL? {
        return resolve(
            candidates: standardPaths,
            fileExists: { FileManager.default.fileExists(atPath: $0) },
            whichLookup: { runWhich() }
        )
    }

    /// Shell-out to `/usr/bin/which espeak-ng`. Returns the trimmed stdout
    /// path on exit code 0, or nil otherwise (including failed launch).
    private static func runWhich() -> String? {
        let process = Process()
        process.launchPath = "/usr/bin/which"
        process.arguments = ["espeak-ng"]
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = Pipe()  // discard stderr
        do {
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            let data = stdout.fileHandleForReading.readDataToEndOfFile()
            return String(decoding: data, as: UTF8.self)
        } catch {
            return nil
        }
    }
}
