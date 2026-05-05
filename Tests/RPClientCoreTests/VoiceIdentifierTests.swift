import Foundation
@testable import RPClientCore

/// Tests for `VoiceIdentifier` — the typed `engine:voice-id` namespacing
/// scheme that §7.2's `VoicePreference.voiceIdentifier` will adopt so
/// stored prefs survive engine swaps. Phase 6 §7.1m. Pure logic.
func voiceIdentifierTests() -> TestSuite {
    let s = TestSuite("VoiceIdentifier")

    s.test("parses Kokoro identifiers") {
        let id = try expectNotNil(VoiceIdentifier(rawValue: "kokoro:af_alloy"))
        try expectEqual(id.engine, .kokoro)
        try expectEqual(id.voiceId, "af_alloy")
    }

    s.test("parses AVKit identifiers with dotted reverse-DNS voice ids") {
        let raw = "avkit:com.apple.voice.premium.en-US.Ava"
        let id = try expectNotNil(VoiceIdentifier(rawValue: raw))
        try expectEqual(id.engine, .avkit)
        try expectEqual(id.voiceId, "com.apple.voice.premium.en-US.Ava")
    }

    s.test("rawValue round-trips") {
        let original = VoiceIdentifier(engine: .kokoro, voiceId: "bf_isabella")
        try expectEqual(original.rawValue, "kokoro:bf_isabella")
        let reparsed = try expectNotNil(VoiceIdentifier(rawValue: original.rawValue))
        try expectEqual(reparsed, original)
    }

    s.test("unknown engine prefix is rejected") {
        try expectNil(VoiceIdentifier(rawValue: "piper:en_US-amy-medium"))
    }

    s.test("missing colon is rejected") {
        try expectNil(VoiceIdentifier(rawValue: "af_alloy"))
        try expectNil(VoiceIdentifier(rawValue: ""))
    }

    s.test("empty voice id is rejected") {
        try expectNil(VoiceIdentifier(rawValue: "kokoro:"))
        try expectNil(VoiceIdentifier(rawValue: "avkit:"))
    }

    s.test("empty engine prefix is rejected") {
        try expectNil(VoiceIdentifier(rawValue: ":af_alloy"))
    }

    s.test("splits on first colon only — voice id may itself contain colons") {
        // Defensive: we don't expect any current engine to use colons in
        // voice ids, but the parser must not silently swallow a future one.
        let id = try expectNotNil(VoiceIdentifier(rawValue: "kokoro:weird:has:colons"))
        try expectEqual(id.engine, .kokoro)
        try expectEqual(id.voiceId, "weird:has:colons")
    }

    s.test("Codable encodes as a single string") {
        let id = VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy")
        let encoder = JSONEncoder()
        let data = try encoder.encode(id)
        let json = String(data: data, encoding: .utf8)
        try expectEqual(json, "\"kokoro:af_alloy\"")
    }

    s.test("Codable decodes from a single string") {
        let json = "\"avkit:com.apple.voice.premium.en-US.Ava\"".data(using: .utf8)!
        let decoder = JSONDecoder()
        let id = try decoder.decode(VoiceIdentifier.self, from: json)
        try expectEqual(id.engine, .avkit)
        try expectEqual(id.voiceId, "com.apple.voice.premium.en-US.Ava")
    }

    s.test("Codable rejects malformed strings") {
        let badJson = "\"not-a-valid-id\"".data(using: .utf8)!
        let decoder = JSONDecoder()
        var threw = false
        do {
            _ = try decoder.decode(VoiceIdentifier.self, from: badJson)
        } catch {
            threw = true
        }
        try expectTrue(threw, "decoder should have thrown on malformed input")
    }

    s.test("Equatable / Hashable behave structurally") {
        let a = VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy")
        let b = VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy")
        let c = VoiceIdentifier(engine: .kokoro, voiceId: "af_aoede")
        let d = VoiceIdentifier(engine: .avkit, voiceId: "af_alloy")
        try expectEqual(a, b)
        try expectTrue(a != c)
        try expectTrue(a != d)
        let set: Set<VoiceIdentifier> = [a, b, c, d]
        try expectEqual(set.count, 3)
    }

    return s
}
