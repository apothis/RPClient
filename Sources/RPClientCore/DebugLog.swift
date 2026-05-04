import Foundation

/// Append-only debug log written to $TMPDIR/rpclient-debug.log.
/// Tail with: tail -f $TMPDIR/rpclient-debug.log
final class DebugLog {
    static let shared = DebugLog()
    private let url: URL
    private let queue = DispatchQueue(label: "RPClient.DebugLog")
    private let formatter: DateFormatter

    private init() {
        let tmp = FileManager.default.temporaryDirectory
        url = tmp.appendingPathComponent("rpclient-debug.log")
        formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        try? "\n=== launched \(Date()) ===\n".write(to: url, atomically: true, encoding: .utf8)
    }

    func write(_ s: String) {
        queue.async {
            let line = "[\(self.formatter.string(from: Date()))] \(s)\n"
            guard let data = line.data(using: .utf8) else { return }
            if let h = try? FileHandle(forWritingTo: self.url) {
                defer { try? h.close() }
                _ = try? h.seekToEnd()
                try? h.write(contentsOf: data)
            }
        }
    }

    var path: String { url.path }
}
