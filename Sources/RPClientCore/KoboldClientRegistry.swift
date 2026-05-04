import Foundation

/// Owns one KoboldClient per ServerProfile and routes lookups by role.
///
/// Keeping a single client per profile preserves URLSession state and the
/// per-client token-count cache across lookups — important because side-call
/// callers and the chat generation path may resolve to the same client many
/// times per turn.
///
/// Thread model: settings updates happen on the main thread; client lookups
/// happen on the main thread today (AppState callsites). If that ever
/// changes, add a lock around `cache` and `current`.
final class KoboldClientRegistry {
    private var current: Settings
    private var cache: [UUID: KoboldClient] = [:]
    private let fallbackURL = URL(string: "http://localhost:5001")!

    init(settings: Settings) {
        self.current = settings
    }

    /// Refresh URLs of cached clients in place (preserving identity so token
    /// caches survive) and evict entries for profiles that have been removed.
    func updateSettings(_ s: Settings) {
        current = s
        let liveIds = Set(s.servers.map(\.id))
        for id in cache.keys where !liveIds.contains(id) {
            cache.removeValue(forKey: id)
        }
        for profile in s.servers {
            if let existing = cache[profile.id], existing.baseURL != profile.baseURL {
                existing.setBaseURL(profile.baseURL)
            }
        }
    }

    func client(for role: ServerRole, chatOverride: UUID?) -> KoboldClient {
        let profileId = resolveProfileId(role: role, chatOverride: chatOverride)
        if let id = profileId, let profile = current.servers.first(where: { $0.id == id }) {
            return cachedClient(for: profile)
        }
        // No usable profile (corrupt / empty state) — return a localhost client
        // so the network layer can fail gracefully instead of routing crashing.
        return cachedFallback()
    }

    private func resolveProfileId(role: ServerRole, chatOverride: UUID?) -> UUID? {
        let liveIds = Set(current.servers.map(\.id))
        let isLive: (UUID?) -> UUID? = { id in
            guard let id = id, liveIds.contains(id) else { return nil }
            return id
        }
        switch role {
        case .general:
            return isLive(chatOverride) ?? isLive(current.defaultServerId)
        case .summarizer:
            return isLive(current.summarizerServerId) ?? isLive(current.defaultServerId)
        case .extractor:
            return isLive(current.extractorServerId) ?? isLive(current.defaultServerId)
        case .embeddings:
            return isLive(current.embeddingsServerId) ?? isLive(current.defaultServerId)
        }
    }

    private func cachedClient(for profile: ServerProfile) -> KoboldClient {
        if let existing = cache[profile.id] {
            if existing.baseURL != profile.baseURL { existing.setBaseURL(profile.baseURL) }
            return existing
        }
        let c = KoboldClient(baseURL: profile.baseURL)
        cache[profile.id] = c
        return c
    }

    /// Sentinel client used when settings are corrupt (no live default).
    /// Stored under a stable nil-UUID key so repeated calls return the same
    /// instance rather than minting a new client per lookup.
    private static let fallbackKey = UUID(uuid: (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0))
    private func cachedFallback() -> KoboldClient {
        if let existing = cache[Self.fallbackKey] { return existing }
        let c = KoboldClient(baseURL: fallbackURL)
        cache[Self.fallbackKey] = c
        return c
    }
}
