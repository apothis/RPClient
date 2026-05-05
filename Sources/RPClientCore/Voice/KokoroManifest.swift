import Foundation

/// On-disk state file recording which Kokoro assets are installed at a given
/// storage root. Lives at `<root>/kokoro/manifest.json`. Phase 6 §7.1e.
///
/// The manifest is bookkeeping — it records *what was downloaded*, not
/// *what's currently on disk*. `KokoroModelStore` consults both the manifest
/// and the filesystem to compute live state, so an out-of-band file deletion
/// behaves correctly without manual reconciliation.
public struct KokoroManifest: Codable, Equatable {
    /// Schema version. Bumped when the manifest format changes; readers that
    /// see a higher version log a warning and ignore unknown fields.
    public var version: Int
    public var model: ModelEntry?
    public var voices: [String: VoiceEntry]

    public static let currentVersion = 1
    public static let empty = KokoroManifest(version: currentVersion, model: nil, voices: [:])

    public struct ModelEntry: Codable, Equatable {
        public var sha256: String
        public var bytes: Int64
        public var downloadedAt: Date

        public init(sha256: String, bytes: Int64, downloadedAt: Date) {
            self.sha256 = sha256
            self.bytes = bytes
            self.downloadedAt = downloadedAt
        }
    }

    public struct VoiceEntry: Codable, Equatable {
        public var sha256: String
        public var bytes: Int64
        public var downloadedAt: Date

        public init(sha256: String, bytes: Int64, downloadedAt: Date) {
            self.sha256 = sha256
            self.bytes = bytes
            self.downloadedAt = downloadedAt
        }
    }

    public init(version: Int, model: ModelEntry?, voices: [String: VoiceEntry]) {
        self.version = version
        self.model = model
        self.voices = voices
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? KokoroManifest.currentVersion
        model = try c.decodeIfPresent(ModelEntry.self, forKey: .model)
        voices = try c.decodeIfPresent([String: VoiceEntry].self, forKey: .voices) ?? [:]
    }

    enum CodingKeys: String, CodingKey {
        case version, model, voices
    }
}
