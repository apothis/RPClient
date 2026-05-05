import Foundation

/// Maps an IPA phoneme string from `EspeakNgClient` to the integer token
/// ids that Kokoro's ONNX model consumes (Phase 6 §7.1k2b). The vocab is
/// the canonical mapping from Kokoro's published `config.json` — getting
/// it wrong by even one codepoint produces gibberish at inference time.
///
/// Source: `huggingface.co/hexgrad/Kokoro-82M/config.json`, fetched
/// 2026-05-05. 114 entries; ids range 1..177 with intentional gaps for
/// tokens reserved upstream but not currently used. Pad token (BOS / EOS
/// padding) is id 0; never appears in the vocab itself.
///
/// Tokenisation rule: iterate Unicode characters, look each up in the
/// vocab, drop any character not present (this correctly filters
/// espeak's U+200D ZWJ tie marks between diphthong components and the
/// U+000A clause-break newlines). Wrap with leading and trailing 0s.
public enum KokoroTokenizer {
    public static let padTokenId: Int64 = 0

    public static let vocab: [String: Int64] = [
        ";": 1,    // U+003B
        ":": 2,    // U+003A
        ",": 3,    // U+002C
        ".": 4,    // U+002E
        "!": 5,    // U+0021
        "?": 6,    // U+003F
        "—": 9,    // U+2014  EM DASH
        "…": 10,   // U+2026  HORIZONTAL ELLIPSIS
        "\"": 11,  // U+0022
        "(": 12,   // U+0028
        ")": 13,   // U+0029
        "\u{201C}": 14,  // LEFT DOUBLE QUOTATION MARK
        "\u{201D}": 15,  // RIGHT DOUBLE QUOTATION MARK
        " ": 16,   // U+0020
        "\u{0303}": 17,  // COMBINING TILDE
        "ʣ": 18, "ʥ": 19, "ʦ": 20, "ʨ": 21, "ᵝ": 22, "ꭧ": 23,
        "A": 24, "I": 25,
        "O": 31, "Q": 33, "S": 35, "T": 36, "W": 39, "Y": 41,
        "ᵊ": 42,
        "a": 43, "b": 44, "c": 45, "d": 46, "e": 47, "f": 48,
        "h": 50, "i": 51, "j": 52, "k": 53, "l": 54, "m": 55,
        "n": 56, "o": 57, "p": 58, "q": 59, "r": 60, "s": 61,
        "t": 62, "u": 63, "v": 64, "w": 65, "x": 66, "y": 67,
        "z": 68,
        "ɑ": 69, "ɐ": 70, "ɒ": 71, "æ": 72,
        "β": 75, "ɔ": 76, "ɕ": 77, "ç": 78,
        "ɖ": 80, "ð": 81, "ʤ": 82, "ə": 83,
        "ɚ": 85, "ɛ": 86, "ɜ": 87,
        "ɟ": 90, "ɡ": 92,
        "ɥ": 99, "ɨ": 101, "ɪ": 102, "ʝ": 103,
        "ɯ": 110, "ɰ": 111, "ŋ": 112, "ɳ": 113, "ɲ": 114, "ɴ": 115,
        "ø": 116, "ɸ": 118, "θ": 119, "œ": 120,
        "ɹ": 123, "ɾ": 125, "ɻ": 126,
        "ʁ": 128, "ɽ": 129, "ʂ": 130, "ʃ": 131, "ʈ": 132, "ʧ": 133,
        "ʊ": 135, "ʋ": 136, "ʌ": 138,
        "ɣ": 139, "ɤ": 140,
        "χ": 142, "ʎ": 143,
        "ʒ": 147, "ʔ": 148,
        "ˈ": 156, "ˌ": 157, "ː": 158,
        "ʰ": 162, "ʲ": 164,
        "↓": 169, "→": 171, "↗": 172, "↘": 173,
        "ᵻ": 177,
    ]

    /// Convert an IPA phoneme string to the int64 token sequence Kokoro's
    /// model expects, padded with `padTokenId` at both ends.
    ///
    /// Iterates Unicode scalars (not extended-grapheme `Character`s) so
    /// espeak's ZWJ tie marks (e.g. `o‍ʊ`, `e‍ɪ`) decompose into their
    /// component scalars, each of which is looked up independently — the
    /// vocab has `o` and `ʊ` separately but no entry for the joined
    /// cluster. Input is NFD-normalised first so composed characters like
    /// `ã` (U+00E3) decompose into `a` + combining tilde (both vocab
    /// entries) rather than miss the lookup as a single composed scalar.
    public static func tokenize(ipa: String) -> [Int64] {
        var out: [Int64] = [padTokenId]
        let normalized = ipa.decomposedStringWithCanonicalMapping
        for scalar in normalized.unicodeScalars {
            if let id = vocab[String(scalar)] {
                out.append(id)
            }
        }
        out.append(padTokenId)
        return out
    }
}
