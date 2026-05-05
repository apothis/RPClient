import Foundation

/// Per-utterance voice configuration passed through `SpeechSynthesizing.speak`.
/// Phase 6 §7.4. Fold of `VoicePreference` into the audio path: the resolved
/// fallback chain (`Entity.voice ?? Chat.voice ?? Settings.defaultVoice`)
/// becomes a `SpeakOptions` at the boundary; engines consume it directly.
///
/// `voice == nil` means "engine default" — the receiving synthesizer picks
/// whatever it considers neutral. Speaker dispatches between engine
/// adapters by `voice?.engine`; nil is dispatcher-defined.
public struct SpeakOptions: Equatable {
    public let voice: VoiceIdentifier?
    /// 1.0-centred multiplier. Both engines share the convention; AVKit's
    /// native rate (0.0..1.0 with 0.5 = normal) is mapped at the adapter.
    public let rate: Float
    /// 1.0-centred multiplier. Honoured by AVKit; ignored by Kokoro (the
    /// model has no pitch parameter — only speed).
    public let pitch: Float

    public static let `default` = SpeakOptions(voice: nil, rate: 1.0, pitch: 1.0)

    public init(voice: VoiceIdentifier? = nil, rate: Float = 1.0, pitch: Float = 1.0) {
        self.voice = voice
        self.rate = rate
        self.pitch = pitch
    }

    /// Project a `VoicePreference?` into options. Nil preference → defaults.
    public init(preference: VoicePreference?) {
        if let p = preference {
            self.init(voice: p.voiceIdentifier, rate: p.rate, pitch: p.pitch)
        } else {
            self.init()
        }
    }
}
