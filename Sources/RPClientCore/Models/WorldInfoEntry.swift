import Foundation

enum WorldInfoInjectionMode: String, Codable, CaseIterable, Equatable {
    case keyword
    case always
    case vectorized

    var label: String {
        switch self {
        case .keyword: return "Keyword"
        case .always: return "Always"
        case .vectorized: return "Vectorized"
        }
    }
}

/// Where in the conversation an entry's keys are searched for. Vectorized
/// mode ignores scope (matches against the chunk store) but the field is
/// still kept for forward-compat.
enum WorldInfoMatchScope: Codable, Equatable {
    case recentTurns(Int)
    case lastUserTurn
    case entireChat

    private enum Kind: String, Codable {
        case recentTurns, lastUserTurn, entireChat
    }
    private enum CodingKeys: String, CodingKey { case kind, n }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(Kind.self, forKey: .kind)
        switch kind {
        case .recentTurns:
            let n = try c.decodeIfPresent(Int.self, forKey: .n) ?? 4
            self = .recentTurns(n)
        case .lastUserTurn:
            self = .lastUserTurn
        case .entireChat:
            self = .entireChat
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .recentTurns(let n):
            try c.encode(Kind.recentTurns, forKey: .kind)
            try c.encode(n, forKey: .n)
        case .lastUserTurn:
            try c.encode(Kind.lastUserTurn, forKey: .kind)
        case .entireChat:
            try c.encode(Kind.entireChat, forKey: .kind)
        }
    }
}

struct WorldInfoEntry: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var keys: [String]
    /// Optional AND-gate: entry fires only if a primary key AND a secondary key both match.
    var secondaryKeys: [String]
    var content: String
    var tokenCap: Int
    var enabled: Bool
    var injectionMode: WorldInfoInjectionMode
    var matchScope: WorldInfoMatchScope
    /// Tiebreak when the total token cap is exceeded — higher priority wins.
    var priority: Int

    init(
        id: UUID = UUID(),
        name: String = "",
        keys: [String] = [],
        secondaryKeys: [String] = [],
        content: String = "",
        tokenCap: Int = 256,
        enabled: Bool = true,
        injectionMode: WorldInfoInjectionMode = .keyword,
        matchScope: WorldInfoMatchScope = .recentTurns(4),
        priority: Int = 0
    ) {
        self.id = id
        self.name = name.isEmpty ? (keys.first ?? "Untitled") : name
        self.keys = keys
        self.secondaryKeys = secondaryKeys
        self.content = content
        self.tokenCap = tokenCap
        self.enabled = enabled
        self.injectionMode = injectionMode
        self.matchScope = matchScope
        self.priority = priority
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        keys = try c.decodeIfPresent([String].self, forKey: .keys) ?? []
        let decodedName = try c.decodeIfPresent(String.self, forKey: .name)
        if let decodedName, !decodedName.isEmpty {
            name = decodedName
        } else {
            name = keys.first ?? "Untitled"
        }
        secondaryKeys = try c.decodeIfPresent([String].self, forKey: .secondaryKeys) ?? []
        content = try c.decodeIfPresent(String.self, forKey: .content) ?? ""
        tokenCap = try c.decodeIfPresent(Int.self, forKey: .tokenCap) ?? 256
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        injectionMode = try c.decodeIfPresent(WorldInfoInjectionMode.self, forKey: .injectionMode) ?? .keyword
        matchScope = try c.decodeIfPresent(WorldInfoMatchScope.self, forKey: .matchScope) ?? .recentTurns(4)
        priority = try c.decodeIfPresent(Int.self, forKey: .priority) ?? 0
    }
}
