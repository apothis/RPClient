import Foundation

final class Storage {
    static let shared = Storage()

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        try? fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: vectorsDir, withIntermediateDirectories: true)
    }

    var rootDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RPClient", isDirectory: true)
    }

    var chatsDir: URL { rootDir.appendingPathComponent("chats", isDirectory: true) }
    var vectorsDir: URL { rootDir.appendingPathComponent("vectors", isDirectory: true) }
    var settingsURL: URL { rootDir.appendingPathComponent("settings.json") }

    // MARK: - Settings

    func loadSettings() -> Settings {
        guard let data = try? Data(contentsOf: settingsURL),
              let s = try? decoder.decode(Settings.self, from: data) else {
            return .default
        }
        return s
    }

    func saveSettings(_ s: Settings) {
        try? fm.createDirectory(at: rootDir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(s) {
            atomicWrite(data, to: settingsURL)
        }
    }

    // MARK: - Chats

    func chatURL(_ id: UUID) -> URL {
        chatsDir.appendingPathComponent("\(id.uuidString).json")
    }

    func saveChat(_ chat: Chat) {
        try? fm.createDirectory(at: chatsDir, withIntermediateDirectories: true)
        var c = chat
        c.modified = Date()
        if let data = try? encoder.encode(c) {
            atomicWrite(data, to: chatURL(c.id))
        }
    }

    func loadChat(id: UUID) -> Chat? {
        guard let data = try? Data(contentsOf: chatURL(id)) else { return nil }
        return try? decoder.decode(Chat.self, from: data)
    }

    func deleteChat(id: UUID) {
        try? fm.removeItem(at: chatURL(id))
        try? fm.removeItem(at: vectorsDir.appendingPathComponent("\(id.uuidString).vec.json"))
    }

    func listChats() -> [Chat] {
        guard let urls = try? fm.contentsOfDirectory(at: chatsDir,
            includingPropertiesForKeys: nil) else { return [] }
        var chats: [Chat] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u),
               let c = try? decoder.decode(Chat.self, from: data) {
                chats.append(c)
            }
        }
        chats.sort { $0.modified > $1.modified }
        return chats
    }

    private func atomicWrite(_ data: Data, to url: URL) {
        let tmp = url.appendingPathExtension("tmp")
        do {
            try data.write(to: tmp, options: .atomic)
            if fm.fileExists(atPath: url.path) {
                _ = try? fm.replaceItemAt(url, withItemAt: tmp)
            } else {
                try fm.moveItem(at: tmp, to: url)
            }
        } catch {
            try? data.write(to: url)
        }
    }
}
