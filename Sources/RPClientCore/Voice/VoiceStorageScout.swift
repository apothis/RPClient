import Foundation

/// Enumerates candidate locations for the configurable voice-model path.
/// Drives the first-run prompt (Phase 6 §7.1e) and the "Set storage
/// location…" picker.
///
/// The core function `options(from:applicationSupport:)` is **pure** — it
/// takes already-probed volume metadata and returns the ordered list. The
/// live `liveOptions(fileManager:)` convenience wraps `FileManager` to feed
/// the pure function in production code; tests construct `VolumeProbe`
/// fixtures directly to avoid a hard dependency on whatever the test
/// machine has mounted.
public enum VoiceStorageScout {

    /// Caller-side description of a mounted volume. Tests construct these
    /// directly; production code derives them from FileManager.
    public struct VolumeProbe: Equatable {
        public let url: URL
        public let name: String
        public let freeBytes: Int64?
        public let isInternal: Bool

        public init(url: URL, name: String, freeBytes: Int64?, isInternal: Bool) {
            self.url = url
            self.name = name
            self.freeBytes = freeBytes
            self.isInternal = isInternal
        }
    }

    /// One row in the first-run picker / "Set storage location…" UI.
    public struct VoiceStorageOption: Equatable, Identifiable {
        public let id: String
        public let label: String
        public let path: URL
        public let isExternal: Bool
        public let freeBytes: Int64?
    }

    /// Minimum free space required to be a viable host for Kokoro assets.
    /// Model is 325 MB; allow ~200 MB slack for voices + manifest + future
    /// growth.
    public static let minFreeBytes: Int64 = 600_000_000

    /// Pure: rank `mountedVolumes` (by free space desc, dropping internal
    /// volumes and any below `minFreeBytes`) and append Application Support
    /// as the always-present fallback.
    public static func options(
        from mountedVolumes: [VolumeProbe],
        applicationSupport: URL
    ) -> [VoiceStorageOption] {
        let externals = mountedVolumes
            .filter { !$0.isInternal }
            .filter { probe in
                // Unknown free-space is allowed through; we'd rather offer it
                // and let the OS reject the write than silently hide a
                // viable network volume.
                guard let bytes = probe.freeBytes else { return true }
                return bytes >= minFreeBytes
            }
            .sorted { lhs, rhs in
                switch (lhs.freeBytes, rhs.freeBytes) {
                case let (l?, r?): return l > r
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.name < rhs.name
                }
            }

        var out: [VoiceStorageOption] = externals.map { probe in
            VoiceStorageOption(
                id: probe.url.path,
                label: externalLabel(probe),
                path: probe.url,
                isExternal: true,
                freeBytes: probe.freeBytes
            )
        }
        out.append(VoiceStorageOption(
            id: applicationSupport.path,
            label: "Application Support (default)",
            path: applicationSupport,
            isExternal: false,
            freeBytes: nil
        ))
        return out
    }

    private static func externalLabel(_ probe: VolumeProbe) -> String {
        guard let bytes = probe.freeBytes else {
            return "\(probe.name) — free space unknown"
        }
        return "\(probe.name) — \(formatBytes(bytes)) free"
    }

    private static func formatBytes(_ bytes: Int64) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowedUnits = [.useMB, .useGB, .useTB]
        return f.string(fromByteCount: bytes)
    }

    /// Live convenience wrapper. Probes `FileManager` for mounted volumes
    /// and forwards into the pure function. Phase 6 §7.1e calls this on
    /// first-run-prompt presentation.
    public static func liveOptions(fileManager: FileManager = .default) -> [VoiceStorageOption] {
        let probes = mountedVolumeProbes(fileManager: fileManager)
        let appSupport = fileManager
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("voice-models", isDirectory: true)
        return options(from: probes, applicationSupport: appSupport)
    }

    private static func mountedVolumeProbes(fileManager: FileManager) -> [VolumeProbe] {
        let keys: [URLResourceKey] = [
            .volumeNameKey,
            .volumeAvailableCapacityKey,
            .volumeIsInternalKey,
        ]
        guard let urls = fileManager.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else {
            return []
        }
        return urls.compactMap { url -> VolumeProbe? in
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else { return nil }
            return VolumeProbe(
                url: url,
                name: values.volumeName ?? url.lastPathComponent,
                freeBytes: values.volumeAvailableCapacity.map(Int64.init),
                isInternal: values.volumeIsInternal ?? false
            )
        }
    }
}
