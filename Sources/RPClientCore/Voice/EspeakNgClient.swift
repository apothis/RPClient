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

    /// Set of input characters that `phonemizePreservingPunctuation` treats
    /// as clause-breaking punctuation: input is split on these, IPA is
    /// produced per segment, and the punctuation chars are stitched back
    /// in between IPA segments. These are exactly the characters Kokoro's
    /// vocab has tokens for and the model uses for prosody / pause cues.
    public static let preservedPunctuation: Set<Swift.Character> = [
        ",", ";", ":", ".", "!", "?", "—", "…",
    ]

    /// Phonemize `text`, preserving clause-breaking punctuation in the
    /// output. Phase 6 §7.1k7.
    ///
    /// `espeak-ng -q --ipa=3` strips ALL punctuation from its phoneme
    /// output (commas, periods, etc. become silent newlines and our
    /// tokenizer drops them). Without this method, every assistant reply
    /// runs together as a robotic monotone — the Kokoro model has no
    /// pause/intonation cues to work with.
    ///
    /// Implementation: split the input on `preservedPunctuation`, call
    /// `phonemize(text:language:)` on each non-empty segment, and stitch
    /// the IPA back together with the original punctuation chars between
    /// segments (one space after each cluster of segment-IPA so the next
    /// segment doesn't run into the previous punct). This costs one
    /// espeak subprocess invocation per segment (~30 ms on macOS) — for
    /// typical assistant replies that's 5–10 calls and totals 150–300 ms,
    /// acceptable.
    ///
    /// Upstream `kokoro-onnx` Python uses `phonemizer.phonemize(...,
    /// preserve_punctuation=True)` which links the espeak shared library
    /// and preserves punctuation natively. The CLI has no equivalent flag,
    /// so we orchestrate ourselves.
    public func phonemizePreservingPunctuation(
        text: String,
        language: KokoroLanguage
    ) throws -> String {
        let punctuation = Self.preservedPunctuation

        // Walk text once, accumulating non-punct segments and punctuation
        // characters in their original order.
        var segments: [String] = []
        var puncts: [Swift.Character] = []
        var current = ""
        for ch in text {
            if punctuation.contains(ch) {
                segments.append(current)
                puncts.append(ch)
                current = ""
            } else {
                current.append(ch)
            }
        }
        segments.append(current)

        // Phonemize each non-empty segment and stitch with the original
        // punctuation. Insert a single space before a new IPA run when
        // the previous output didn't already end with whitespace, so
        // "...word, word..." becomes "...IPA, IPA..." not "...IPA,IPA...".
        var result = ""
        for (i, seg) in segments.enumerated() {
            let trimmed = seg.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty {
                if !result.isEmpty, !result.hasSuffix(" ") {
                    result.append(" ")
                }
                let ipa = try phonemize(text: trimmed, language: language)
                result.append(ipa)
            }
            if i < puncts.count {
                // Kokoro's prosody for ASCII colon `:` is empirically flat
                // — the model produces no audible pause. Map `:` → `.` so
                // a user-typed colon produces a sentence-end pause; the
                // user prefers a fuller pause for colons (comma was tested
                // and felt too short).
                let pun: Swift.Character = puncts[i] == ":" ? "." : puncts[i]
                result.append(pun)
            }
        }
        return result
    }
}
