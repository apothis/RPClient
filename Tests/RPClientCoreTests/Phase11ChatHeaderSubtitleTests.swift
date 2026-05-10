import Foundation
@testable import RPClientCore

/// V2_UI_OVERHAUL §4.f — chat header `with <persona>` subhead
/// resolver. Pure-data mapping from (Chat.personaId, AppState.personas)
/// to a display string (or nil to hide the subhead).
func phase11ChatHeaderSubtitleTests() -> TestSuite {
    let s = TestSuite("Phase11ChatHeaderSubtitle")

    let alice = Persona(id: UUID(), name: "Alice", description: "A")
    let unnamed = Persona(id: UUID(), name: "", description: "B")

    s.test("nil personaId returns nil so subhead hides") {
        try expectNil(ChatHeaderSubtitle.resolve(personaId: nil, personas: [alice]))
        try expectNil(ChatHeaderSubtitle.resolve(personaId: nil, personas: []))
    }

    s.test("matching personaId yields 'with <name>'") {
        try expectEqual(
            ChatHeaderSubtitle.resolve(personaId: alice.id, personas: [alice]),
            "with Alice"
        )
    }

    s.test("stale personaId (deleted persona) returns nil") {
        // Defensive: a chat references a persona that's since been
        // removed from the library — surface no subhead rather than
        // crashing or showing 'with ?'.
        try expectNil(
            ChatHeaderSubtitle.resolve(personaId: UUID(), personas: [alice])
        )
    }

    s.test("matching but empty-name persona yields 'with Unnamed'") {
        try expectEqual(
            ChatHeaderSubtitle.resolve(personaId: unnamed.id, personas: [unnamed]),
            "with Unnamed"
        )
    }

    return s
}
