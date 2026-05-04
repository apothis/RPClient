import Foundation

/// Pure helpers for the per-chat server picker (Phase 4 §5.4). Sit at the
/// model layer so the AppKit popup wiring is glue and the index ↔ profile id
/// mapping is testable in isolation.
///
/// The popup's index 0 is the "(use default)" sentinel; profiles fill 1..n.
/// `selectedIndex` and `idAtIndex` invert each other.
enum ChatServerPicker {
    static func selectedIndex(chatServerId: UUID?, settings: Settings) -> Int {
        guard let id = chatServerId,
              let i = settings.servers.firstIndex(where: { $0.id == id }) else {
            return 0
        }
        return i + 1
    }

    static func idAtIndex(_ index: Int, settings: Settings) -> UUID? {
        guard index > 0, index - 1 < settings.servers.count else { return nil }
        return settings.servers[index - 1].id
    }

    static func displayLabel(chatServerId: UUID?, settings: Settings) -> String {
        guard let id = chatServerId,
              let p = settings.servers.first(where: { $0.id == id }) else {
            return "(use default)"
        }
        return p.name.isEmpty ? "(unnamed)" : p.name
    }
}
