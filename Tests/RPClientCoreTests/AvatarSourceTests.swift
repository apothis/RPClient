import AppKit
import Foundation
@testable import RPClientCore

/// Tests for `AvatarSource` — the resolver that turns a character/persona id
/// into a renderable `NSImage` (real avatar or initials placeholder), backed
/// by an in-memory cache that drops on the appropriate library-changed
/// notification.
///
/// Each test uses a fresh UUID so we don't collide on `Storage.shared`'s
/// real avatar directory; the on-disk PNG is cleaned up at the end of the
/// test that wrote it.
func avatarSourceTests() -> TestSuite {
    let s = TestSuite("AvatarSource")

    s.test("character with avatar on disk loads from disk and caches") {
        let id = UUID()
        let png = makeAvatarPNG(side: 64)
        Storage.shared.writeCharacterAvatar(png, for: id)
        defer { Storage.shared.deleteCharacter(id: id) }

        let src = AvatarSource()
        let img = src.image(forCharacter: id, name: "Nyx")
        try expectGreaterThan(img.size.width, 0)

        let cached = try expectNotNil(src.cachedImage(forCharacter: id))
        try expectTrue(cached === img, "second lookup returns the same NSImage instance from cache")
    }

    s.test("character without avatar returns initials placeholder, also cached") {
        let id = UUID() // no avatar written
        let src = AvatarSource()
        let img = src.image(forCharacter: id, name: "Marin Vale")
        try expectGreaterThan(img.size.width, 0)

        let cached = try expectNotNil(src.cachedImage(forCharacter: id))
        try expectTrue(cached === img)
    }

    s.test("charactersChanged notification clears character cache") {
        let id = UUID()
        let src = AvatarSource()
        _ = src.image(forCharacter: id, name: "Nyx")
        _ = try expectNotNil(src.cachedImage(forCharacter: id))

        NotificationCenter.default.post(name: AppNotification.charactersChanged, object: nil)
        try expectNil(src.cachedImage(forCharacter: id))
    }

    s.test("personasChanged notification clears persona cache but not character cache") {
        let charId = UUID()
        let perId = UUID()
        let src = AvatarSource()
        _ = src.image(forCharacter: charId, name: "Nyx")
        _ = src.image(forPersona: perId, name: "Kira")
        _ = try expectNotNil(src.cachedImage(forCharacter: charId))
        _ = try expectNotNil(src.cachedImage(forPersona: perId))

        NotificationCenter.default.post(name: AppNotification.personasChanged, object: nil)
        // Character cache survives a persona-library change.
        _ = try expectNotNil(src.cachedImage(forCharacter: charId))
        // Persona cache cleared on personasChanged.
        try expectNil(src.cachedImage(forPersona: perId))
    }

    s.test("persona with avatar on disk loads from disk") {
        let id = UUID()
        let png = makeAvatarPNG(side: 64)
        Storage.shared.writePersonaAvatar(png, for: id)
        defer { Storage.shared.deletePersona(id: id) }

        let src = AvatarSource()
        let img = src.image(forPersona: id, name: "Kira")
        try expectGreaterThan(img.size.width, 0)
        _ = try expectNotNil(src.cachedImage(forPersona: id))
    }

    return s
}

/// Solid-colour PNG of the given side. Mirrors the helper in
/// CharacterPersonaTests (kept private there) — duplicated here rather than
/// exposed because the two test files are independent and tiny.
private func makeAvatarPNG(side: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: side,
        pixelsHigh: side,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    )!
    rep.size = NSSize(width: side, height: side)
    NSGraphicsContext.saveGraphicsState()
    let ctx = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = ctx
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    ctx.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}
