import Foundation
@testable import RPClientCore

/// Phase 6 §7.2c: per-chat voice override + global default narrator voice.
///
/// Both `Chat.voice` and `Settings.defaultVoice` are optional `VoicePreference`s
/// that decode additively. The two-tier fallback (entity → chat → settings)
/// is consumed by the speaker layer in §7.4; §7.2c only ships the data
/// fields so §7.5's UI has somewhere to write to.
func chatSettingsVoiceTests() -> TestSuite {
    let s = TestSuite("Chat/Settings voice migration")

    let chatEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let chatDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: - Chat.voice

    s.test("Chat: old-shape JSON without voice decodes as nil") {
        let now = ISO8601DateFormatter().string(from: Date())
        let oldJson = """
        {
            "id": "11111111-1111-1111-1111-111111111111",
            "title": "Pre-§7.2c chat",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced"
        }
        """.data(using: .utf8)!
        let chat = try chatDecoder.decode(Chat.self, from: oldJson)
        try expectNil(chat.voice)
    }

    s.test("Chat: voice round-trips") {
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.1,
            pitch: 0.95
        )
        var chat = Chat(title: "With voice")
        chat.voice = pref
        let data = try chatEncoder.encode(chat)
        let decoded = try chatDecoder.decode(Chat.self, from: data)
        try expectEqual(decoded.voice, pref)
    }

    s.test("Chat: malformed voice rejects the whole chat") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "22222222-2222-2222-2222-222222222222",
            "title": "Bad voice",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "voice": {"voiceIdentifier": "not-an-id"}
        }
        """.data(using: .utf8)!
        var threw = false
        do {
            _ = try chatDecoder.decode(Chat.self, from: json)
        } catch {
            threw = true
        }
        try expectTrue(threw, "Chat decoder should propagate malformed VoicePreference")
    }

    // MARK: - Settings.defaultVoice

    s.test("Settings: old-shape JSON without defaultVoice decodes as nil") {
        let oldJson = """
        {
            "servers": [],
            "defaultServerId": "33333333-3333-3333-3333-333333333333",
            "userName": "",
            "defaultTemplateId": "gemma",
            "defaultSamplerPresetId": "balanced",
            "voiceEnabled": false,
            "voiceActive": true,
            "maxContextOverride": 0,
            "retrieval": {},
            "uiFontOffset": 0,
            "replyTokensOverride": 0,
            "factExtractionEnabled": true,
            "factExtractionEveryNTurns": 4,
            "priorityTopicLibrary": [],
            "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!
        // The fallback `serverURL` migration kicks in when servers is empty — that's
        // fine here; we only care about defaultVoice.
        let settings = try JSONDecoder().decode(Settings.self, from: oldJson)
        try expectNil(settings.defaultVoice)
    }

    s.test("Settings: defaultVoice round-trips") {
        var settings = Settings.default
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.premium.en-US.Ava"),
            rate: 1.0,
            pitch: 1.0
        )
        settings.defaultVoice = pref
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        try expectEqual(decoded.defaultVoice, pref)
    }

    s.test("Settings: encode omits defaultVoice when nil") {
        // Don't bloat the on-disk JSON with an explicit "defaultVoice": null on
        // every fresh install. encodeIfPresent writes nothing for nil; verify.
        let settings = Settings.default
        try expectNil(settings.defaultVoice)
        let data = try JSONEncoder().encode(settings)
        let json = String(data: data, encoding: .utf8) ?? ""
        try expectTrue(!json.contains("defaultVoice"),
                       "encoded settings should not contain a defaultVoice key when nil; got: \(json)")
    }

    return s
}
