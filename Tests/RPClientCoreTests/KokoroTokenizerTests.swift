import Foundation
@testable import RPClientCore

/// Tests for `KokoroTokenizer` — pure mapping from IPA characters to
/// Kokoro Int64 token ids using the canonical vocab from
/// `huggingface.co/hexgrad/Kokoro-82M/config.json` (Phase 6 §7.1k2b).
func kokoroTokenizerTests() -> TestSuite {
    let s = TestSuite("KokoroTokenizer")

    // MARK: - Vocab integrity

    s.test("vocab has the canonical 114 entries") {
        try expectEqual(KokoroTokenizer.vocab.count, 114)
    }

    s.test("vocab maps known characters to their canonical ids") {
        // Spot-checks across the vocab so a subtle codepoint drift fails fast.
        try expectEqual(KokoroTokenizer.vocab[";"], 1)
        try expectEqual(KokoroTokenizer.vocab[","], 3)
        try expectEqual(KokoroTokenizer.vocab[" "], 16)
        try expectEqual(KokoroTokenizer.vocab["a"], 43)
        try expectEqual(KokoroTokenizer.vocab["l"], 54)
        try expectEqual(KokoroTokenizer.vocab["ə"], 83)        // schwa
        try expectEqual(KokoroTokenizer.vocab["ɪ"], 102)       // small cap I
        try expectEqual(KokoroTokenizer.vocab["ʊ"], 135)       // upsilon
        try expectEqual(KokoroTokenizer.vocab["ˈ"], 156)       // primary stress
        try expectEqual(KokoroTokenizer.vocab["ː"], 158)       // length mark
        try expectEqual(KokoroTokenizer.vocab["ᵻ"], 177)       // barred-i
    }

    // MARK: - Pad tokens

    s.test("tokenize('') returns just BOS + EOS pad tokens") {
        let tokens = KokoroTokenizer.tokenize(ipa: "")
        try expectEqual(tokens, [0, 0])
    }

    // MARK: - Real espeak output round-trip

    s.test("tokenize hand-traced 'Hello, world.' IPA matches expected ids") {
        // Output from `espeak-ng -q --ipa=3 -v en-us "Hello, world."` —
        // captured 2026-05-05. Newlines (U+000A) and ZWJ tie marks
        // (U+200D) are not in the vocab and must be silently dropped.
        let ipa = "həlˈo\u{200D}ʊ\nwˈɜːld"
        let tokens = KokoroTokenizer.tokenize(ipa: ipa)
        // Hand-traced: h=50 ə=83 l=54 ˈ=156 o=57 (ZWJ skip) ʊ=135
        //              (newline skip) w=65 ˈ=156 ɜ=87 ː=158 l=54 d=46
        // Wrapped with BOS=0 / EOS=0
        try expectEqual(tokens, [0, 50, 83, 54, 156, 57, 135, 65, 156, 87, 158, 54, 46, 0])
    }

    s.test("tokenize keeps space tokens between words") {
        // espeak in some modes emits a space rather than a newline between
        // words; the tokenizer must preserve it (id 16).
        let tokens = KokoroTokenizer.tokenize(ipa: "hi wˈɜːld")
        // h=50 i=51 space=16 w=65 ˈ=156 ɜ=87 ː=158 l=54 d=46
        try expectEqual(tokens, [0, 50, 51, 16, 65, 156, 87, 158, 54, 46, 0])
    }

    // MARK: - Unknown character handling

    s.test("characters not in vocab are silently dropped") {
        // 'X' (uppercase) is not in the vocab. 'h' (50) and 'i' (51) are.
        let tokens = KokoroTokenizer.tokenize(ipa: "Xhi")
        try expectEqual(tokens, [0, 50, 51, 0])
    }

    s.test("ZWJ tie marks between diphthong components are dropped") {
        // espeak's diphthongs come through as 'o‍ʊ', 'e‍ɪ' etc. — joiner U+200D.
        let tokens = KokoroTokenizer.tokenize(ipa: "o\u{200D}ʊ")
        try expectEqual(tokens, [0, 57, 135, 0])
    }

    s.test("newlines from clause boundaries are dropped") {
        let tokens = KokoroTokenizer.tokenize(ipa: "hi\nlo")
        // h=50 i=51 (newline skip) l=54 o=57
        try expectEqual(tokens, [0, 50, 51, 54, 57, 0])
    }

    // MARK: - Real-input integration with EspeakNgClient

    s.test("end-to-end espeak → tokenize produces sane id sequence") {
        guard let client = EspeakNgClient.resolved() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let ipa = try client.phonemize(text: "Hello, world.",
                                       language: .americanEnglish)
        let tokens = KokoroTokenizer.tokenize(ipa: ipa)
        try expect(tokens.first == 0, "expected leading BOS pad")
        try expect(tokens.last == 0, "expected trailing EOS pad")
        try expect(tokens.count > 5, "expected non-trivial token count, got \(tokens.count)")
        // Every interior token must be in the vocab range.
        for t in tokens.dropFirst().dropLast() {
            try expect(t >= 1 && t <= 177, "token \(t) out of vocab range")
        }
    }

    return s
}
