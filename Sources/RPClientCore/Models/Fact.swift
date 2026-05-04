import Foundation

/// One atomic fact attached to an Entity. The `lastReinforcedTurn` /
/// `mentionCount` fields exist for Step D salience scoring; they're populated
/// here so the schema stays stable across the C/D split.
struct Fact: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var addedTurn: Int
    var lastReinforcedTurn: Int
    /// Total times this fact's parent entity has been mentioned since the
    /// fact was added. Bumped by the entity-mention scan after each turn.
    var mentionCount: Int
    /// If non-nil, the id of an earlier fact this one replaces. Lets the UI
    /// show edit history without losing the prior text immediately.
    var supersedesFactId: UUID?
    /// User has explicitly pinned this fact — never evict during budget
    /// pressure. Reserved for Step D; today only the EntitiesPane writes it.
    var pinnedByUser: Bool

    init(
        id: UUID = UUID(),
        text: String,
        addedTurn: Int = 0,
        lastReinforcedTurn: Int = 0,
        mentionCount: Int = 0,
        supersedesFactId: UUID? = nil,
        pinnedByUser: Bool = false
    ) {
        self.id = id
        self.text = text
        self.addedTurn = addedTurn
        self.lastReinforcedTurn = lastReinforcedTurn
        self.mentionCount = mentionCount
        self.supersedesFactId = supersedesFactId
        self.pinnedByUser = pinnedByUser
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        text = try c.decode(String.self, forKey: .text)
        addedTurn = try c.decodeIfPresent(Int.self, forKey: .addedTurn) ?? 0
        lastReinforcedTurn = try c.decodeIfPresent(Int.self, forKey: .lastReinforcedTurn) ?? 0
        mentionCount = try c.decodeIfPresent(Int.self, forKey: .mentionCount) ?? 0
        supersedesFactId = try c.decodeIfPresent(UUID.self, forKey: .supersedesFactId)
        pinnedByUser = try c.decodeIfPresent(Bool.self, forKey: .pinnedByUser) ?? false
    }
}
