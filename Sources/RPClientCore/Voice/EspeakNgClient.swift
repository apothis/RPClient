import Foundation

/// Subprocess wrapper that turns plain text into an IPA phoneme string by
/// invoking `espeak-ng -q --ipa=3 -v <code>` (Phase 6 §7.1k2a). The
/// returned string feeds `KokoroTokenizer` (§7.1k2b), whose token ids
/// then feed the Kokoro ONNX model (§7.1k3).
///
/// We pipe text on stdin rather than passing it as an argument so very
/// long passages and shell-special characters don't need quoting. espeak
/// reads stdin when no positional text argument is supplied.
public struct EspeakNgClient {
    public enum Error: Swift.Error, Equatable {
        case launchFailed(String)
        case nonZeroExit(code: Int32, stderr: String)
    }

    public let binary: URL

    public init(binary: URL) {
        self.binary = binary
    }

    /// Convenience: resolve the binary via `EspeakNg.find()`. Returns
    /// `nil` when espeak-ng isn't installed — caller should fall back to
    /// AVKit in that case.
    public static func resolved() -> EspeakNgClient? {
        guard let url = EspeakNg.find() else { return nil }
        return EspeakNgClient(binary: url)
    }

    /// Map a Kokoro language to the corresponding espeak-ng `-v` voice
    /// code. Pure; unit-tested. The mapping is tight because espeak's
    /// codes mostly match the Kokoro `KokoroLanguage.rawValue`s (lower-
    /// cased), with two exceptions: French wants `fr-fr`, Mandarin wants
    /// `cmn`.
    public static func espeakVoiceCode(for language: KokoroLanguage) -> String {
        switch language {
        case .americanEnglish: return "en-us"
        case .britishEnglish:  return "en-gb"
        case .spanish:         return "es"
        case .french:          return "fr-fr"
        case .hindi:           return "hi"
        case .italian:         return "it"
        case .japanese:        return "ja"
        case .mandarin:        return "cmn"
        case .portugueseBR:    return "pt-br"
        }
    }

    /// Run espeak-ng on `text` and return the IPA phoneme string. Newlines
    /// in espeak's output (one per clause boundary) are preserved; the
    /// tokenizer treats them as pause tokens.
    public func phonemize(text: String, language: KokoroLanguage) throws -> String {
        let process = Process()
        process.executableURL = binary
        process.arguments = [
            "-q",                      // suppress audio (we want phonemes only)
            "--ipa=3",                 // IPA with stress + tie marks
            "-v", Self.espeakVoiceCode(for: language),
        ]

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        do {
            try process.run()
        } catch {
            throw Error.launchFailed(error.localizedDescription)
        }
        // Write text on stdin and close so espeak-ng knows EOF.
        if let payload = text.data(using: .utf8) {
            try? stdin.fileHandleForWriting.write(contentsOf: payload)
        }
        try? stdin.fileHandleForWriting.close()

        let outData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errData = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errMsg = String(decoding: errData, as: UTF8.self)
            throw Error.nonZeroExit(code: process.terminationStatus, stderr: errMsg)
        }
        let raw = String(decoding: outData, as: UTF8.self)
        return raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
