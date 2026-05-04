import Foundation

/// Importer for SillyTavern character card v2 (`chara_card_v2`). Accepts both
/// `.png` (avatar PNG with a base64-encoded JSON payload in a `tEXt` chunk
/// keyed `chara`) and `.json` (Tavern V2 export, same JSON shape but no
/// avatar). Rejects v1 cards with a clear error — the v1 schema is a
/// flatter, looser shape that doesn't carry `system_prompt`,
/// `post_history_instructions`, or `character_book`, and converting on the
/// fly papers over too much. Users hit that error rarely enough that
/// surfacing it is the right call (V2_PLAN §4.6).
///
/// Output shape: `(Character, avatarPNG: Data?)`. The caller (AppState /
/// File-menu handler) is responsible for running `Storage.normalizeAvatarData`
/// and persisting both. Keeping the importer pure makes the test suite
/// trivial — no temp dirs, no shared singletons.
enum CharacterCardImporter {

    /// 2 MB import cap. PNGs above this are rejected outright rather than
    /// loaded into memory; the spec calls for the cap (V2_PLAN §4.6) and a
    /// sane upper bound also defends against accidental drops of huge images.
    static let maxFileBytes = 2 * 1024 * 1024

    enum ImportError: Error, Equatable {
        case fileTooLarge(bytes: Int)
        case unrecognizedExtension(String)
        case notAPNG
        case missingCharaChunk
        case invalidBase64
        case invalidJSON(String)
        case unsupportedSpec(String)
        case missingName
    }

    struct Result: Equatable {
        let character: Character
        /// Raw PNG bytes from the source card, or nil for `.json` imports.
        /// Already validated as decodable by the time this is returned.
        let avatarPNG: Data?
    }

    // MARK: - Public entry points

    static func importFile(at url: URL) throws -> Result {
        let data = try Data(contentsOf: url)
        guard data.count <= maxFileBytes else {
            throw ImportError.fileTooLarge(bytes: data.count)
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "png":
            return try importPNGData(data)
        case "json":
            return try importJSONData(data)
        default:
            throw ImportError.unrecognizedExtension(ext)
        }
    }

    static func importPNGData(_ data: Data) throws -> Result {
        let chunks: [PNGTextChunks.TextChunk]
        do {
            chunks = try PNGTextChunks.readTextChunks(from: data)
        } catch PNGTextChunks.ParseError.notAPNG {
            throw ImportError.notAPNG
        }
        guard let chara = chunks.first(where: { $0.keyword == "chara" }) else {
            throw ImportError.missingCharaChunk
        }
        let json = try base64DecodeStrict(chara.text)
        let character = try decodeAndMap(json)
        return Result(character: character, avatarPNG: data)
    }

    static func importJSONData(_ data: Data) throws -> Result {
        let character = try decodeAndMap(data)
        return Result(character: character, avatarPNG: nil)
    }

    // MARK: - Decoding

    /// ST v2 card envelope. The `data` field carries every field we map onto
    /// `Character` — top-level fields (name, description, etc.) are present
    /// only on v1 cards, where the envelope itself is missing.
    private struct CardEnvelope: Decodable {
        let spec: String?
        let spec_version: String?
        let data: CardData?
        // V1 fallback: top-level fields. We only check `name` to recognise
        // the shape; we don't actually map v1 onto `Character`.
        let name: String?
    }

    private struct CardData: Decodable {
        let name: String?
        let description: String?
        let personality: String?
        let scenario: String?
        let first_mes: String?
        let alternate_greetings: [String]?
        let system_prompt: String?
        let post_history_instructions: String?
        let tags: [String]?
        let creator: String?
        let character_version: String?
        let character_book: CharacterBook?
    }

    private struct CharacterBook: Decodable {
        let entries: [CharacterBookEntry]?
    }

