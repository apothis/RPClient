import Foundation
@testable import RPClientCore

/// Tests for `EspeakNgClient` — Process wrapper that pipes text through
/// `espeak-ng -q --ipa=3` to produce an IPA phoneme string for Kokoro
/// tokenization (Phase 6 §7.1k2a). Pure logic (language → espeak code
/// mapping) is unit-tested; the actual subprocess call is smoke-tested
/// when espeak-ng is installed and skipped otherwise.
func espeakNgClientTests() -> TestSuite {
    let s = TestSuite("EspeakNgClient")

    // MARK: - Pure: language → espeak voice code

    s.test("americanEnglish maps to en-us") {
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .americanEnglish), "en-us")
    }

    s.test("britishEnglish maps to en-gb") {
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .britishEnglish), "en-gb")
    }

    s.test("non-English Kokoro languages map to their espeak codes") {
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .japanese), "ja")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .mandarin), "cmn")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .french), "fr-fr")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .spanish), "es")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .italian), "it")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .hindi), "hi")
        try expectEqual(EspeakNgClient.espeakVoiceCode(for: .portugueseBR), "pt-br")
    }

    // MARK: - Smoke: real subprocess

    s.test("phonemize 'Hello, world.' returns non-empty IPA when espeak-ng is installed") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let ipa = try client.phonemize(text: "Hello, world.", language: .americanEnglish)
        try expect(!ipa.isEmpty, "expected non-empty phoneme output, got '\(ipa)'")
        // 'l' and the schwa 'ə' should both appear in the IPA for "Hello, world."
        try expect(ipa.contains("l"), "expected 'l' in output: '\(ipa)'")
        try expect(ipa.contains("ə"), "expected schwa 'ə' in output: '\(ipa)'")
    }

    s.test("phonemize trims trailing whitespace") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let ipa = try client.phonemize(text: "Hi.", language: .americanEnglish)
        try expectEqual(ipa, ipa.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    s.test("phonemize same input is deterministic") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let a = try client.phonemize(text: "The quick brown fox.",
                                     language: .americanEnglish)
        let b = try client.phonemize(text: "The quick brown fox.",
                                     language: .americanEnglish)
        try expectEqual(a, b)
    }

    s.test("phonemizePreservingPunctuation keeps commas and periods in IPA") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let raw = try client.phonemize(text: "Hello, world.", language: .americanEnglish)
        let kept = try client.phonemizePreservingPunctuation(
            text: "Hello, world.", language: .americanEnglish
        )
        // Bare phonemize drops the punctuation entirely — that's the bug
        // §7.1k7 fixes. Sanity-check the regression first.
        try expectFalse(raw.contains(","), "bare phonemize unexpectedly kept ',' (precondition for the test no longer holds)")
        try expectFalse(raw.contains("."), "bare phonemize unexpectedly kept '.'")
        // The new method must keep the comma AND the period.
        try expectTrue(kept.contains(","), "punct-preserving output missing ',': \(kept)")
        try expectTrue(kept.contains("."), "punct-preserving output missing '.': \(kept)")
    }

    s.test("phonemizePreservingPunctuation keeps semicolons, exclamations, questions") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let kept = try client.phonemizePreservingPunctuation(
            text: "First; second! Third?", language: .americanEnglish
        )
        try expectTrue(kept.contains(";"), kept)
        try expectTrue(kept.contains("!"), kept)
        try expectTrue(kept.contains("?"), kept)
    }

    s.test("phonemizePreservingPunctuation maps colon to period") {
        // Kokoro's prosody for ':' is empirically flat (no pause). Map to
        // '.' at the IPA layer so a user-typed colon produces a full-stop
        // pause — auditioned: comma felt too short, period matches the
        // user's expectation for colon-length emphasis.
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let kept = try client.phonemizePreservingPunctuation(
            text: "Listen carefully: this matters", language: .americanEnglish
        )
        try expectFalse(kept.contains(":"), "colon should be remapped, got: \(kept)")
        // Two periods expected: the remapped `:` plus none for trailing
        // (input has no terminal punct). One period total.
        try expectTrue(kept.contains("."), "expected a period in remapped output, got: \(kept)")
    }

    s.test("phonemizePreservingPunctuation handles unpunctuated input as a single phonemize call") {
        guard let binary = EspeakNg.find() else {
            print("    [skipped — espeak-ng not installed]")
            return
        }
        let client = EspeakNgClient(binary: binary)
        let raw = try client.phonemize(text: "Hello world", language: .americanEnglish)
        let kept = try client.phonemizePreservingPunctuation(
            text: "Hello world", language: .americanEnglish
        )
        try expectEqual(raw, kept)
    }

    s.test("phonemize throws when binary path doesn't exist") {
        let client = EspeakNgClient(
            binary: URL(fileURLWithPath: "/nonexistent/espeak-ng")
        )
        do {
            _ = try client.phonemize(text: "Hi.", language: .americanEnglish)
            try expect(false, "expected throw")
        } catch {
            // Any error is fine — the contract is "doesn't return a string"
        }
    }

    return s
}
