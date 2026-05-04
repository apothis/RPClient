import Foundation

/// "Test connection" probe for a koboldcpp endpoint. Fetches `/api/v1/model`
/// and `/api/extra/version` (and best-effort `/api/extra/true_max_context_length`)
/// and folds the responses into a `ServerCapabilities` snapshot the UI caches
/// on the profile.
///
/// Pure response-parsing lives on the static parse* methods so the JSON-shape
/// rules can be unit-tested without spinning a fake HTTP server.
enum ServerProbe {
    enum ProbeError: Error, CustomStringConvertible {
        case timedOut
        case http(Int)
        case transport(Error)
        case unreachable

        var description: String {
            switch self {
            case .timedOut: return "Timed out"
            case .http(let code): return "HTTP \(code)"
            case .transport(let e): return "Network: \(e.localizedDescription)"
            case .unreachable: return "Unreachable"
            }
        }
    }

    static let timeout: TimeInterval = 5

    static func parseModelName(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return obj["result"] as? String
    }

    static func parseVersion(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let v = obj["result"] as? String, !v.isEmpty { return v }
        if let v = obj["version"] as? String, !v.isEmpty { return v }
        return nil
    }

    static func parseTrueMaxContext(from data: Data) -> Int? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if let n = obj["value"] as? NSNumber { return n.intValue }
        if let n = obj["value"] as? Int { return n }
        return nil
    }

    /// Probe `baseURL` and yield `ServerCapabilities` on success or a
    /// `ProbeError` on failure. Network reach via a short-timeout
    /// `URLSession`. Calls completion on a background queue — caller marshals
    /// to main as appropriate.
    static func probe(
        baseURL: URL,
        completion: @escaping (Result<ServerCapabilities, ProbeError>) -> Void
    ) {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = timeout
        cfg.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: cfg)

        let group = DispatchGroup()
        var modelName: String?
        var version: String?
        var trueMaxCtx: Int?
        var firstError: ProbeError?
        let lock = NSLock()

        func fetch(_ path: String, _ handler: @escaping (Data?) -> Void) {
            guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
                handler(nil); return
            }
            group.enter()
            let task = session.dataTask(with: url) { data, resp, err in
                defer { group.leave() }
                if let err = err {
                    let nsErr = err as NSError
                    let probeErr: ProbeError =
                        nsErr.code == NSURLErrorTimedOut ? .timedOut
                        : nsErr.code == NSURLErrorCannotConnectToHost ? .unreachable
                        : .transport(err)
                    lock.lock()
                    if firstError == nil { firstError = probeErr }
                    lock.unlock()
                    handler(nil)
                    return
                }
                if let http = resp as? HTTPURLResponse, http.statusCode >= 400 {
                    lock.lock()
                    if firstError == nil { firstError = .http(http.statusCode) }
                    lock.unlock()
                    handler(nil)
                    return
                }
                handler(data)
            }
            task.resume()
        }

        fetch("/api/v1/model") { data in
            guard let data = data else { return }
            lock.lock(); modelName = parseModelName(from: data); lock.unlock()
        }
        fetch("/api/extra/version") { data in
            guard let data = data else { return }
            lock.lock(); version = parseVersion(from: data); lock.unlock()
        }
        fetch("/api/extra/true_max_context_length") { data in
            guard let data = data else { return }
            lock.lock(); trueMaxCtx = parseTrueMaxContext(from: data); lock.unlock()
        }

        group.notify(queue: .global()) {
            // /api/v1/model is the canonical liveness signal — if everything
            // failed, surface the error. If model came back, treat as success
            // even if version/maxctx are missing (older koboldcpp builds).
            if modelName == nil, let err = firstError {
                completion(.failure(err))
                return
            }
            let caps = ServerCapabilities(
                modelName: modelName,
                trueMaxContext: trueMaxCtx,
                version: version
            )
            completion(.success(caps))
        }
    }
}
