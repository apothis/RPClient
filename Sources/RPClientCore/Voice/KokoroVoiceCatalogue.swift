import Foundation

/// Static metadata describing every voice the upstream Kokoro v1.0 release
/// ships. Lives in `RPClientCore` (not `RPClientVoice`) so it's testable
/// without dragging the ONNX Runtime into the test target — pure data, no
/// engine dependency. Phase 6 §7.1c.
///
/// Update by source edit when a Kokoro version bump introduces new voices.
/// Source of truth: `huggingface.co/hexgrad/Kokoro-82M/voices/`.

public enum KokoroLanguage: String, Equatable, Hashable, CaseIterable, Codable {
    case americanEnglish = "en-US"
    case britishEnglish = "en-GB"
    case spanish = "es"
    case french = "fr"
    case hindi = "hi"
    case italian = "it"
    case japanese = "ja"
    case mandarin = "zh"
    case portugueseBR = "pt-BR"

    public var displayLabel: String {
        switch self {
        case .americanEnglish: return "American English"
        case .britishEnglish: return "British English"
        case .spanish: return "Spanish"
        case .french: return "French"
        case .hindi: return "Hindi"
        case .italian: return "Italian"
        case .japanese: return "Japanese"
        case .mandarin: return "Mandarin Chinese"
        case .portugueseBR: return "Brazilian Portuguese"
        }
    }
}

public enum KokoroGender: String, Equatable, Hashable, Codable {
    case female
    case male
}

public struct KokoroVoice: Equatable, Hashable, Identifiable, Codable {
    /// Stable upstream id, e.g. `af_bella`. First char encodes language,
    /// second encodes gender; the suffix is the voice name.
    public let id: String
    /// Friendly capitalised form of the suffix, e.g. `Bella`. Used in pickers.
    public let displayName: String
    public let language: KokoroLanguage
    public let gender: KokoroGender
    /// Short phrase synthesised by the Preview button in the library manager.
    /// Per-language; identical for every voice that shares a language.
    public let sampleText: String

    public var fileName: String { "\(id).pt" }

    public var downloadURL: URL {
        URL(string: "https://huggingface.co/hexgrad/Kokoro-82M/resolve/main/voices/\(fileName)")!
    }
}

public enum KokoroVoiceCatalogue {
    /// Canonical kokoro-v1.0 ONNX model. Verified upstream 2026-05-05.
    public static let modelDownloadURL = URL(
        string: "https://github.com/thewh1teagle/kokoro-onnx/releases/download/model-files-v1.0/kokoro-v1.0.onnx"
    )!
    public static let modelByteSize = 325_532_387

    /// All 54 voices report 523_425 ± a few bytes. The exact size per voice
    /// varies by tens of bytes; manifest.json captures the true byte count
    /// at download time. This constant is the floor used by progress bars.
    public static let voiceByteSizeApprox = 523_425

    public static func voice(id: String) -> KokoroVoice? {
        all.first { $0.id == id }
    }

    public static func voices(language: KokoroLanguage) -> [KokoroVoice] {
        all.filter { $0.language == language }
    }

    public static func voices(gender: KokoroGender) -> [KokoroVoice] {
        all.filter { $0.gender == gender }
    }

    /// Pangram-ish sample lines, one per language. Used by the library
    /// manager's Preview button (each voice gets its language's line).
    private static let sampleByLanguage: [KokoroLanguage: String] = [
        .americanEnglish: "The quick brown fox jumps over the lazy dog.",
        .britishEnglish: "Pack my box with five dozen liquor jugs.",
        .spanish: "El veloz murciélago hindú comía feliz cardillo y kiwi.",
        .french: "Portez ce vieux whisky au juge blond qui fume.",
        .hindi: "नमस्ते, आज मौसम बहुत अच्छा है।",
        .italian: "Ciao, oggi è una bellissima giornata di sole.",
        .japanese: "今日はとても良い天気ですね。",
        .mandarin: "今天的天气真的非常好。",
        .portugueseBR: "Olá, hoje está um dia muito bonito.",
    ]

