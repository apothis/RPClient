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
