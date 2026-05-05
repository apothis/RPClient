import Foundation

/// Per-entity voice settings. Phase 6 §7.2.
///
/// Stored on `Entity.voice` as an optional — `nil` means "use chat-default
/// voice." `voiceIdentifier` is the §7.1m typed value (`engine:voice-id`)
/// so a stored preference survives the user swapping engines later.
///
/// `rate` and `pitch` are 1.0-centred multipliers (1.0 = neutral). Both
/// engines share that convention: Kokoro's `speed` parameter is a multiplier
/// of base speech rate, AVKit's rate/pitch sliders are also multipliers
/// around 1.0. The plan ranges them at 0.5..2.0 — but range validation
/// belongs at the UI/engine boundary, not in the decoder, so an out-of-range
/// value persisted by an older build still loads.
///
/// Codable migration: missing nested `rate`/`pitch` decode to 1.0; missing
/// or malformed `voiceIdentifier` throws (the preference is unusable
/// without it).
public struct VoicePreference: Codable, Equatable {
    public var voiceIdentifier: VoiceIdentifier
    public var rate: Float
    public var pitch: Float

    public init(voiceIdentifier: VoiceIdentifier, rate: Float = 1.0, pitch: Float = 1.0) {
        self.voiceIdentifier = voiceIdentifier
        self.rate = rate
        self.pitch = pitch
    }

    private enum CodingKeys: String, CodingKey {
        case voiceIdentifier, rate, pitch
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceIdentifier = try c.decode(VoiceIdentifier.self, forKey: .voiceIdentifier)
        rate = try c.decodeIfPresent(Float.self, forKey: .rate) ?? 1.0
        pitch = try c.decodeIfPresent(Float.self, forKey: .pitch) ?? 1.0
    }
}