    /// The 54 Kokoro v1.0 voices, sorted by id for stable iteration.
    public static let all: [KokoroVoice] = [
        // American English — female (11)
        Self.make(id: "af_alloy", language: .americanEnglish, gender: .female),
        Self.make(id: "af_aoede", language: .americanEnglish, gender: .female),
        Self.make(id: "af_bella", language: .americanEnglish, gender: .female),
        Self.make(id: "af_heart", language: .americanEnglish, gender: .female),
        Self.make(id: "af_jessica", language: .americanEnglish, gender: .female),
        Self.make(id: "af_kore", language: .americanEnglish, gender: .female),
        Self.make(id: "af_nicole", language: .americanEnglish, gender: .female),
        Self.make(id: "af_nova", language: .americanEnglish, gender: .female),
        Self.make(id: "af_river", language: .americanEnglish, gender: .female),
        Self.make(id: "af_sarah", language: .americanEnglish, gender: .female),
        Self.make(id: "af_sky", language: .americanEnglish, gender: .female),
        // American English — male (9)
        Self.make(id: "am_adam", language: .americanEnglish, gender: .male),
        Self.make(id: "am_echo", language: .americanEnglish, gender: .male),
        Self.make(id: "am_eric", language: .americanEnglish, gender: .male),
        Self.make(id: "am_fenrir", language: .americanEnglish, gender: .male),
        Self.make(id: "am_liam", language: .americanEnglish, gender: .male),
        Self.make(id: "am_michael", language: .americanEnglish, gender: .male),
        Self.make(id: "am_onyx", language: .americanEnglish, gender: .male),
        Self.make(id: "am_puck", language: .americanEnglish, gender: .male),
        Self.make(id: "am_santa", language: .americanEnglish, gender: .male),
        // British English — female (4) + male (4)
        Self.make(id: "bf_alice", language: .britishEnglish, gender: .female),
        Self.make(id: "bf_emma", language: .britishEnglish, gender: .female),
        Self.make(id: "bf_isabella", language: .britishEnglish, gender: .female),
        Self.make(id: "bf_lily", language: .britishEnglish, gender: .female),
        Self.make(id: "bm_daniel", language: .britishEnglish, gender: .male),
        Self.make(id: "bm_fable", language: .britishEnglish, gender: .male),
        Self.make(id: "bm_george", language: .britishEnglish, gender: .male),
        Self.make(id: "bm_lewis", language: .britishEnglish, gender: .male),
        // Spanish (1F + 2M)
        Self.make(id: "ef_dora", language: .spanish, gender: .female),
        Self.make(id: "em_alex", language: .spanish, gender: .male),
        Self.make(id: "em_santa", language: .spanish, gender: .male),
        // French (1F)
        Self.make(id: "ff_siwis", language: .french, gender: .female),
        // Hindi (2F + 2M)
        Self.make(id: "hf_alpha", language: .hindi, gender: .female),
        Self.make(id: "hf_beta", language: .hindi, gender: .female),
        Self.make(id: "hm_omega", language: .hindi, gender: .male),
        Self.make(id: "hm_psi", language: .hindi, gender: .male),
        // Italian (1F + 1M)
        Self.make(id: "if_sara", language: .italian, gender: .female),
        Self.make(id: "im_nicola", language: .italian, gender: .male),
        // Japanese (4F + 1M)
        Self.make(id: "jf_alpha", language: .japanese, gender: .female),
        Self.make(id: "jf_gongitsune", language: .japanese, gender: .female),
        Self.make(id: "jf_nezumi", language: .japanese, gender: .female),
        Self.make(id: "jf_tebukuro", language: .japanese, gender: .female),
        Self.make(id: "jm_kumo", language: .japanese, gender: .male),
        // Brazilian Portuguese (1F + 2M)
        Self.make(id: "pf_dora", language: .portugueseBR, gender: .female),
        Self.make(id: "pm_alex", language: .portugueseBR, gender: .male),
        Self.make(id: "pm_santa", language: .portugueseBR, gender: .male),
        // Mandarin Chinese (4F + 4M)
        Self.make(id: "zf_xiaobei", language: .mandarin, gender: .female),
        Self.make(id: "zf_xiaoni", language: .mandarin, gender: .female),
        Self.make(id: "zf_xiaoxiao", language: .mandarin, gender: .female),
        Self.make(id: "zf_xiaoyi", language: .mandarin, gender: .female),
        Self.make(id: "zm_yunjian", language: .mandarin, gender: .male),
        Self.make(id: "zm_yunxi", language: .mandarin, gender: .male),
        Self.make(id: "zm_yunxia", language: .mandarin, gender: .male),
        Self.make(id: "zm_yunyang", language: .mandarin, gender: .male),
    ]

    /// Capitalises the suffix of an id (`af_bella` → `Bella`,
    /// `jf_gongitsune` → `Gongitsune`). Names with mixed casing in upstream
    /// (none today) would need a per-id override map.
    private static func make(id: String, language: KokoroLanguage, gender: KokoroGender) -> KokoroVoice {
        let suffix = id.split(separator: "_", maxSplits: 1).last.map(String.init) ?? id
        let displayName = suffix.prefix(1).uppercased() + suffix.dropFirst()
        return KokoroVoice(
            id: id,
            displayName: displayName,
            language: language,
            gender: gender,
            sampleText: sampleByLanguage[language] ?? ""
        )
    }
}
