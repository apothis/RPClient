import Foundation

/// User-side identity injected into the prompt so the model knows who the
/// user is roleplaying as. V2 §4 — owned by the persona library and
/// referenced from `Chat.personaId`. The `description` is the load-bearing
/// field; everything else is metadata for the library UI.
///
/// Avatars live next to the JSON in `personas/avatars/<id>.png`. The path is
/// not stored on the model — `Storage` derives it from the id so an
/// imported persona JSON without an accompanying avatar still loads cleanly.
struct Persona: Codable, Equatable, Identifiable {
    let id: UUID
    var name: String
    var description: String
    var created: Date

    init(
        id: UUID = UUID(),
        name: String = "",
        description: String = "",
        created: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.created = created
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        description = try c.decodeIfPresent(String.self, forKey: .description) ?? ""
        created = try c.decodeIfPresent(Date.self, forKey: .created) ?? Date()
    }
}
