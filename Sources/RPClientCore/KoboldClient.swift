import Foundation

struct GenerateRequest {
    var prompt: String
    var stopSequences: [String]
    var preset: SamplerPreset
    var maxContextLength: Int
    /// Per-request override for the reply token cap. nil = use preset.maxLength.
    var maxLengthOverride: Int?
}

enum KoboldError: Error {
    case badURL
    case http(Int, String)
    case transport(Error)
}

final class KoboldClient: NSObject, URLSessionDataDelegate {
    private(set) var baseURL: URL
    private lazy var session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        cfg.timeoutIntervalForResource = 0
        return URLSession(configuration: cfg, delegate: self, delegateQueue: nil)
    }()

    private var streamBuffer = Data()
    private var onToken: ((String) -> Void)?
    private var onFinish: ((Error?) -> Void)?
    private var activeTask: URLSessionDataTask?
    private var activeSideCallTask: URLSessionDataTask?

    init(baseURL: URL) {
        self.baseURL = baseURL
        super.init()
    }

    func setBaseURL(_ url: URL) {
        self.baseURL = url
    }

    // MARK: - Streaming generation

    func generateStream(
        request: GenerateRequest,
        onToken: @escaping (String) -> Void,
        onFinish: @escaping (Error?) -> Void
    ) {
        cancel()
        guard let url = URL(string: "/api/extra/generate/stream", relativeTo: baseURL)?.absoluteURL else {
            onFinish(KoboldError.badURL)
            return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("text/event-stream", forHTTPHeaderField: "Accept")

        let body: [String: Any] = [
            "prompt": request.prompt,
            "max_length": request.maxLengthOverride ?? request.preset.maxLength,
            "max_context_length": request.maxContextLength,
            "temperature": request.preset.temperature,
            "top_p": request.preset.topP,
            "top_k": request.preset.topK,
            "min_p": request.preset.minP,
            "rep_pen": request.preset.repPen,
            "rep_pen_range": request.preset.repPenRange,
            "sampler_order": request.preset.samplerOrder,
            "stop_sequence": request.stopSequences,
            "trim_stop": true,
            "stream_sse": true
        ]

        do {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onFinish(error)
            return
        }

        self.streamBuffer = Data()
        self.onToken = onToken
        self.onFinish = onFinish

        let task = session.dataTask(with: req)
        self.activeTask = task
        task.resume()
    }

    func cancel() {
        activeTask?.cancel()
        activeTask = nil
        activeSideCallTask?.cancel()
        activeSideCallTask = nil
        // Best effort abort on server side — works for both streaming and side-calls.
        guard let url = URL(string: "/api/extra/abort", relativeTo: baseURL)?.absoluteURL else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = "{}".data(using: .utf8)
        let abort = URLSession.shared.dataTask(with: req)
        abort.resume()
    }

    // MARK: - URLSessionDataDelegate

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        streamBuffer.append(data)
        processBuffer()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let cb = self.onFinish
        self.onFinish = nil
        self.onToken = nil
        self.activeTask = nil
        if let error = error as NSError?, error.code == NSURLErrorCancelled {
            cb?(nil)
        } else {
            cb?(error)
        }
    }

    private func processBuffer() {
        // SSE frames separated by blank line ("\n\n"). Each frame has "event:" and "data:" lines.
        while let range = streamBuffer.range(of: Data("\n\n".utf8)) {
            let frameData = streamBuffer.subdata(in: 0..<range.lowerBound)
            streamBuffer.removeSubrange(0..<range.upperBound)
            guard let frameText = String(data: frameData, encoding: .utf8) else { continue }
            handleFrame(frameText)
        }
    }

    private func handleFrame(_ frame: String) {
        var dataLines: [String] = []
        for line in frame.split(separator: "\n", omittingEmptySubsequences: false) {
            let s = String(line)
            if s.hasPrefix("data:") {
                let v = s.dropFirst(5)
                let trimmed = v.first == " " ? String(v.dropFirst()) : String(v)
                dataLines.append(trimmed)
            }
        }
        guard !dataLines.isEmpty else { return }
        let payload = dataLines.joined(separator: "\n")
        guard let pd = payload.data(using: .utf8) else { return }
        if let obj = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] {
            if let tok = obj["token"] as? String {
                onToken?(tok)
            }
        }
    }

    // MARK: - Misc endpoints

    func fetchModel(completion: @escaping (Result<String, Error>) -> Void) {
        getJSON(path: "/api/v1/model") { result in
            switch result {
            case .success(let obj):
                if let dict = obj as? [String: Any], let r = dict["result"] as? String {
                    completion(.success(r))
                } else {
                    completion(.success("?"))
                }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    func fetchTrueMaxContext(completion: @escaping (Result<Int, Error>) -> Void) {
        getJSON(path: "/api/extra/true_max_context_length") { result in
            switch result {
            case .success(let obj):
                if let dict = obj as? [String: Any],
                   let v = (dict["value"] as? NSNumber)?.intValue {
                    completion(.success(v))
                } else {
                    completion(.success(4096))
                }
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    struct EmbeddingInfo {
        var name: String?
        var dim: Int?
        var error: String?
    }

    /// Best-effort discovery of the loaded embedding model.
    /// Strategy: probe `/v1/embeddings` with a one-token input — that's the
    /// source of truth for "is the endpoint live" and the vector dimension.
    /// In parallel, list `/v1/models` and pick the entry whose id looks like
    /// an embedding model (kobold registers it alongside the chat model). We
    /// also fall back to `/api/extra/version`'s `embeddings`/`embedding_model`
    /// field for newer kobold builds that surface the name there.
    func fetchEmbeddingInfo(completion: @escaping (EmbeddingInfo) -> Void) {
        let group = DispatchGroup()
        var declaredName: String?

        group.enter()
        getJSON(path: "/api/extra/version") { result in
            if case .success(let obj) = result, let dict = obj as? [String: Any] {
                if let s = dict["embeddings"] as? String, !s.isEmpty, s != "false" {
                    declaredName = s
                } else if let s = dict["embedding_model"] as? String, !s.isEmpty {
                    declaredName = s
                } else if let s = dict["embeddings_model"] as? String, !s.isEmpty {
                    declaredName = s
                }
            }
            group.leave()
        }

        group.enter()
        getJSON(path: "/v1/models") { result in
            if declaredName == nil,
               case .success(let obj) = result,
               let dict = obj as? [String: Any],
               let data = dict["data"] as? [[String: Any]] {
                let ids = data.compactMap { $0["id"] as? String }
                // Heuristic: an id containing "embed", "bge", "e5", "gte" or
                // "nomic" is almost certainly the embedding model. If only one
                // model is registered besides the chat model, take whichever
                // isn't named like a chat model.
                if let match = ids.first(where: { id in
                    let l = id.lowercased()
                    return l.contains("embed") || l.contains("bge") ||
                           l.contains("e5") || l.contains("gte") || l.contains("nomic")
                }) {
                    declaredName = match
                } else if ids.count == 2 {
                    // Two-model setup: pick the one that isn't the chat model.
                    // Caller (AppState) already knows the chat model name; we
                    // can't resolve here, so just take the second entry.
                    declaredName = ids[1]
                }
            }
            group.leave()
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self = self else { return }
            self.embed(texts: ["ping"]) { result in
                switch result {
                case .success(let vecs):
                    let dim = vecs.first?.count
                    completion(EmbeddingInfo(name: declaredName, dim: dim, error: nil))
                case .failure(let err):
                    completion(EmbeddingInfo(name: declaredName, dim: nil, error: "\(err)"))
                }
            }
        }
    }

    func fetchPerf(completion: @escaping (Result<[String: Any], Error>) -> Void) {
        getJSON(path: "/api/extra/perf") { result in
            switch result {
            case .success(let obj):
                completion(.success((obj as? [String: Any]) ?? [:]))
            case .failure(let e): completion(.failure(e))
            }
        }
    }

    /// Non-streaming generation. Used for side-calls (summarize, fact extraction).
    /// Pass a `grammar` to constrain output to a GBNF schema (kobold applies it
    /// at sampling time — invalid tokens are filtered before they're emitted).
    func generate(
        prompt: String,
        stopSequences: [String],
        preset: SamplerPreset,
        maxContextLength: Int,
        grammar: String? = nil,
        maxLengthOverride: Int? = nil,
        completion: @escaping (Result<String, Error>) -> Void
    ) {
        guard let url = URL(string: "/api/v1/generate", relativeTo: baseURL)?.absoluteURL else {
            completion(.failure(KoboldError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "prompt": prompt,
            "max_length": maxLengthOverride ?? preset.maxLength,
            "max_context_length": maxContextLength,
            "temperature": preset.temperature,
            "top_p": preset.topP,
            "top_k": preset.topK,
            "min_p": preset.minP,
            "rep_pen": preset.repPen,
            "rep_pen_range": preset.repPenRange,
            "sampler_order": preset.samplerOrder,
            "stop_sequence": stopSequences,
            "trim_stop": true
        ]
        if let g = grammar, !g.isEmpty {
            body["grammar"] = g
        }
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 600
        let s = URLSession(configuration: cfg)
        let task = s.dataTask(with: req) { [weak self] data, _, err in
            self?.activeSideCallTask = nil
            if let err = err as NSError?, err.code == NSURLErrorCancelled {
                completion(.failure(err))
                return
            }
            if let err = err { completion(.failure(err)); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let results = obj["results"] as? [[String: Any]],
                  let text = results.first?["text"] as? String else {
                completion(.failure(KoboldError.http(0, "no text in response")))
                return
            }
            completion(.success(text))
        }
        activeSideCallTask = task
        task.resume()
    }

    /// Embeds a batch of texts via koboldcpp's `/v1/embeddings` endpoint.
    /// Requires the server to be launched with `--embeddingsmodel <gguf>`. If
    /// no embedding model is loaded, kobold returns an error which we surface.
    func embed(
        texts: [String],
        completion: @escaping (Result<[[Float]], Error>) -> Void
    ) {
        guard !texts.isEmpty else { completion(.success([])); return }
        guard let url = URL(string: "/v1/embeddings", relativeTo: baseURL)?.absoluteURL else {
            completion(.failure(KoboldError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "input": texts,
            "model": "embedding"
        ])
        URLSession.shared.dataTask(with: req) { data, resp, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else {
                completion(.failure(KoboldError.http(0, "no body"))); return
            }
            if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                let msg = String(data: data, encoding: .utf8) ?? ""
                completion(.failure(KoboldError.http(http.statusCode, msg)))
                return
            }
            do {
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let dataArr = obj["data"] as? [[String: Any]] else {
                    completion(.failure(KoboldError.http(0, "unexpected shape")))
                    return
                }
                let vecs: [[Float]] = dataArr.compactMap { entry in
                    guard let raw = entry["embedding"] as? [Any] else { return nil }
                    return raw.compactMap { ($0 as? NSNumber)?.floatValue }
                }
                completion(.success(vecs))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }

    func tokenCount(text: String, completion: @escaping (Result<Int, Error>) -> Void) {
        guard let url = URL(string: "/api/extra/tokencount", relativeTo: baseURL)?.absoluteURL else {
            completion(.failure(KoboldError.badURL)); return
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["prompt": text])
        URLSession.shared.dataTask(with: req) { data, _, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { completion(.success(0)); return }
            if let v = obj["value"] as? Int { completion(.success(v)) }
            else { completion(.success(0)) }
        }.resume()
    }

    private func getJSON(path: String, completion: @escaping (Result<Any, Error>) -> Void) {
        guard let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            completion(.failure(KoboldError.badURL)); return
        }
        URLSession.shared.dataTask(with: url) { data, _, err in
            if let err = err { completion(.failure(err)); return }
            guard let data = data else { completion(.failure(KoboldError.http(0, ""))); return }
            do {
                let obj = try JSONSerialization.jsonObject(with: data)
                completion(.success(obj))
            } catch {
                completion(.failure(error))
            }
        }.resume()
    }
}
