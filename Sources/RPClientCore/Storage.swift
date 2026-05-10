import AppKit
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
        try? fm.createDirectory(at: charactersDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: characterAvatarsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: personasDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: personaAvatarsDir, withIntermediateDirectories: true)
    }

    var rootDir: URL {
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("RPClient", isDirectory: true)
    }

    var chatsDir: URL { rootDir.appendingPathComponent("chats", isDirectory: true) }
    var vectorsDir: URL { rootDir.appendingPathComponent("vectors", isDirectory: true) }
    var charactersDir: URL { rootDir.appendingPathComponent("characters", isDirectory: true) }
    var characterAvatarsDir: URL { charactersDir.appendingPathComponent("avatars", isDirectory: true) }
    var personasDir: URL { rootDir.appendingPathComponent("personas", isDirectory: true) }
    var personaAvatarsDir: URL { personasDir.appendingPathComponent("avatars", isDirectory: true) }
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

    // MARK: - Characters

    func characterURL(_ id: UUID) -> URL {
        charactersDir.appendingPathComponent("\(id.uuidString).json")
    }

    func characterAvatarURL(_ id: UUID) -> URL {
        characterAvatarsDir.appendingPathComponent("\(id.uuidString).png")
    }

    func saveCharacter(_ character: Character) {
        try? fm.createDirectory(at: charactersDir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(character) {
            atomicWrite(data, to: characterURL(character.id))
        }
    }

    func loadCharacter(id: UUID) -> Character? {
        guard let data = try? Data(contentsOf: characterURL(id)) else { return nil }
        return try? decoder.decode(Character.self, from: data)
    }

    func listCharacters() -> [Character] {
        guard let urls = try? fm.contentsOfDirectory(at: charactersDir,
            includingPropertiesForKeys: nil) else { return [] }
        var out: [Character] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u),
               let c = try? decoder.decode(Character.self, from: data) {
                out.append(c)
            }
        }
        out.sort { $0.created > $1.created }
        return out
    }

    func deleteCharacter(id: UUID) {
        try? fm.removeItem(at: characterURL(id))
        try? fm.removeItem(at: characterAvatarURL(id))
    }

    func writeCharacterAvatar(_ pngData: Data, for id: UUID) {
        try? fm.createDirectory(at: characterAvatarsDir, withIntermediateDirectories: true)
        atomicWrite(pngData, to: characterAvatarURL(id))
    }

    func loadCharacterAvatar(id: UUID) -> Data? {
        try? Data(contentsOf: characterAvatarURL(id))
    }

    // MARK: - Personas

    func personaURL(_ id: UUID) -> URL {
        personasDir.appendingPathComponent("\(id.uuidString).json")
    }

    func personaAvatarURL(_ id: UUID) -> URL {
        personaAvatarsDir.appendingPathComponent("\(id.uuidString).png")
    }

    func savePersona(_ persona: Persona) {
        try? fm.createDirectory(at: personasDir, withIntermediateDirectories: true)
        if let data = try? encoder.encode(persona) {
            atomicWrite(data, to: personaURL(persona.id))
        }
    }

    func loadPersona(id: UUID) -> Persona? {
        guard let data = try? Data(contentsOf: personaURL(id)) else { return nil }
        return try? decoder.decode(Persona.self, from: data)
    }

    func listPersonas() -> [Persona] {
        guard let urls = try? fm.contentsOfDirectory(at: personasDir,
            includingPropertiesForKeys: nil) else { return [] }
        var out: [Persona] = []
        for u in urls where u.pathExtension == "json" {
            if let data = try? Data(contentsOf: u),
               let p = try? decoder.decode(Persona.self, from: data) {
                out.append(p)
            }
        }
        out.sort { $0.created > $1.created }
        return out
    }

    func deletePersona(id: UUID) {
        try? fm.removeItem(at: personaURL(id))
        try? fm.removeItem(at: personaAvatarURL(id))
    }

    func writePersonaAvatar(_ pngData: Data, for id: UUID) {
        try? fm.createDirectory(at: personaAvatarsDir, withIntermediateDirectories: true)
        atomicWrite(pngData, to: personaAvatarURL(id))
    }

    func loadPersonaAvatar(id: UUID) -> Data? {
        try? Data(contentsOf: personaAvatarURL(id))
    }

    // MARK: - Avatar normalization

    /// Cap on the longest side of a stored avatar. Source images larger than
    /// this are scaled down on write so the on-disk PNG and the in-memory
    /// `NSImage` both stay cheap to load. Avatar grids render at ≤ 80 px,
    /// detail views at ≤ 256 px, so 512 leaves headroom for retina without
    /// keeping multi-megapixel originals around.
    static let avatarMaxDimension: CGFloat = 512

    /// Re-encode `pngData` (or any AppKit-readable image bytes) into a PNG
    /// whose longest side is ≤ `avatarMaxDimension`. Returns the original
    /// bytes when the image is already small enough so we don't churn the
    /// PNG encoder for no win, nil when the input isn't a decodable image.
    /// Used by the card importer (step 2) and by future "set avatar" UX
    /// (step 3) so both paths produce identically-sized stored files.
    static func normalizeAvatarData(_ pngData: Data) -> Data? {
        guard let img = NSImage(data: pngData) else { return nil }
        let size = img.size
        guard size.width > 0, size.height > 0 else { return nil }
        let longest = max(size.width, size.height)
        if longest <= avatarMaxDimension {
            // Already fits — keep the bytes the caller gave us. Saves a
            // re-encode on imports of well-prepared cards.
            return pngData
        }
        let scale = avatarMaxDimension / longest
        let target = NSSize(width: floor(size.width * scale), height: floor(size.height * scale))
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: Int(target.width),
            pixelsHigh: Int(target.height),
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }
        bitmap.size = target
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let ctx = NSGraphicsContext(bitmapImageRep: bitmap) else { return nil }
        NSGraphicsContext.current = ctx
        ctx.imageInterpolation = .high
        img.draw(
            in: NSRect(origin: .zero, size: target),
            from: .zero,
            operation: .copy,
            fraction: 1.0
        )
        ctx.flushGraphics()
        return bitmap.representation(using: .png, properties: [:])
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
