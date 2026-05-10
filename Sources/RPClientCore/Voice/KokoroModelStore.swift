import Foundation

/// Live state for the on-disk Kokoro assets at a given storage root.
/// Phase 6 §7.1e — exposes synchronous state queries + atomic manifest
/// writes; download orchestration and mount-event subscriptions land in
/// 7.1f / 7.1g.
///
/// Design: state is computed by intersecting the manifest record with
/// the filesystem. File presence is the source of truth for `.ready`;
/// the manifest only contributes the recorded SHA-256. An orphan file
/// (on disk, no manifest entry) reads as `.ready(_, sha: nil)` rather
/// than throwing — this matters for users who manually drop files into
/// the storage path.

public enum BaseModelState: Equatable {
    case missing
    case ready(URL, sha256: String?)
    case volumeUnavailable
}

public enum VoiceState: Equatable {
    case missing
    case ready(URL, sha256: String?)
    case volumeUnavailable
}

public final class KokoroModelStore {
    public let paths: KokoroStoragePaths
    private let fileManager: FileManager
    private let jsonEncoder: JSONEncoder
    private let jsonDecoder: JSONDecoder

    public init(paths: KokoroStoragePaths, fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.jsonEncoder = e
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        self.jsonDecoder = d
    }

    // MARK: - State queries

    public func baseModelState() -> BaseModelState {
        guard volumeAvailable() else { return .volumeUnavailable }
        guard fileManager.fileExists(atPath: paths.modelURL.path) else { return .missing }
        let sha = currentManifest().model?.sha256
        return .ready(paths.modelURL, sha256: sha)
    }

    public func voiceState(id: String) -> VoiceState {
        guard volumeAvailable() else { return .volumeUnavailable }
        let url = paths.voiceFileURL(id: id)
        guard fileManager.fileExists(atPath: url.path) else { return .missing }
        let sha = currentManifest().voices[id]?.sha256
        return .ready(url, sha256: sha)
    }

    /// Voices both recorded in the manifest AND physically present on disk,
    /// sorted by id. Orphan files (on disk but not in manifest) are NOT
    /// listed here — they're real (`voiceState(id:)` returns `.ready`) but
    /// they don't appear in the library manager's "Installed" filter until
    /// the manifest catches up.
    public func installedVoiceIds() -> [String] {
        guard volumeAvailable() else { return [] }
        let manifest = currentManifest()
        return manifest.voices.keys
            .filter { id in
                fileManager.fileExists(atPath: paths.voiceFileURL(id: id).path)
            }
            .sorted()
    }

    // MARK: - Manifest IO

    public func currentManifest() -> KokoroManifest {
        guard let data = try? Data(contentsOf: paths.manifestURL),
              let manifest = try? jsonDecoder.decode(KokoroManifest.self, from: data)
        else {
            return .empty
        }
        return manifest
    }

    public func writeManifest(_ manifest: KokoroManifest) throws {
        try ensureDirectoriesExist()
        let data = try jsonEncoder.encode(manifest)
        // Atomic write via temp file + rename — protects against crashes
        // mid-write that would otherwise corrupt the manifest.
        let tmp = paths.manifestURL.appendingPathExtension("tmp")
        try data.write(to: tmp, options: [.atomic])
        if fileManager.fileExists(atPath: paths.manifestURL.path) {
            _ = try fileManager.replaceItemAt(paths.manifestURL, withItemAt: tmp)
        } else {
            try fileManager.moveItem(at: tmp, to: paths.manifestURL)
        }
    }

    // MARK: - Recording downloads

    public func recordModelDownloaded(sha256: String, bytes: Int64, at: Date = Date()) throws {
        var m = currentManifest()
        m.model = .init(sha256: sha256, bytes: bytes, downloadedAt: at)
        try writeManifest(m)
    }

    public func recordVoiceDownloaded(id: String, sha256: String, bytes: Int64, at: Date = Date()) throws {
        var m = currentManifest()
        m.voices[id] = .init(sha256: sha256, bytes: bytes, downloadedAt: at)
        try writeManifest(m)
    }

    public func removeModel() throws {
        if fileManager.fileExists(atPath: paths.modelURL.path) {
            try fileManager.removeItem(at: paths.modelURL)
        }
        var m = currentManifest()
        m.model = nil
        try writeManifest(m)
    }

    public func removeVoice(id: String) throws {
        let url = paths.voiceFileURL(id: id)
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        var m = currentManifest()
        if m.voices[id] != nil {
            m.voices.removeValue(forKey: id)
            try writeManifest(m)
        }
    }

    // MARK: - Helpers

    /// Creates `<root>/kokoro/voices/` if it doesn't exist. Called before any
    /// write so the first download against a fresh root just works.
    private func ensureDirectoriesExist() throws {
        try fileManager.createDirectory(
            at: paths.voicesDirURL, withIntermediateDirectories: true
        )
    }

    /// Returns false when the configured root is on a volume that isn't
    /// currently mounted. Catches the "user unplugged the SSD" case so the
    /// caller can fall back to AVKit cleanly rather than crashing on file IO.
    private func volumeAvailable() -> Bool {
        let path = paths.root.path
        if fileManager.fileExists(atPath: path) { return true }
        // Path under /Volumes/<X>/... — check the mount point itself. If the
        // mount-point dir is gone, the volume isn't currently mounted.
        if path.hasPrefix("/Volumes/") {
            let comps = path.split(separator: "/", omittingEmptySubsequences: true)
            if comps.count >= 2 {
                let mountPoint = "/Volumes/\(comps[1])"
                return fileManager.fileExists(atPath: mountPoint)
            }
        }
        // Path is on the boot volume; the dir simply doesn't exist yet. That's
        // a "missing" state for assets, not a "volume unavailable" state.
        return true
    }
}
