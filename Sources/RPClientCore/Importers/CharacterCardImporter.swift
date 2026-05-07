import Foundation

/// Importer for SillyTavern character cards. Accepts:
///   • v2 (`chara_card_v2`): JSON-in-`chara`-tEXt-chunk PNG, or `.json`.
///   • v3 (`chara_card_v3`): JSON-in-`ccv3`-tEXt-chunk PNG (preferred), or
///     `.json`, or v3 envelope inside the `chara` chunk (the v2-reader
///     backfill convention).
///   • v1 / Pygmalion / KoboldAI Lite (flat top-level fields, no `data` block):
///     mapped onto the v2 fields with `mes_example` going first-class to
///     `Character.messageExample` (Phase 9 §5.2c — pre-Phase-9 imports
///     squashed it into `description`; that path is gone).
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
        // Phase 9 §5.2c — prefer the v3 `ccv3` chunk. Fall back to `chara`
        // (covers v2 cards and v3 cards using the v2-reader backfill).
        let payload = chunks.first(where: { $0.keyword == "ccv3" })
            ?? chunks.first(where: { $0.keyword == "chara" })
        guard let payload = payload else {
            throw ImportError.missingCharaChunk
        }
        let json = try base64DecodeStrict(payload.text)
        let character = try decodeAndMap(json)
        return Result(character: character, avatarPNG: data)
    }

    // MARK: - Legacy v1-squash detection (Phase 9 §5.2c)

    /// Detect the literal `\n\nExample dialogue:\n` separator that Phase 9
    /// pre-§5.2c v1 imports inserted into `description`. Used by the §3.5
    /// "Restore example dialogue" affordance in the creator window and by
    /// the importer's diagnostic log path. The check is deliberately strict
    /// (requires the blank-line + `Example dialogue:` + newline shape)
    /// because authors write the loose phrase "Example dialogue:" in prose
    /// often enough that a fuzzier match would false-positive. Keep
    /// conservative.
    static let legacyExamplePrefix = "\n\nExample dialogue:\n"

    static func containsLegacyExamplePrefix(_ text: String) -> Bool {
        text.contains(legacyExamplePrefix)
    }

    /// Split a legacy v1-squashed `description` back into
    /// `(description, messageExample)`. Returns nil when the canonical
    /// separator isn't present. Splits on the *first* occurrence so a
    /// twice-squashed string preserves the trailing portion in the
    /// example slot. Used by the §3.5 "Restore example dialogue"
    /// affordance — author opts in via the creator UI; not auto-applied.
    static func splitLegacyExampleSquash(_ text: String) -> (description: String, messageExample: String)? {
        guard let range = text.range(of: legacyExamplePrefix) else { return nil }
        let before = String(text[..<range.lowerBound])
        let after = String(text[range.upperBound...])
        return (before, after)
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
        let mes_example: String?
        let alternate_greetings: [String]?
        let system_prompt: String?
        let post_history_instructions: String?
        let creator_notes: String?
        let tags: [String]?
        let creator: String?
        let character_version: String?
        let character_book: CharacterBook?
        // V2 + V3 spec passthrough — preserved verbatim (§5.2c).
        let extensions: [String: JSONValue]?
        // V3-only fields (§5.2b/§5.2c).
        let nickname: String?
        let group_only_greetings: [String]?
        let source: [String]?
        let creator_notes_multilingual: [String: String]?
        let creation_date: Double?
        let modification_date: Double?
        let assets: [JSONValue]?
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
        // v2 / v3 cards have a spec + data block. v1 / Pygmalion cards skip
        // the envelope entirely and put fields at the top level. Anything
        // else (future spec, malformed) gets rejected — but we lean toward
        // acceptance: a missing spec with v1 fields populated is assumed to
        // be v1 even if the file doesn't say so explicitly, matching kobold's
        // loose import policy.
        if envelope.spec == "chara_card_v2", let cardData = envelope.data {
            return try mapV2OrV3(cardData, isV3: false)
        }
        if envelope.spec == "chara_card_v3", let cardData = envelope.data {
            return try mapV2OrV3(cardData, isV3: true)
        }
        if let spec = envelope.spec, spec != "chara_card_v1", !spec.isEmpty {
            throw ImportError.unsupportedSpec(spec)
        }
        return try mapV1(envelope)
    }

    /// Build a `Character` from a v2 or v3 `data` block. v3-only fields are
    /// only populated when `isV3` is true (a v2 envelope with stray v3 keys
    /// gets the v3 fields ignored to keep the v2 contract honest).
    private static func mapV2OrV3(_ d: CardData, isV3: Bool) throws -> Character {
        guard let name = d.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.isEmpty else {
            throw ImportError.missingName
        }
        let merged = mergeExtensions(d.extensions, assets: isV3 ? d.assets : nil)
        let description = d.description ?? ""
        if containsLegacyExamplePrefix(description) {
            DebugLog.shared.write(
                "importer: ⚠ legacy v1-squash separator detected in description "
                + "(consider re-importing the original card to restore mes_example)"
            )
        }
        return Character(
            id: UUID(),
            name: name,
            description: description,
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
            created: Date(),
            messageExample: d.mes_example ?? "",
            creatorNotes: nonEmpty(d.creator_notes),
            extensions: merged,
            nickname: isV3 ? nonEmpty(d.nickname) : nil,
            groupOnlyGreetings: isV3 ? (d.group_only_greetings ?? []) : [],
            source: isV3 ? (d.source ?? []) : [],
            creatorNotesMultilingual: isV3 ? d.creator_notes_multilingual : nil,
            creationDate: isV3 ? d.creation_date.map { Date(timeIntervalSince1970: $0) } : nil,
            modificationDate: isV3 ? d.modification_date.map { Date(timeIntervalSince1970: $0) } : nil
        )
    }

    /// Merge the source `extensions` blob with the v3 `assets[]` array if
    /// present, parking assets under `rpclient/assets_passthrough` so a
    /// re-export can restore them losslessly. Source extensions win over
    /// any pre-existing passthrough key from a previous round-trip — the
    /// live `data.assets` is authoritative.
    private static func mergeExtensions(
        _ source: [String: JSONValue]?,
        assets: [JSONValue]?
    ) -> [String: JSONValue]? {
        var out: [String: JSONValue] = source ?? [:]
        if let assets = assets, !assets.isEmpty {
            out["rpclient/assets_passthrough"] = .array(assets)
        }
        return out.isEmpty ? nil : out
    }

    /// Build a `Character` from a flat v1 / Pygmalion envelope. v1 cards
    /// don't carry `system_prompt`, `post_history_instructions`,
    /// `alternate_greetings`, or a `character_book`, so those land empty —
    /// the user can fill them in later via the creator. Phase 9 §5.2c:
    /// `mes_example` lands first-class in `Character.messageExample` (rather
    /// than being squashed into `description` as pre-§5.2c imports did).
    private static func mapV1(_ env: CardEnvelope) throws -> Character {
        guard let rawName = env.name?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawName.isEmpty else {
            throw ImportError.missingName
        }
        let description = env.description ?? ""
        if containsLegacyExamplePrefix(description) {
            DebugLog.shared.write(
                "importer: ⚠ legacy v1-squash separator detected in v1 description "
                + "(re-export from source tooling may help)"
            )
        }
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
            created: Date(),
            messageExample: env.mes_example ?? ""
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
