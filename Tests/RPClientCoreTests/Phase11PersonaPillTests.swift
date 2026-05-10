import Foundation
@testable import RPClientCore

/// V2_UI_OVERHAUL §4.g.4 — composer persona pill. Pure-data title
/// resolver. The pill itself is a UI control; this exercises the
/// (chat.personaId, AppState.personas) → display-string mapping that
/// drives `button.title`.
func phase11PersonaPillTests() -> TestSuite {
    let s = TestSuite("Phase11PersonaPill")

    let alice = Persona(id: UUID(), name: "Alice", description: "Curious")
    let bob = Persona(id: UUID(), name: "Bob", description: "")
    let unnamed = Persona(id: UUID(), name: "", description: "Has no name")

    s.test("nil personaId resolves to 'None' regardless of list") {
        try expectEqual(
            PersonaPillTitle.resolve(personaId: nil, personas: []),
            "None"
        )
        try expectEqual(
            PersonaPillTitle.resolve(personaId: nil, personas: [alice, bob]),
            "None"
        )
    }

    s.test("personaId matching a persona returns that name") {
        try expectEqual(
            PersonaPillTitle.resolve(personaId: alice.id, personas: [alice, bob]),
            "Alice"
        )
        try expectEqual(
            PersonaPillTitle.resolve(personaId: bob.id, personas: [alice, bob]),
            "Bob"
        )
    }

    s.test("personaId with no matching persona resolves to 'None'") {
        // Stale id (persona was deleted) — should not crash, just
        // surface the same 'None' face the user sees for nil.
        try expectEqual(
            PersonaPillTitle.resolve(personaId: UUID(), personas: [alice, bob]),
            "None"
        )
    }

    s.test("matching but empty-name persona resolves to 'Unnamed'") {
        try expectEqual(
            PersonaPillTitle.resolve(personaId: unnamed.id, personas: [unnamed]),
            "Unnamed"
        )
    }

    return s
}
