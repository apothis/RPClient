import Foundation

/// Pure data source for the entity Voice picker (Phase 6 §7.5a).
///
/// Builds a deterministic list of selectable voices from
/// (a) `KokoroVoiceCatalogue.all` filtered to `KokoroModelStore.installedVoiceIds()`
/// and (b) the AVKit system voices passed in by the AppKit layer (so this
/// type doesn't pull `AVFoundation` into the test target). The popup that
/// consumes the list is responsible for prepending a "(use chat default)"
/// sentinel mapped to a nil `VoicePreference` — that's outside this type.
public enum VoicePickerSource {
    public struct AVKitVoice: Equatable, Hashable {
        public let identifier: String
        public let displayName: String
        public let language: String

        public init(identifier: String, displayName: String, language: String) {
            self.identifier = identifier
            self.displayName = displayName
            self.language = language
        }
    }

    public struct Option: Equatable, Hashable {
        public let identifier: VoiceIdentifier
        /// User-facing label, includes language so cross-engine name clashes
        /// are still distinguishable in a single flat popup.
        public let displayName: String
        /// Section header — `"Kokoro"` or `"System (AVKit)"`. The popup can
        /// either insert separator items or ignore this; the field is here
        /// for the consumer to decide.
        public let groupLabel: String
    }

    public static func options(
        installedKokoroIds: [String],
        avkitVoices: [AVKitVoice]
    ) -> [Option] {
        let kokoro = makeKokoroOptions(installedKokoroIds: installedKokoroIds)
        let avkit = makeAVKitOptions(avkitVoices: avkitVoices)
        return kokoro + avkit
    }

    private static func makeKokoroOptions(installedKokoroIds: [String]) -> [Option] {
        let installed = Set(installedKokoroIds)
        let voices = KokoroVoiceCatalogue.all.filter { installed.contains($0.id) }
        let sorted = voices.sorted { lhs, rhs in
            if lhs.language.displayLabel != rhs.language.displayLabel {
                return lhs.language.displayLabel < rhs.language.displayLabel
            }
            return lhs.displayName < rhs.displayName
        }
        return sorted.map { v in
            Option(
                identifier: VoiceIdentifier(engine: .kokoro, voiceId: v.id),
                displayName: "\(v.displayName) (\(v.language.displayLabel))",
                groupLabel: "Kokoro"
            )
        }
    }

    private static func makeAVKitOptions(avkitVoices: [AVKitVoice]) -> [Option] {
        let sorted = avkitVoices.sorted { lhs, rhs in
            if lhs.language != rhs.language {
                return lhs.language < rhs.language
            }
            return lhs.displayName < rhs.displayName
        }
        return sorted.map { v in
            Option(
                identifier: VoiceIdentifier(engine: .avkit, voiceId: v.identifier),
                displayName: "\(v.displayName) (\(v.language))",
                groupLabel: "System (AVKit)"
            )
        }
    }
}
