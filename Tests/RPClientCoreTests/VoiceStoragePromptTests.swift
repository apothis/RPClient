import Foundation
@testable import RPClientCore

/// Tests for `VoiceStoragePrompt.shouldPrompt(old:new:)` — pure decision
/// for whether the first-run storage sheet should fire after a Settings
/// save (Phase 6 §7.1g).
func voiceStoragePromptTests() -> TestSuite {
    let s = TestSuite("VoiceStoragePrompt")

    func settings(voiceEnabled: Bool, voiceModelPath: String? = nil) -> Settings {
        var out = Settings.default
        out.voiceEnabled = voiceEnabled
        out.voiceModelPath = voiceModelPath
        return out
    }

    s.test("no prompt when voiceEnabled stays false") {
        let old = settings(voiceEnabled: false)
        let new = settings(voiceEnabled: false)
        try expectEqual(VoiceStoragePrompt.shouldPrompt(old: old, new: new), false)
    }

    s.test("no prompt when voiceEnabled stays true") {
        let old = settings(voiceEnabled: true, voiceModelPath: nil)
        let new = settings(voiceEnabled: true, voiceModelPath: nil)
        try expectEqual(VoiceStoragePrompt.shouldPrompt(old: old, new: new), false)
    }

    s.test("no prompt when voiceEnabled flips true → false") {
        let old = settings(voiceEnabled: true)
        let new = settings(voiceEnabled: false)
        try expectEqual(VoiceStoragePrompt.shouldPrompt(old: old, new: new), false)
    }

    s.test("prompt fires when voiceEnabled flips false → true and path is nil") {
        let old = settings(voiceEnabled: false)
        let new = settings(voiceEnabled: true, voiceModelPath: nil)
        try expectEqual(VoiceStoragePrompt.shouldPrompt(old: old, new: new), true)
    }

    s.test("no prompt when voiceEnabled flips false → true but a path is already set") {
        let old = settings(voiceEnabled: false)
        let new = settings(voiceEnabled: true, voiceModelPath: "/Volumes/SSD1/voice-models")
        try expectEqual(VoiceStoragePrompt.shouldPrompt(old: old, new: new), false)
    }

    return s
}
