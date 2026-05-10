import Foundation

enum EntityType: String, Codable, CaseIterable, Equatable {
    case character
    case location
    case item
    case relationship
    case event

    var label: String {
        switch self {
        case .character: return "Character"
        case .location: return "Location"
        case .item: return "Item"
        case .relationship: return "Relationship"
        case .event: return "Event"
        }
    }
}

/// Structured per-chat entity store. Replaces the flat `chat.memory` string as
/// the primary home for long-term facts. Selective injection (`entitiesBlock`
/// in PromptBuilder) only emits entities mentioned in recent turns, so memory
/// stops being budget-bound. See MEMORY_V2_PLAN.md "Step C — Entity store".
struct Entity: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var aliases: [String]
    var type: EntityType
    var facts: [Fact]
    /// True when the user manually created or edited this entity. Pinned
    /// entities are never auto-merged or auto-evicted; reserved as a no-op
    /// today but read by Step D salience.
    var pinnedByUser: Bool
    var createdTurn: Int
    /// Per-character voice. `nil` falls back to the chat-default voice.
    /// Phase 6 §7.2 — additive Codable: pre-§7.2 entities decode with nil.
    var voice: VoicePreference?

    init(
        id: UUID = UUID(),
        name: String,
        aliases: [String] = [],
        type: EntityType,
        facts: [Fact] = [],
        pinnedByUser: Bool = false,
        createdTurn: Int = 0,
        voice: VoicePreference? = nil
    ) {
        self.id = id
        self.name = name
        self.aliases = aliases
        self.type = type
        self.facts = facts
        self.pinnedByUser = pinnedByUser
        self.createdTurn = createdTurn
        self.voice = voice
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        aliases = try c.decodeIfPresent([String].self, forKey: .aliases) ?? []
        type = try c.decodeIfPresent(EntityType.self, forKey: .type) ?? .event
        facts = try c.decodeIfPresent([Fact].self, forKey: .facts) ?? []
        pinnedByUser = try c.decodeIfPresent(Bool.self, forKey: .pinnedByUser) ?? false
        createdTurn = try c.decodeIfPresent(Int.self, forKey: .createdTurn) ?? 0
        voice = try c.decodeIfPresent(VoicePreference.self, forKey: .voice)
    }

    /// Case-insensitive name + alias match against arbitrary text. Used by the
    /// prompt-builder to decide which entities are "on-stage" right now.
    func mentioned(in lowerText: String) -> Bool {
        let candidates = ([name] + aliases)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        for c in candidates where lowerText.contains(c) {
            return true
        }
        return false
    }
}
