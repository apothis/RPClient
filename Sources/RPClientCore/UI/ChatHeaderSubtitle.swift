import Foundation

/// V2_UI_OVERHAUL §4.2 / §4.f — pure-data resolver for the chat
/// header's `with <persona>` subhead. Returns `nil` when there's no
/// persona to surface so the caller can hide the subhead label
/// entirely (preserving the title's vertical centring in the 36pt
/// header).
///
/// Lifted out of the view so the (personaId × personas) → display
/// mapping is unit-testable without an NSWindow.
enum ChatHeaderSubtitle {
    static func resolve(personaId: UUID?, personas: [Persona]) -> String? {
        guard let pid = personaId else { return nil }
        guard let p = personas.first(where: { $0.id == pid }) else { return nil }
        let name = p.name.isEmpty ? "Unnamed" : p.name
        return "with \(name)"
    }
}
