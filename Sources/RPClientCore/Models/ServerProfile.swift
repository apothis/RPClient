import Foundation

enum ServerRole: String, Codable, CaseIterable, Equatable {
    case general
    case summarizer
    case extractor
    case embeddings
}

struct ServerCapabilities: Codable, Equatable {
    var modelName: String?
    var trueMaxContext: Int?
    var version: String?
}

struct ServerProfile: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var baseURL: URL
    var capabilities: ServerCapabilities?
    var lastProbed: Date?

    init(id: UUID = UUID(),
         name: String,
         baseURL: URL,
         capabilities: ServerCapabilities? = nil,
         lastProbed: Date? = nil) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.capabilities = capabilities
        self.lastProbed = lastProbed
    }
}
