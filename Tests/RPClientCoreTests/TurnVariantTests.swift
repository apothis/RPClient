import Foundation
@testable import RPClientCore

func turnVariantTests() -> TestSuite {
    let s = TestSuite("TurnVariant")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    s.test("assistant turn with seed text gets one variant") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        let t = Turn(role: .assistant, text: "hello there", ts: stamp)
        try expectEqual(t.variants.count, 1)
        try expectEqual(t.variants[0].text, "hello there")
        try expectEqual(t.activeVariant, 0)
        try expectEqual(t.text, "hello there")
    }

    s.test("user turn never has variants") {
        let t = Turn(role: .user, text: "hi")
        try expectTrue(t.variants.isEmpty)
        try expectEqual(t.activeVariant, 0)
    }

    s.test("empty assistant placeholder has no variants") {
        let t = Turn(role: .assistant, text: "")
        try expectTrue(t.variants.isEmpty)
    }

    s.test("appendToActiveVariant seeds a variant on first token") {
        var t = Turn(role: .assistant, text: "")
        t.appendToActiveVariant("Once")
        t.appendToActiveVariant(" upon a time")
        try expectEqual(t.variants.count, 1)
        try expectEqual(t.variants[0].text, "Once upon a time")
        try expectEqual(t.text, "Once upon a time")
    }

    s.test("setActiveVariantText mirrors and marks edited") {
        var t = Turn(role: .assistant, text: "draft")
        t.setActiveVariantText("revised")
        try expectEqual(t.text, "revised")
        try expectEqual(t.variants[0].text, "revised")
        try expectTrue(t.edited)
        try expectTrue(t.variants[0].edited)
    }

    s.test("addEmptyVariant moves active forward and clears text") {
        var t = Turn(role: .assistant, text: "v0")
        t.addEmptyVariant()
        try expectEqual(t.variants.count, 2)
        try expectEqual(t.activeVariant, 1)
        try expectEqual(t.text, "")
        try expectEqual(t.variants[0].text, "v0", "previous variant must be preserved")
    }

    s.test("setActiveIndex switches and mirrors text") {
        var t = Turn(role: .assistant, text: "v0")
        t.addEmptyVariant()
        t.appendToActiveVariant("v1 body")
        try expectEqual(t.text, "v1 body")
        t.setActiveIndex(0)
        try expectEqual(t.text, "v0")
        try expectEqual(t.activeVariant, 0)
        // Out-of-range is a no-op.
        t.setActiveIndex(99)
        try expectEqual(t.activeVariant, 0)
    }

    s.test("codable round-trip preserves variants and active index") {
        // Both the turn and the manually-constructed second variant pin their
        // timestamps to a whole-second value so the iso8601 encoder
        // (whole-second precision) round-trips exactly.
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var t = Turn(role: .assistant, text: "v0", ts: stamp)
        // Construct the second variant directly so we can pin its timestamp
        // — `addEmptyVariant` defaults to Date() which has subsecond drift.
        t.variants.append(TurnVariant(text: "v1 reply", ts: stamp, samplerPresetId: "balanced"))
        t.activeVariant = 1
        t.text = "v1 reply"
        let data = try encoder.encode(t)
        let decoded = try decoder.decode(Turn.self, from: data)
        try expectEqual(decoded, t)
        try expectEqual(decoded.variants.count, 2)
        try expectEqual(decoded.activeVariant, 1)
        try expectEqual(decoded.variants[1].samplerPresetId, "balanced")
    }

    s.test("legacy assistant turn (no variants field) synthesises one variant on decode") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "role": "assistant",
            "text": "legacy reply",
            "edited": false,
            "ts": "\(now)"
        }
        """
        let t = try decoder.decode(Turn.self, from: Data(json.utf8))
        try expectEqual(t.variants.count, 1)
        try expectEqual(t.variants[0].text, "legacy reply")
        try expectEqual(t.activeVariant, 0)
    }

    s.test("legacy user turn decodes with no variants") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "role": "user",
            "text": "hi",
            "edited": false,
            "ts": "\(now)"
        }
        """
        let t = try decoder.decode(Turn.self, from: Data(json.utf8))
        try expectTrue(t.variants.isEmpty)
        try expectEqual(t.activeVariant, 0)
    }

    s.test("decode clamps out-of-range activeVariant") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString
        let vid = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "role": "assistant",
            "text": "v0",
            "edited": false,
            "ts": "\(now)",
            "variants": [
                {"id": "\(vid)", "text": "v0", "edited": false, "ts": "\(now)"}
            ],
            "activeVariant": 7
        }
        """
        let t = try decoder.decode(Turn.self, from: Data(json.utf8))
        try expectEqual(t.activeVariant, 0, "out-of-range index must clamp into [0, variants.count - 1]")
    }

    s.test("regen-as-variant flow preserves prior variant and streams into the new one") {
        // Mirrors what AppState.regenerate now does: take a finished assistant
        // turn, append an empty variant, then drive stream tokens through
        // appendToActiveVariant. The original variant must survive untouched
        // and be reachable via setActiveIndex(0).
        var t = Turn(role: .assistant, text: "first reply")
        t.addEmptyVariant(samplerPresetId: "creative")
        for tok in ["Sec", "ond ", "reply"] {
            t.appendToActiveVariant(tok)
        }
        try expectEqual(t.variants.count, 2)
        try expectEqual(t.activeVariant, 1)
        try expectEqual(t.text, "Second reply")
        try expectEqual(t.variants[0].text, "first reply")
        try expectEqual(t.variants[1].samplerPresetId, "creative")
        // Page back to the original.
        t.setActiveIndex(0)
        try expectEqual(t.text, "first reply")
        try expectEqual(t.activeVariant, 0)
    }

    s.test("edit on a non-active variant does not bleed into the active text") {
        // Editing an assistant turn while v1 is active must update v1's text
        // and the mirrored `text`. v0 is left alone.
        var t = Turn(role: .assistant, text: "v0 body")
        t.addEmptyVariant()
        t.appendToActiveVariant("v1 body")
        t.setActiveVariantText("v1 body, edited")
        try expectEqual(t.text, "v1 body, edited")
        try expectEqual(t.variants[1].text, "v1 body, edited")
        try expectTrue(t.variants[1].edited)
        try expectEqual(t.variants[0].text, "v0 body")
        try expectFalse(t.variants[0].edited, "edits on the active variant must not touch the inactive one")
    }

    s.test("legacy assistant placeholder (empty text, no variants) stays empty") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id = UUID().uuidString
        let json = """
        {
            "id": "\(id)",
            "role": "assistant",
            "text": "",
            "edited": false,
            "ts": "\(now)"
        }
        """
        let t = try decoder.decode(Turn.self, from: Data(json.utf8))
        try expectTrue(t.variants.isEmpty, "no synthesis when there's no text to seed from")
    }

    return s
}
