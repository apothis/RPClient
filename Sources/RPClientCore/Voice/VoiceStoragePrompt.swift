import Foundation

/// Pure decision: should the first-run voice storage sheet fire after a
/// Settings save? Phase 6 §7.1g. Lives separately from the sheet UI so the
/// trigger logic is unit-testable in `RPClientCoreTests`.
enum VoiceStoragePrompt {
    /// Fire iff the subsystem has just been enabled AND no storage location
    /// has been chosen yet. Re-enabling with an existing path is a no-op
    /// (the user already picked once); disabling never prompts.
    static func shouldPrompt(old: Settings, new: Settings) -> Bool {
        let edge = !old.voiceEnabled && new.voiceEnabled
        let needsLocation = (new.voiceModelPath ?? "").isEmpty
        return edge && needsLocation
    }
}
