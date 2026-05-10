import Foundation
@testable import RPClientCore

// Phase 10 §10.0.a — opt-in loader for a user's actual chat from the
// production storage directory. Smokes default to synthetic fixtures;
// when `--chat <id>` is passed at the CLI, the smoke calls
// `RealChatLoader.loadChat(id:)` to read it from disk. Useful for
// reproducing model-quirk reports against the chat where the bug
// surfaced — synthetics can't always reproduce a wedge that depends
// on the user's specific lorebook / persona / world-info shape.
//
// Public API:
//   - `loadChat(id:)` — reads from the production app-support dir
//   - `loadChat(id:in:)` — explicit dir, used by the test path
//   - `chatsDirectory()` — production chats dir for diagnostics
enum RealChatLoader {

    enum LoadError: Error, CustomStringConvertible {
        case notFound(URL)
        case decode(URL, Error)

        var description: String {
            switch self {
            case .notFound(let url):
                return "RealChatLoader: no chat at \(url.path)"
            case .decode(let url, let err):
                return "RealChatLoader: decode failed at \(url.path) — \(err)"
            }
        }
    }

    /// Production chats directory: `~/Library/Application Support/RPClient/chats/`.
    /// Mirrors `Storage.chatsDir` but without taking the AppKit-bound
    /// `Storage.shared` singleton (smokes are CLI-side; we don't want
    /// the implicit `Storage.init()` side-effect of creating every
    /// app-support subdirectory just to read one chat).
    static func chatsDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("chats", isDirectory: true)
    }

    /// Load `<chatsDir>/<id>.json` and decode as `Chat`. The id may be
    /// either a bare UUID string or one with a trailing `.json`
    /// (the user typically pastes from `ls`).
    static func loadChat(id: String) throws -> Chat {
        try loadChat(id: id, in: chatsDirectory())
    }

    /// Same as `loadChat(id:)` but reads from an explicit directory.
    /// Test path uses this with a temp dir.
    static func loadChat(id: String, in directory: URL) throws -> Chat {
        let trimmed = id.hasSuffix(".json") ? String(id.dropLast(5)) : id
        let url = directory.appendingPathComponent("\(trimmed).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw LoadError.notFound(url)
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.decode(url, error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Chat.self, from: data)
        } catch {
            throw LoadError.decode(url, error)
        }
    }

    /// Production characters directory:
    /// `~/Library/Application Support/RPClient/characters/`. Mirrors
    /// `Storage.charactersDir` without taking the AppKit-bound
    /// `Storage.shared` singleton.
    static func charactersDirectory() -> URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base
            .appendingPathComponent("RPClient", isDirectory: true)
            .appendingPathComponent("characters", isDirectory: true)
    }

    /// Load a character by UUID. Returns nil when no card file exists
    /// for that id (e.g. the chat references a deleted character).
    static func loadCharacter(id: UUID) throws -> Character? {
        let url = charactersDirectory().appendingPathComponent("\(id.uuidString).json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            return nil
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoadError.decode(url, error)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(Character.self, from: data)
        } catch {
            throw LoadError.decode(url, error)
        }
    }
}
