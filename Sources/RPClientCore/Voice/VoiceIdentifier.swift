import Foundation

/// Engine-namespaced voice identifier — `<engine>:<voice-id>`. Phase 6 §7.1m.
///
/// §7.2's `VoicePreference.voiceIdentifier` stores a `VoiceIdentifier` so a
/// chat configured with a Kokoro voice doesn't lose its preference if the
/// user later swaps to AVKit (and vice versa). The bare voice id alone is
/// ambiguous: `af_alloy` could be a Kokoro id or, in some future engine,
/// something else entirely. The engine prefix disambiguates.
///
/// Codable representation is a single string (`"kokoro:af_alloy"`) so the
/// stored JSON shape is compact and the parse is the load-bearing step.
public struct VoiceIdentifier: Equatable, Hashable, Codable {
    public enum Engine: String, Codable {
        case kokoro
        case avkit
    }

    public let engine: Engine
    public let voiceId: String

    public init(engine: Engine, voiceId: String) {
        self.engine = engine
        self.voiceId = voiceId
    }

    /// Parses `<engine>:<voice-id>`. Returns nil on missing colon, unknown
    /// engine prefix, or empty engine/voice-id segment. Splits on the
    /// *first* colon so voice ids that themselves contain colons (none
    /// today, but defensive) round-trip correctly.
    public init?(rawValue: String) {
        guard let colon = rawValue.firstIndex(of: ":") else { return nil }
        let prefix = String(rawValue[..<colon])
        let suffix = String(rawValue[rawValue.index(after: colon)...])
        guard !prefix.isEmpty, !suffix.isEmpty else { return nil }
        guard let engine = Engine(rawValue: prefix) else { return nil }
        self.engine = engine
        self.voiceId = suffix
    }

    public var rawValue: String { "\(engine.rawValue):\(voiceId)" }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let raw = try container.decode(String.self)
        guard let parsed = VoiceIdentifier(rawValue: raw) else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Invalid VoiceIdentifier '\(raw)' — expected '<engine>:<voice-id>'."
            )
        }
        self = parsed
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}
