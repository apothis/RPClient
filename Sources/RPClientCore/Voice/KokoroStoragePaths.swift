import Foundation

/// Pure URL layout helper for the on-disk Kokoro assets. Phase 6 §7.1d.
///
/// The on-disk shape under `<root>/kokoro/`:
///
///     model.onnx              — the 325 MB base model
///     voices/<id>.pt          — the per-voice 523 KB tensor files
///     manifest.json           — installed-voices state file (7.1e)
///
/// `root` is the user-configured `Settings.voiceModelPath`, or the
/// Application Support fallback when unset. This type knows nothing about
/// what's actually on disk — see `KokoroModelStore` (7.1f) for live state.
public struct KokoroStoragePaths: Equatable {
    public let root: URL

    public init(root: URL) {
        // Standardise so a trailing slash on the input doesn't bleed into
        // derived paths (e.g. `<root>//kokoro/...`).
        self.root = root.standardizedFileURL
    }

    public var kokoroDirURL: URL {
        root.appendingPathComponent("kokoro", isDirectory: true)
    }

    public var modelURL: URL {
        kokoroDirURL.appendingPathComponent("model.onnx")
    }

    public var voicesDirURL: URL {
        kokoroDirURL.appendingPathComponent("voices", isDirectory: true)
    }

    public var manifestURL: URL {
        kokoroDirURL.appendingPathComponent("manifest.json")
    }

    public func voiceFileURL(id: String) -> URL {
        voicesDirURL.appendingPathComponent("\(id).pt")
    }
}
