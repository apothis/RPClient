import AppKit
import Foundation
@testable import RPClientCore

/// Phase 11 §4.c — pure resolution rule for the user-turn caption
/// shown above the subtle bubble. The resolution falls back through:
///
///   1. The chat's persona name (from `Chat.personaId` → Persona.name)
///   2. The settings-level userName (legacy single-user mode)
///   3. "You" (anonymous chats with no settings name set)
///
/// Empty strings count as nil so the fallback chain trips correctly
/// when the persona has been created but never named.
func phase11UserDisplayNameTests() -> TestSuite {
    let s = TestSuite("Phase11UserDisplayName")

    s.test("persona name wins when present") {
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: "Kevin", settingsUserName: "Kev"),
            "Kevin"
        )
    }

    s.test("falls back to settings userName when persona is nil") {
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: nil, settingsUserName: "Kev"),
            "Kev"
        )
    }

    s.test("falls back to settings userName when persona is empty") {
        // Empty-string personas are common — Persona() initializes name=""
        // and the user might create one via the library window without
        // ever naming it.
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: "", settingsUserName: "Kev"),
            "Kev"
        )
    }

    s.test("falls back to 'You' when both are empty") {
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: nil, settingsUserName: ""),
            "You"
        )
    }

    s.test("falls back to 'You' when both are empty strings") {
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: "", settingsUserName: ""),
            "You"
        )
    }

    s.test("trims whitespace before deciding emptiness") {
        // "   " is not a meaningful name; treat as empty so we don't
        // render a blank caption above the bubble.
        try expectEqual(
            TurnView.userTurnDisplayName(personaName: "   ", settingsUserName: "Kev"),
            "Kev"
        )
    }

    return s
}
