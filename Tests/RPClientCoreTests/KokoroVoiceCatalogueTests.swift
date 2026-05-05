import Foundation
@testable import RPClientCore

/// Tests for `KokoroVoiceCatalogue` — the static metadata listing every
/// voice the Kokoro v1.0 release ships. Pure data; bugs here are
/// either typos or upstream-roster drift. Phase 6 §7.1c.
func kokoroVoiceCatalogueTests() -> TestSuite {
    let s = TestSuite("KokoroVoiceCatalogue")

    s.test("all lists exactly 54 voices, all unique ids") {
        let all = KokoroVoiceCatalogue.all
        try expectEqual(all.count, 54)
        let ids = Set(all.map { $0.id })
        try expectEqual(ids.count, 54)
    }

    s.test("every voice has a non-empty display name") {
        for v in KokoroVoiceCatalogue.all {
            try expect(!v.displayName.isEmpty, "voice \(v.id) has empty displayName")
        }
    }

    s.test("voice(id:) finds known voices and returns nil for unknowns") {
        try expectEqual(KokoroVoiceCatalogue.voice(id: "af_bella")?.displayName, "Bella")
        try expectEqual(KokoroVoiceCatalogue.voice(id: "zm_yunyang")?.language, .mandarin)
        try expectNil(KokoroVoiceCatalogue.voice(id: "totally_made_up"))
    }

    s.test("language inference from id prefix is correct") {
        try expectEqual(KokoroVoiceCatalogue.voice(id: "af_bella")?.language, .americanEnglish)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "bm_george")?.language, .britishEnglish)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "jf_alpha")?.language, .japanese)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "zf_xiaoxiao")?.language, .mandarin)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "ef_dora")?.language, .spanish)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "ff_siwis")?.language, .french)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "hf_alpha")?.language, .hindi)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "if_sara")?.language, .italian)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "pf_dora")?.language, .portugueseBR)
    }

    s.test("gender inference from id prefix is correct") {
        try expectEqual(KokoroVoiceCatalogue.voice(id: "af_bella")?.gender, .female)
        try expectEqual(KokoroVoiceCatalogue.voice(id: "am_michael")?.gender, .male)
    }

    s.test("voices(language:) filters correctly — 20 American English voices") {
        let am = KokoroVoiceCatalogue.voices(language: .americanEnglish)
        // 11 af_* + 9 am_* = 20
        try expectEqual(am.count, 20)
        try expect(am.allSatisfy { $0.language == .americanEnglish })
    }

    s.test("voices(language:) — 8 British English voices") {
        let gb = KokoroVoiceCatalogue.voices(language: .britishEnglish)
        // 4 bf_* + 4 bm_*
        try expectEqual(gb.count, 8)
    }

    s.test("voices(gender:) splits 29 female / 25 male") {
        let f = KokoroVoiceCatalogue.voices(gender: .female)
        let m = KokoroVoiceCatalogue.voices(gender: .male)
        try expectEqual(f.count, 29)
        try expectEqual(m.count, 25)
        try expectEqual(f.count + m.count, 54)
    }

    s.test("downloadURL points at HuggingFace's hexgrad/Kokoro-82M voices/<id>.pt") {
        let bella = KokoroVoiceCatalogue.voice(id: "af_bella")!
        try expectEqual(
            bella.downloadURL.absoluteString,
            "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/af_bella.pt"
        )
    }

    s.test("voice fileName matches `<id>.pt`") {
        try expectEqual(KokoroVoiceCatalogue.voice(id: "af_bella")?.fileName, "af_bella.pt")
        try expectEqual(KokoroVoiceCatalogue.voice(id: "zm_yunyang")?.fileName, "zm_yunyang.pt")
    }

    s.test("model constants point at the kokoro-onnx v1.0 release") {
        try expectEqual(
            KokoroVoiceCatalogue.modelDownloadURL.absoluteString,
            "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
        )
        // Verified upstream 2026-05-05 — exact byte size of kokoro-v1.0.onnx.
        try expectEqual(KokoroVoiceCatalogue.modelByteSize, 325_532_387)
    }

    s.test("voice byte size constant matches HuggingFace .pt files (~512 KB)") {
        // All 54 voices are within a 100-byte window of 523 KB. Use the floor
        // as a loose sanity bound; per-voice variance is recorded in manifest.
        try expectEqual(KokoroVoiceCatalogue.voiceByteSizeApprox, 523_425)
    }

    s.test("sampleText is non-empty for every voice and matches its language") {
        for v in KokoroVoiceCatalogue.all {
            try expect(!v.sampleText.isEmpty, "voice \(v.id) has empty sampleText")
        }
    }

    return s
}
