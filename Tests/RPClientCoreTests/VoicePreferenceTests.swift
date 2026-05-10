import Foundation
@testable import RPClientCore

/// Tests for `VoicePreference` — the per-entity voice settings struct
/// (`voiceIdentifier` + `rate` + `pitch`). Phase 6 §7.2a. Pure logic.
///
/// Migration semantics: missing nested `rate`/`pitch` decode to 1.0 (neutral
/// multiplier shared by both Kokoro and AVKit). Range validation lives at the
/// UI/engine boundary, not in the decoder. A malformed nested
/// `voiceIdentifier` throws — the preference is unusable without it.
func voicePreferenceTests() -> TestSuite {
    let s = TestSuite("VoicePreference")

    s.test("encodes all three fields with the identifier as a single string") {
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.25,
            pitch: 0.9
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(pref)
        let json = String(data: data, encoding: .utf8)
        try expectEqual(json, #"{"pitch":0.9,"rate":1.25,"voiceIdentifier":"kokoro:af_alloy"}"#)
    }

    s.test("Codable round-trips") {
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.premium.en-US.Ava"),
            rate: 1.0,
            pitch: 1.0
        )
        let data = try JSONEncoder().encode(pref)
        let decoded = try JSONDecoder().decode(VoicePreference.self, from: data)
        try expectEqual(decoded, pref)
    }

    s.test("missing rate decodes to 1.0") {
        let json = #"{"voiceIdentifier":"kokoro:af_alloy","pitch":0.8}"#.data(using: .utf8)!
        let pref = try JSONDecoder().decode(VoicePreference.self, from: json)
        try expectEqual(pref.rate, 1.0)
        try expectEqual(pref.pitch, 0.8)
    }

    s.test("missing pitch decodes to 1.0") {
        let json = #"{"voiceIdentifier":"kokoro:af_alloy","rate":1.5}"#.data(using: .utf8)!
        let pref = try JSONDecoder().decode(VoicePreference.self, from: json)
        try expectEqual(pref.rate, 1.5)
        try expectEqual(pref.pitch, 1.0)
    }

    s.test("missing both rate and pitch decode to 1.0 / 1.0") {
        let json = #"{"voiceIdentifier":"avkit:com.apple.voice.compact.en-US.Samantha"}"#.data(using: .utf8)!
        let pref = try JSONDecoder().decode(VoicePreference.self, from: json)
        try expectEqual(pref.rate, 1.0)
        try expectEqual(pref.pitch, 1.0)
        try expectEqual(pref.voiceIdentifier.engine, .avkit)
    }

    s.test("malformed voiceIdentifier throws") {
        let json = #"{"voiceIdentifier":"not-a-valid-id","rate":1.0,"pitch":1.0}"#.data(using: .utf8)!
        var threw = false
        do {
            _ = try JSONDecoder().decode(VoicePreference.self, from: json)
        } catch {
            threw = true
        }
        try expectTrue(threw, "decoder should have thrown on malformed voiceIdentifier")
    }

    s.test("missing voiceIdentifier throws — the preference is unusable without it") {
        let json = #"{"rate":1.0,"pitch":1.0}"#.data(using: .utf8)!
        var threw = false
        do {
            _ = try JSONDecoder().decode(VoicePreference.self, from: json)
        } catch {
            threw = true
        }
        try expectTrue(threw, "decoder should have thrown on missing voiceIdentifier")
    }

    s.test("Equatable is structural") {
        let a = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.0,
            pitch: 1.0
        )
        let b = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.0,
            pitch: 1.0
        )
        let differentRate = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.5,
            pitch: 1.0
        )
        let differentVoice = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .avkit, voiceId: "af_alloy"),
            rate: 1.0,
            pitch: 1.0
        )
        try expectEqual(a, b)
        try expectTrue(a != differentRate)
        try expectTrue(a != differentVoice)
    }

    return s
}