    /// SillyTavern's character_book entry shape. Most fields are optional —
    /// real-world cards skip everything except `keys` and `content`.
    /// `comment` is the human-readable name in ST's UI; we map it onto
    /// `WorldInfoEntry.name` so library users see the same label.
    private struct CharacterBookEntry: Decodable {
        let keys: [String]?
        let secondary_keys: [String]?
        let content: String?
        let enabled: Bool?
        let insertion_order: Int?
        let priority: Int?
        let constant: Bool?
        let selective: Bool?
        let comment: String?
        let name: String?
    }

    private static func decodeAndMap(_ data: Data) throws -> Character {
        let envelope: CardEnvelope
        do {
            envelope = try JSONDecoder().decode(CardEnvelope.self, from: data)
        } catch {
            throw ImportError.invalidJSON(String(describing: error))
        }
        // V2 cards have spec="chara_card_v2". V1 cards have no spec field
        // (or spec="chara_card_v1"). Accept v2 only.
        let spec = envelope.spec ?? (envelope.name != nil ? "chara_card_v1" : "")
        guard spec == "chara_card_v2" else {
            throw ImportError.unsupportedSpec(spec.isEmpty ? "<missing spec>" : spec)
        }
        guard let cardData = envelope.data else {
            // spec=v2 without a data block is malformed. Treat as v1-shape.
            throw ImportError.unsupportedSpec("chara_card_v2 (missing data)")
        }
        guard let name = cardData.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw ImportError.missingName
        }
        return Character(
            id: UUID(),
            name: name,
            description: cardData.description ?? "",
            personality: cardData.personality ?? "",
            scenario: cardData.scenario ?? "",
            firstMessage: cardData.first_mes ?? "",
            alternateGreetings: cardData.alternate_greetings ?? [],
            systemPrompt: nonEmpty(cardData.system_prompt),
            postHistoryInstructions: nonEmpty(cardData.post_history_instructions),
            tags: cardData.tags ?? [],
            creator: nonEmpty(cardData.creator),
            characterVersion: nonEmpty(cardData.character_version),
            charBook: mapCharBook(cardData.character_book),
            created: Date()
        )
    }

    // MARK: - character_book → [WorldInfoEntry]

    /// Map ST's `character_book.entries` onto our `WorldInfoEntry` model.
    /// Mapping rules — derived from ST's runtime behaviour (not the spec
    /// text, which is sparse here):
    ///   • `constant: true` → `injectionMode = .always` (fires every turn).
    ///   • non-empty `secondary_keys` → preserved verbatim; the existing
    ///     AND-gate logic in `WorldInfoInjector` already handles this.
    ///   • `insertion_order` → `priority` (ST orders by insertion_order desc;
    ///     so does our injector, by design).
    ///   • `comment` → `name` (ST's "memo" field).
    /// Token cap defaults to our 256, ST cards don't carry per-entry caps.
    private static func mapCharBook(_ book: CharacterBook?) -> [WorldInfoEntry] {
        guard let entries = book?.entries, !entries.isEmpty else { return [] }
        return entries.map { e in
            let keys = e.keys ?? []
            let displayName: String = {
                if let c = e.comment, !c.isEmpty { return c }
                if let n = e.name, !n.isEmpty { return n }
                return keys.first ?? "Untitled"
            }()
            let mode: WorldInfoInjectionMode = (e.constant == true) ? .always : .keyword
            let priority = e.insertion_order ?? e.priority ?? 0
            return WorldInfoEntry(
                name: displayName,
                keys: keys,
                secondaryKeys: e.secondary_keys ?? [],
                content: e.content ?? "",
                tokenCap: 256,
                enabled: e.enabled ?? true,
                injectionMode: mode,
                matchScope: .recentTurns(4),
                priority: priority
            )
        }
    }

    // MARK: - Helpers

    /// Strict base64 decode that tolerates the whitespace ST sometimes leaves
    /// in the chunk text. Strips ASCII whitespace before decoding so
    /// otherwise-valid blobs aren't rejected for cosmetic reasons.
    private static func base64DecodeStrict(_ s: String) throws -> Data {
        let stripped = s.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }
        let cleaned = String(String.UnicodeScalarView(stripped))
        guard let data = Data(base64Encoded: cleaned) else {
            throw ImportError.invalidBase64
        }
        return data
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s = s, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return s
    }
}
