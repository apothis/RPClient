import AppKit
import Foundation

/// Resolver from character/persona id → renderable `NSImage`. Reads the on-disk
/// avatar via `Storage` once, falls back to an initials placeholder when the
/// PNG is missing, and caches the result so the sidebar (which reloads on
/// every `chatListChanged` / `chatUpdated` / `statusChanged` tick) doesn't
/// re-decode the same PNGs on every redraw.
///
/// V2_PLAN §6 — Phase 5 step 5a. Sidebar (5b) and TurnView (5c) both consume
/// `AvatarSource.shared`; tests construct their own instance to keep cache
/// state isolated between cases.
final class AvatarSource {
    static let shared = AvatarSource()

    /// Plain dictionaries rather than NSCache — avatar count is bounded by
    /// the user's character + persona libraries (tens, not thousands), and a
    /// dictionary makes cache-state observable from tests without exposing
    /// NSCache internals.
    private var characterCache: [UUID: NSImage] = [:]
    private var personaCache: [UUID: NSImage] = [:]

    init() {
        let nc = NotificationCenter.default
        nc.addObserver(self,
            selector: #selector(invalidateCharacters),
            name: AppNotification.charactersChanged, object: nil)
        nc.addObserver(self,
            selector: #selector(invalidatePersonas),
            name: AppNotification.personasChanged, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    /// Returns the avatar image for `id`, falling back to an initials
    /// placeholder rendered from `name` when no PNG is on disk. Caches both
    /// the loaded and the placeholder result so a missing avatar doesn't
    /// repeatedly re-render the same placeholder bitmap.
    func image(forCharacter id: UUID, name: String) -> NSImage {
        if let cached = characterCache[id] { return cached }
        let img = loadOrPlaceholder(
            data: Storage.shared.loadCharacterAvatar(id: id),
            initials: name)
        characterCache[id] = img
        return img
    }

    /// Same as `image(forCharacter:name:)` for personas.
    func image(forPersona id: UUID, name: String) -> NSImage {
        if let cached = personaCache[id] { return cached }
        let img = loadOrPlaceholder(
            data: Storage.shared.loadPersonaAvatar(id: id),
            initials: name)
        personaCache[id] = img
        return img
    }

    /// Cache peek — returns nil when no resolution has been done yet for
    /// this id, or after the corresponding library-changed notification
    /// has cleared the cache. Test seam.
    func cachedImage(forCharacter id: UUID) -> NSImage? {
        characterCache[id]
    }

    /// Cache peek for personas. See `cachedImage(forCharacter:)`.
    func cachedImage(forPersona id: UUID) -> NSImage? {
        personaCache[id]
    }

    private func loadOrPlaceholder(data: Data?, initials: String) -> NSImage {
        if let data, let img = NSImage(data: data) {
            return img
        }
        return placeholderAvatar(initials: initials)
    }

    @objc private func invalidateCharacters() {
        characterCache.removeAll()
    }

    @objc private func invalidatePersonas() {
        personaCache.removeAll()
    }
}
