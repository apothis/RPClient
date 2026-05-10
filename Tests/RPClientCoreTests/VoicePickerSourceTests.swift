import Foundation
@testable import RPClientCore

/// Phase 6 §7.5a: pure picker source for the entity Voice section.
///
/// Builds a deterministic, sectioned list of selectable voices from
/// (a) `KokoroVoiceCatalogue.all ∩ installedVoiceIds` and
/// (b) the AVKit system voices passed in. The popup that consumes this
/// list also surfaces a "(use chat default)" entry at index 0 — that's
/// not modelled here; it's a nil sentinel handled at the AppKit layer.
func voicePickerSourceTests() -> TestSuite {
    let s = TestSuite("VoicePickerSource")

    let avAva = VoicePickerSource.AVKitVoice(
        identifier: "com.apple.voice.premium.en-US.Ava",
        displayName: "Ava",
        language: "en-US"
    )
    let avSamantha = VoicePickerSource.AVKitVoice(
        identifier: "com.apple.voice.compact.en-US.Samantha",
        displayName: "Samantha",
        language: "en-US"
    )
    let avDaniel = VoicePickerSource.AVKitVoice(
        identifier: "com.apple.voice.compact.en-GB.Daniel",
        displayName: "Daniel",
        language: "en-GB"
    )

    s.test("empty inputs return an empty option list") {
        let opts = VoicePickerSource.options(installedKokoroIds: [], avkitVoices: [])
        try expectTrue(opts.isEmpty, "expected empty, got \(opts)")
    }

    s.test("Kokoro voices are filtered to the installed set") {
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["af_bella", "af_alloy"],
            avkitVoices: []
        )
        try expectEqual(opts.count, 2)
        try expectTrue(opts.allSatisfy { $0.identifier.engine == .kokoro })
        let ids = Set(opts.map(\.identifier.voiceId))
        try expectEqual(ids, Set(["af_bella", "af_alloy"]))
    }

    s.test("installed ids unknown to the catalogue are silently dropped") {
        // A user could carry an installed manifest entry for a voice that the
        // statically-bundled catalogue doesn't list (catalogue out of date,
        // hand-edited manifest, etc.). Drop those rather than crash.
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["af_bella", "ghost_voice_not_in_catalogue"],
            avkitVoices: []
        )
        try expectEqual(opts.count, 1)
        try expectEqual(opts.first?.identifier.voiceId, "af_bella")
    }

    s.test("AVKit voices appear after Kokoro voices") {
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["af_bella"],
            avkitVoices: [avAva]
        )
        try expectEqual(opts.count, 2)
        try expectEqual(opts[0].identifier.engine, .kokoro)
        try expectEqual(opts[1].identifier.engine, .avkit)
    }

    s.test("Kokoro voices group sorted by language label, then display name") {
        // af_bella = American English, bf_isabella = British English — alphabetic
        // by language label puts "American" before "British".
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["bf_isabella", "af_bella", "af_alloy"],
            avkitVoices: []
        )
        let ordered = opts.map(\.identifier.voiceId)
        try expectEqual(ordered, ["af_alloy", "af_bella", "bf_isabella"])
    }

    s.test("AVKit voices group sorted by language, then display name") {
        // en-GB Daniel before en-US Ava/Samantha (by language code); within en-US,
        // Ava before Samantha alphabetically.
        let opts = VoicePickerSource.options(
            installedKokoroIds: [],
            avkitVoices: [avSamantha, avAva, avDaniel]
        )
        let ordered = opts.map(\.identifier.voiceId)
        try expectEqual(ordered, [
            "com.apple.voice.compact.en-GB.Daniel",
            "com.apple.voice.premium.en-US.Ava",
            "com.apple.voice.compact.en-US.Samantha",
        ])
    }

    s.test("groupLabel reflects the engine") {
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["af_bella"],
            avkitVoices: [avAva]
        )
        try expectEqual(opts[0].groupLabel, "Kokoro")
        try expectEqual(opts[1].groupLabel, "System (AVKit)")
    }

    s.test("displayName carries enough to disambiguate") {
        // Picker renders one flat list — the display string must include
        // language so two voices with the same name (rare but possible
        // across engines) don't appear identical.
        let opts = VoicePickerSource.options(
            installedKokoroIds: ["af_bella"],
            avkitVoices: [avAva]
        )
        let kokoro = try expectNotNil(opts.first { $0.identifier.engine == .kokoro })
        try expectTrue(kokoro.displayName.contains("Bella"))
        try expectTrue(kokoro.displayName.contains("American English"))
        let avkit = try expectNotNil(opts.first { $0.identifier.engine == .avkit })
        try expectTrue(avkit.displayName.contains("Ava"))
        try expectTrue(avkit.displayName.contains("en-US"))
    }

    s.test("output is deterministic for the same input") {
        let a = VoicePickerSource.options(
            installedKokoroIds: ["af_bella", "bf_isabella"],
            avkitVoices: [avAva, avDaniel]
        )
        let b = VoicePickerSource.options(
            installedKokoroIds: ["bf_isabella", "af_bella"],   // reverse order
            avkitVoices: [avDaniel, avAva]                     // reverse order
        )
        try expectEqual(a, b)
    }

    return s
}
