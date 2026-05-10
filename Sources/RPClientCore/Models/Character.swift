import Foundation

/// AI-side persona — what the model is roleplaying. V2 §4. Field shape mirrors
/// SillyTavern character card v2 (`chara_card_v2`) so importer round-trips
/// don't lose data: `description + personality + scenario` form the read-only
/// memory prefix, `firstMessage` becomes the seeded assistant turn,
/// `alternateGreetings` are exposed as Phase-2 variants on that turn,
/// `systemPrompt` overrides chat memory at the top of the prompt, and
/// `postHistoryInstructions` injects as the author's note.
///
/// `charBook` is the card's bundled lorebook ("character book" in ST), merged
/// into chat-level world info on first use. Tags + creator + characterVersion
/// are display-only — they help the user identify cards in the library but
/// don't reach the prompt. Avatar lives at
/// `characters/avatars/<id>.png`; the path is derived by `Storage`.
struct Character: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    var personality: String
    var scenario: String
    var firstMessage: String
    var alternateGreetings: [String]
    var systemPrompt: String?
    var postHistoryInstructions: String?
    var tags: [String]
    var creator: String?
    var characterVersion: String?
    var charBook: [WorldInfoEntry]
    var created: Date

    // MARK: - Phase 9 §5.2a — v2-mappable additions

    /// V2/V3 spec field. Restored as first-class — pre-Phase-9 v1 imports
    /// folded `mes_example` into `description` with an `Example dialogue:\n`
    /// prefix; that path is removed in §5.2c. Round-trips to `data.mes_example`
    /// on v2/v3 export.
    var messageExample: String

    /// V2 spec field. Display-only — never reaches the prompt. NSFW authors
    /// use this for content rating, trigger warnings, and kink list (chub.ai
    /// convention). Round-trips to `data.creator_notes`.
    var creatorNotes: String?

    /// V2 + V3 passthrough for arbitrary application-specific data. The spec
    /// mandates editors preserve unknown keys verbatim; this slot is the
    /// vehicle. Includes the community `depth_prompt` convention (surfaced
    /// as a first-class control in the creator UI but stored here for
    /// spec-compliance) and namespaced sub-blobs from other clients
    /// (`agnai/voice`, `risuai`, RPClient's own `rpclient`).
    var extensions: [String: JSONValue]?

    // MARK: - Phase 9 §5.2b — v3 opt-in additions

    /// V3 spec field. Replaces `{{char}}` if non-nil; falls back to `name`.
    /// Useful when an in-fiction nickname differs from the card's index name.
    var nickname: String?

    /// V3 spec field. Greetings used only on group-chat seeding (§4 cast-add
    /// path). Empty array on solo cards.
    var groupOnlyGreetings: [String]

    /// V3 spec field. Provenance: URLs or external IDs. Read-only on import,
    /// append-only on edit per the spec.
    var source: [String]

    /// V3 spec field. Language-keyed creator notes (ISO 639-1 keys); the `en`
    /// entry is expected to mirror `creatorNotes` when both are populated.
    var creatorNotesMultilingual: [String: String]?

    /// V3 spec field. Application-set; user is not expected to edit.
    var creationDate: Date?

    /// V3 spec field. Updated on export. Application-set; user is not expected
    /// to edit.
    var modificationDate: Date?

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        personality: String = "",
        scenario: String = "",
        firstMessage: String = "",
        alternateGreetings: [String] = [],
        systemPrompt: String? = nil,
        postHistoryInstructions: String? = nil,
        tags: [String] = [],
        creator: String? = nil,
        characterVersion: String? = nil,
        charBook: [WorldInfoEntry] = [],
        created: Date = Date(),
        messageExample: String = "",
        creatorNotes: String? = nil,
        extensions: [String: JSONValue]? = nil,
        nickname: String? = nil,
        groupOnlyGreetings: [String] = [],
        source: [String] = [],
        creatorNotesMultilingual: [String: String]? = nil,
        creationDate: Date? = nil,
        modificationDate: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.personality = personality
        self.scenario = scenario
        self.firstMessage = firstMessage
        self.alternateGreetings = alternateGreetings
        self.systemPrompt = systemPrompt
        self.postHistoryInstructions = postHistoryInstructions
        self.tags = tags
        self.creator = creator
        self.characterVersion = characterVersion
        self.charBook = charBook
        self.created = created
        self.messageExample = messageExample
        self.creatorNotes = creatorNotes
        self.extensions = extensions
        self.nickname = nickname
        self.groupOnlyGreetings = groupOnlyGreetings
        self.source = source
        self.creatorNotesMultilingual = creatorNotesMultilingual
        self.creationDate = creationDate
        self.modificationDate = modificationDate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        personality = try c.decodeIfPresent(String.self, forKey: .personality) ?? ""
        scenario = try c.decodeIfPresent(String.self, forKey: .scenario) ?? ""
        firstMessage = try c.decodeIfPresent(String.self, forKey: .firstMessage) ?? ""
        alternateGreetings = try c.decodeIfPresent([String].self, forKey: .alternateGreetings) ?? []
        systemPrompt = try c.decodeIfPresent(String.self, forKey: .systemPrompt)
        postHistoryInstructions = try c.decodeIfPresent(String.self, forKey: .postHistoryInstructions)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        creator = try c.decodeIfPresent(String.self, forKey: .creator)
        characterVersion = try c.decodeIfPresent(String.self, forKey: .characterVersion)
        charBook = try c.decodeIfPresent([WorldInfoEntry].self, forKey: .charBook) ?? []
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        messageExample = try c.decodeIfPresent(String.self, forKey: .messageExample) ?? ""
        creatorNotes = try c.decodeIfPresent(String.self, forKey: .creatorNotes)
        extensions = try c.decodeIfPresent([String: JSONValue].self, forKey: .extensions)
        nickname = try c.decodeIfPresent(String.self, forKey: .nickname)
        groupOnlyGreetings = try c.decodeIfPresent([String].self, forKey: .groupOnlyGreetings) ?? []
        source = try c.decodeIfPresent([String].self, forKey: .source) ?? []
        creatorNotesMultilingual = try c.decodeIfPresent([String: String].self, forKey: .creatorNotesMultilingual)
        creationDate = try c.decodeIfPresent(Date.self, forKey: .creationDate)
        modificationDate = try c.decodeIfPresent(Date.self, forKey: .modificationDate)
    }
}
