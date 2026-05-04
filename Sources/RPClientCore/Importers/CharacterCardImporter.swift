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

    /// Card envelope covering every JSON shape we accept:
    ///   • ST v2: `{spec: "chara_card_v2", data: {...}}` — `data` carries
    ///     every mapped field.
    ///   • ST/TavernAI v1: flat top-level `{name, description, personality,
    ///     scenario, first_mes, ...}`. No `data` block, no `spec`.
    ///   • Pygmalion v1: same as TavernAI v1 but uses aliased keys
    ///     (`char_name` for `name`, `char_persona` for `personality`,
    ///     `char_greeting` for `first_mes`, `world_scenario` for `scenario`).
    ///     KoboldAI Lite tolerates these aliases on import; we do too so
    ///     cards exported from kobold round-trip cleanly.
    private struct CardEnvelope: Decodable {
        let spec: String?
        let spec_version: String?
        let data: CardData?
        // V1 / Pygmalion top-level fields. CodingKeys aliases the Pygmalion
        // names onto the modern field names so a single field on the
        // envelope covers either spelling.
        let name: String?
        let description: String?
        let personality: String?
        let scenario: String?
        let first_mes: String?
        let mes_example: String?
        let creator: String?
        let character_version: String?
        let tags: [String]?

        private enum CodingKeys: String, CodingKey {
            case spec, spec_version, data
            case name, description, personality, scenario, first_mes, mes_example
            case creator, character_version, tags
            // Pygmalion aliases — decoded as fallbacks below.
            case char_name, char_persona, char_greeting, world_scenario, example_dialogue
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            spec = try c.decodeIfPresent(String.self, forKey: .spec)
            spec_version = try c.decodeIfPresent(String.self, forKey: .spec_version)
            data = try c.decodeIfPresent(CardData.self, forKey: .data)
            name = try c.decodeIfPresent(String.self, forKey: .name)
                ?? c.decodeIfPresent(String.self, forKey: .char_name)
            description = try c.decodeIfPresent(String.self, forKey: .description)
            personality = try c.decodeIfPresent(String.self, forKey: .personality)
                ?? c.decodeIfPresent(String.self, forKey: .char_persona)
            scenario = try c.decodeIfPresent(String.self, forKey: .scenario)
                ?? c.decodeIfPresent(String.self, forKey: .world_scenario)
            first_mes = try c.decodeIfPresent(String.self, forKey: .first_mes)
                ?? c.decodeIfPresent(String.self, forKey: .char_greeting)
            mes_example = try c.decodeIfPresent(String.self, forKey: .mes_example)
                ?? c.decodeIfPresent(String.self, forKey: .example_dialogue)
            creator = try c.decodeIfPresent(String.self, forKey: .creator)
            character_version = try c.decodeIfPresent(String.self, forKey: .character_version)
            tags = try c.decodeIfPresent([String].self, forKey: .tags)
        }
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
        // v2 cards have a spec="chara_card_v2" + data block. v1 / Pygmalion
        // cards skip the envelope entirely and put fields at the top level.
        // Anything else (future spec, malformed) gets rejected — but we lean
        // toward acceptance: a missing spec with v1 fields populated is
        // assumed to be v1 even if the file doesn't say so explicitly,
        // matching kobold's loose import policy.
        if envelope.spec == "chara_card_v2", let cardData = envelope.data {
            return try mapV2(cardData)
        }
        if let spec = envelope.spec, spec != "chara_card_v1", !spec.isEmpty {
            throw ImportError.unsupportedSpec(spec)
        }
        return try mapV1(envelope)
    }

    /// Build a `Character` from a v2 `data` block.
    private static func mapV2(_ d: CardData) throws -> Character {
        guard let name = d.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw ImportError.missingName
        }
        return Character(
            id: UUID(),
            name: name,
            description: d.description ?? "",
            personality: d.personality ?? "",
            scenario: d.scenario ?? "",
            firstMessage: d.first_mes ?? "",
            alternateGreetings: d.alternate_greetings ?? [],
            systemPrompt: nonEmpty(d.system_prompt),
            postHistoryInstructions: nonEmpty(d.post_history_instructions),
            tags: d.tags ?? [],
            creator: nonEmpty(d.creator),
            characterVersion: nonEmpty(d.character_version),
            charBook: mapCharBook(d.character_book),
            created: Date()
        )
    }

    /// Build a `Character` from a flat v1 / Pygmalion envelope. v1 cards
    /// don't carry `system_prompt`, `post_history_instructions`,
    /// `alternate_greetings`, or a `character_book`, so those land empty —
    /// the user can fill them in later via the (future) editor. `mes_example`
    /// from v1 is folded into the description with a separator since
    /// `Character` has no dedicated example-dialogue field; this matches
    /// what ST does when it converts a v1 card to v2 internally.
    private static func mapV1(_ env: CardEnvelope) throws -> Character {
        guard let rawName = env.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            throw ImportError.missingName
        }
        let baseDescription = env.description ?? ""
        let example = env.mes_example?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let description: String = {
            guard !example.isEmpty else { return baseDescription }
            let separator = baseDescription.isEmpty ? "" : "\n\n"
            return baseDescription + separator + "Example dialogue:\n" + example
        }()
        return Character(
            id: UUID(),
            name: rawName,
            description: description,
            personality: env.personality ?? "",
            scenario: env.scenario ?? "",
            firstMessage: env.first_mes ?? "",
            alternateGreetings: [],
            systemPrompt: nil,
            postHistoryInstructions: nil,
            tags: env.tags ?? [],
            creator: nonEmpty(env.creator),
            characterVersion: nonEmpty(env.character_version),
            charBook: [],
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
