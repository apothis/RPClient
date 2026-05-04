import Foundation

enum TurnRole: String, Codable {
    case user
    case assistant
}

struct Turn: Codable, Identifiable, Equatable {
    let id: UUID
    var role: TurnRole
    var text: String
    var edited: Bool
    var ts: Date

    init(id: UUID = UUID(), role: TurnRole, text: String, edited: Bool = false, ts: Date = Date()) {
        self.id = id
        self.role = role
        self.text = text
        self.edited = edited
        self.ts = ts
    }
}
