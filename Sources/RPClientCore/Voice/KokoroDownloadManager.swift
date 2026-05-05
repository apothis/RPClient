import Foundation

/// URLSession-driven download orchestrator for Kokoro assets (Phase 6 §7.1j2).
/// Concurrency cap of 2 — anything beyond queues. On completion: SHA-256
/// the temp file, atomically move to the destination, and call the model
/// store's record API so manifest.json captures the checksum + byte count.
///
/// Lives in `RPClientCore` despite the plan's "likely RPClientVoice" line —
/// it's pure URLSession + Foundation, so keeping it Core-side lets the UI
/// in `RPClientCore` consume it without re-exporting symbols. Smoke-tested
/// per the AppKit/network exemption (the pure types + SHA helper from §7.1j1
/// carry the unit-test load).
///
/// Observers subscribe to `AppNotification.kokoroDownloadStateChanged` and
/// re-read `state(of:)` for the latest snapshot. The userInfo carries the
/// task `id` so observers can ignore unrelated transitions cheaply.
public final class KokoroDownloadManager: NSObject {
    public static let shared = KokoroDownloadManager()

    private let maxConcurrent = 2

    private var session: URLSession!
    private struct Pending {
        let task: KokoroDownloadTask
        let store: KokoroModelStore
    }
    private struct InFlight {
        let task: KokoroDownloadTask
        let store: KokoroModelStore
        let urlTask: URLSessionDownloadTask
    }
    private var pendingQueue: [Pending] = []
    private var inFlight: [Int: InFlight] = [:]
    private var snapshot: [String: KokoroDownloadState] = [:]

    public override init() {
        super.init()
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 60 * 60  // 1h cap on a single file
        session = URLSession(configuration: config, delegate: self, delegateQueue: .main)
    }

    /// Latest known state for `id`, or nil if it's never been enqueued.
    public func state(of id: String) -> KokoroDownloadState? {
        snapshot[id]
    }

    /// Idempotent enqueue. If `task.id` is already running or queued, no-op.
    /// If it previously completed/failed/cancelled, re-runs from scratch.
    public func enqueue(_ task: KokoroDownloadTask, store: KokoroModelStore) {
        switch snapshot[task.id] {
        case .queued, .running: return
        default: break
        }
        snapshot[task.id] = .queued
        pendingQueue.append(Pending(task: task, store: store))
        post(task.id)
        drain()
    }

    /// Cancel an in-flight or queued download. No-op if the id is unknown
    /// or already terminal.
    public func cancel(id: String) {
        if let pair = inFlight.first(where: { $0.value.task.id == id }) {
            pair.value.urlTask.cancel()  // delegate fires .cancelled below
            return
        }
        if let idx = pendingQueue.firstIndex(where: { $0.task.id == id }) {
            pendingQueue.remove(at: idx)
            snapshot[id] = .cancelled
            post(id)
        }
    }

    private func drain() {
        while inFlight.count < maxConcurrent, !pendingQueue.isEmpty {
            let next = pendingQueue.removeFirst()
            let urlTask = session.downloadTask(with: next.task.sourceURL)
            inFlight[urlTask.taskIdentifier] = InFlight(
                task: next.task, store: next.store, urlTask: urlTask
            )
            snapshot[next.task.id] = .running(bytesDownloaded: 0, totalBytes: nil)
            post(next.task.id)
            urlTask.resume()
        }
    }

    private func post(_ id: String) {
        NotificationCenter.default.post(
            name: AppNotification.kokoroDownloadStateChanged,
            object: nil,
            userInfo: ["id": id]
        )
    }
}

// MARK: - URLSessionDownloadDelegate

extension KokoroDownloadManager: URLSessionDownloadDelegate {
    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didWriteData bytesWritten: Int64,
                           totalBytesWritten: Int64,
                           totalBytesExpectedToWrite: Int64) {
        guard let entry = inFlight[downloadTask.taskIdentifier] else { return }
        let total: Int64? = totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        snapshot[entry.task.id] = .running(
            bytesDownloaded: totalBytesWritten, totalBytes: total
        )
        post(entry.task.id)
    }

    public func urlSession(_ session: URLSession,
                           downloadTask: URLSessionDownloadTask,
                           didFinishDownloadingTo location: URL) {
        guard let entry = inFlight[downloadTask.taskIdentifier] else { return }
        // didCompleteWithError fires after this; success path finalises here
        // and removes the in-flight entry, so the error callback no-ops.
        do {
            let sha = try Sha256.hex(ofFileAt: location)
            let attrs = try FileManager.default.attributesOfItem(atPath: location.path)
            let bytes = (attrs[.size] as? NSNumber)?.int64Value ?? 0
            let dest = entry.task.destinationURL
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if FileManager.default.fileExists(atPath: dest.path) {
                _ = try FileManager.default.replaceItemAt(dest, withItemAt: location)
            } else {
                try FileManager.default.moveItem(at: location, to: dest)
            }
            switch entry.task.asset {
            case .baseModel:
                try entry.store.recordModelDownloaded(sha256: sha, bytes: bytes)
            case .voice(let id):
                try entry.store.recordVoiceDownloaded(id: id, sha256: sha, bytes: bytes)
            }
            snapshot[entry.task.id] = .completed(sha256: sha, bytes: bytes)
        } catch {
            snapshot[entry.task.id] = .failed(message: error.localizedDescription)
        }
        inFlight.removeValue(forKey: downloadTask.taskIdentifier)
        post(entry.task.id)
        drain()
    }

    public func urlSession(_ session: URLSession,
                           task: URLSessionTask,
                           didCompleteWithError error: Error?) {
        guard let downloadTask = task as? URLSessionDownloadTask,
              let entry = inFlight[downloadTask.taskIdentifier] else { return }
        // Success path: didFinishDownloadingTo already removed inFlight; this
        // branch only runs for genuine errors / cancellation.
        if let error = error {
            let nsError = error as NSError
            if nsError.code == NSURLErrorCancelled {
                snapshot[entry.task.id] = .cancelled
            } else {
                snapshot[entry.task.id] = .failed(message: error.localizedDescription)
            }
        } else {
            snapshot[entry.task.id] = .failed(message: "Download ended without a result")
        }
        inFlight.removeValue(forKey: downloadTask.taskIdentifier)
        post(entry.task.id)
        drain()
    }
}
