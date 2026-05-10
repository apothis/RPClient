import Foundation

/// Pure helpers for the Settings UI's Servers tab. Sit at the model layer so
/// the AppKit code in `SettingsWindowController` is glue and the editing
/// rules (delete-default-blocked, role-pointer cleanup on remove, URL
/// validation) are testable in isolation.
enum ServerEditing {
    static func canDeleteProfile(_ id: UUID, in settings: Settings) -> Bool {
        return id != settings.defaultServerId
    }

    static func rolesAssigned(to id: UUID, in settings: Settings) -> [ServerRole] {
        var out: [ServerRole] = []
        if settings.defaultServerId == id { out.append(.general) }
        if settings.summarizerServerId == id { out.append(.summarizer) }
        if settings.extractorServerId == id { out.append(.extractor) }
        if settings.embeddingsServerId == id { out.append(.embeddings) }
        return out
    }

    /// Set or clear a role's profile assignment. Special case: `.general` is
    /// `defaultServerId`, which can be re-pointed but never cleared (passing
    /// nil is a no-op for that role — there must always be a fallback).
    static func assignRole(_ role: ServerRole, to id: UUID?, in settings: inout Settings) {
        switch role {
        case .general:
            if let id = id { settings.defaultServerId = id }
        case .summarizer:
            settings.summarizerServerId = id
        case .extractor:
            settings.extractorServerId = id
        case .embeddings:
            settings.embeddingsServerId = id
        }
    }

    /// Drop a profile and clear any role overrides pointing at it. No-op when
    /// the target is the default profile (the UI also blocks that via
    /// `canDeleteProfile`, but the model layer refuses too — we'd otherwise
    /// leave settings without a fallback).
    static func removeProfile(_ id: UUID, from settings: inout Settings) {
        guard canDeleteProfile(id, in: settings) else { return }
        settings.servers.removeAll(where: { $0.id == id })
        if settings.summarizerServerId == id { settings.summarizerServerId = nil }
        if settings.extractorServerId == id { settings.extractorServerId = nil }
        if settings.embeddingsServerId == id { settings.embeddingsServerId = nil }
    }

    /// Lightweight URL validation for the Add/Edit form. Accepts only
    /// http/https and requires a host. Empty / scheme-less / file-scheme
    /// strings return nil so the UI can refuse to save them.
    static func validateBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        return url
    }
}
