import Foundation

/// Pure value types describing a Kokoro asset download (Phase 6 §7.1j1).
/// The actual URLSession-driven manager lives in `RPClientVoice`; this layer
/// is here so unit tests in `RPClientCoreTests` can exercise the data shapes
/// without dragging the ONNX target into the test binary.
public enum KokoroDownloadAsset: Equatable, Hashable {
    case baseModel
    case voice(id: String)
}

/// One outstanding or completed download. Identified by `id` so multiple
/// concurrent voice fetches can be tracked side-by-side.
public struct KokoroDownloadTask: Equatable, Identifiable {
    public let asset: KokoroDownloadAsset
    public let sourceURL: URL
    /// Final on-disk location. The manager downloads to a temp file first,
    /// hashes it, then atomically moves it here on success.
    public let destinationURL: URL
    /// Floor used by progress UI before `URLResponse.expectedContentLength`
    /// reports a real total. From `KokoroVoiceCatalogue.modelByteSize` /
    /// `voiceByteSizeApprox`.
    public let expectedBytes: Int64

    public init(asset: KokoroDownloadAsset,
                sourceURL: URL,
                destinationURL: URL,
                expectedBytes: Int64) {
        self.asset = asset
        self.sourceURL = sourceURL
        self.destinationURL = destinationURL
        self.expectedBytes = expectedBytes
    }

    /// Stable id: "model" for the base, the voice id for voices. Used as
    /// the key in progress dictionaries and to look up live tasks for
    /// cancellation.
    public var id: String {
        switch asset {
        case .baseModel: return "model"
        case .voice(let voiceId): return voiceId
        }
    }
}

/// Lifecycle of a single download task. The manager owns transitions; UI
/// observes via a published progress dictionary.
public enum KokoroDownloadState: Equatable {
    case queued
    case running(bytesDownloaded: Int64, totalBytes: Int64?)
    case completed(sha256: String, bytes: Int64)
    case cancelled
    case failed(message: String)
}
