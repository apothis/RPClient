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
        created: Date = Date()
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
    }
}
