import Foundation
@testable import RPClientCore

/// Phase 9 §5.3c.1 — `Settings.customTags` + `TagVocabulary` union behavior.
/// Pure tests; the UI wiring (token-commit calls `TagVocabulary.addIfNovel`,
/// settings save) is exercised via smoke.
func phase9cTagsPersistTests() -> TestSuite {
    let s = TestSuite("Phase9cTagsPersist")

    // MARK: - Settings.customTags

    s.test("Settings.customTags defaults to empty on legacy decode") {
        let legacy = """
        {
            "servers": [{"id": "11111111-2222-3333-4444-555555555555", "name": "X", "baseURL": "http://localhost:5001"}],
            "defaultServerId": "11111111-2222-3333-4444-555555555555",
            "userName": "",
            "defaultTemplateId": "qwen3",
            "defaultSamplerPresetId": "default",
            "voiceEnabled": false,
            "voiceActive": true,
            "maxContextOverride": 0,
            "retrieval": {},
            "uiFontOffset": 0,
            "replyTokensOverride": 0,
            "factExtractionEnabled": false,
            "factExtractionEveryNTurns": 5,
            "priorityTopicLibrary": [],
            "qwenThinkingEnabled": false
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(Settings.self, from: legacy)
        try expectEqual(decoded.customTags, [])
    }

    s.test("Settings.customTags Codable round-trips") {
        var s1 = Settings.default
        s1.customTags = ["assistant", "rivalry", "courtroom"]
        let data = try JSONEncoder().encode(s1)
        let s2 = try JSONDecoder().decode(Settings.self, from: data)
        try expectEqual(s2.customTags, ["assistant", "rivalry", "courtroom"])
    }

    // MARK: - TagVocabulary.matches with custom tags

    s.test("matches returns union of bundled + custom") {
        let custom = ["bespoke-tag", "courtroom-drama"]
        let m = TagVocabulary.shared.matches(prefix: "bespoke", customTags: custom)
        try expectTrue(m.contains("bespoke-tag"))
    }

    s.test("matches still finds bundled tags when customTags is empty") {
        let m = TagVocabulary.shared.matches(prefix: "nsfw", customTags: [])
        try expectTrue(m.contains("nsfw"))
    }

    s.test("matches deduplicates a custom tag that already exists in bundled") {
        // "nsfw" is in the bundled list. Adding it to customTags shouldn't
        // produce two "nsfw" entries.
        let custom = ["nsfw"]
        let m = TagVocabulary.shared.matches(prefix: "nsfw", customTags: custom)
        try expectEqual(m.filter { $0 == "nsfw" }.count, 1)
    }

    s.test("matches is case-insensitive across custom tags") {
        let custom = ["Bespoke-Tag"]
        let m = TagVocabulary.shared.matches(prefix: "besp", customTags: custom)
        // Custom tags should be matched case-insensitively. The returned
        // form should be lowercased (canonical) so the autocomplete
        // doesn't display two case variants.
        try expectTrue(m.contains(where: { $0.lowercased() == "bespoke-tag" }))
    }

    s.test("matches caps results at 12 even when the union is large") {
        // Generate 20 custom tags all starting with "x".
        let custom = (0..<20).map { "x-tag-\($0)" }
        let m = TagVocabulary.shared.matches(prefix: "x", customTags: custom)
        try expectTrue(m.count <= 12)
    }

    // MARK: - TagVocabulary.addIfNovel

    s.test("addIfNovel returns nil for a tag already in bundled") {
        // "nsfw" lives in the bundled common-set.
        let result = TagVocabulary.shared.addIfNovel("nsfw", customTags: [])
        try expectTrue(result == nil)
    }

    s.test("addIfNovel returns nil for a tag already in custom") {
        let result = TagVocabulary.shared.addIfNovel("rivalry", customTags: ["rivalry"])
        try expectTrue(result == nil)
    }

    s.test("addIfNovel is case-insensitive when comparing against bundled") {
        // "NSFW" should not be added because "nsfw" is bundled.
        let result = TagVocabulary.shared.addIfNovel("NSFW", customTags: [])
        try expectTrue(result == nil)
    }

    s.test("addIfNovel is case-insensitive when comparing against custom") {
        let result = TagVocabulary.shared.addIfNovel("Rivalry", customTags: ["rivalry"])
        try expectTrue(result == nil)
    }

    s.test("addIfNovel returns updated list (lowercased) for a novel tag") {
        let result = try expectNotNil(
            TagVocabulary.shared.addIfNovel("Bespoke-Tag", customTags: ["existing"])
        )
        try expectEqual(result, ["existing", "bespoke-tag"])
    }

    s.test("addIfNovel trims whitespace before comparing and storing") {
        // A pasted tag with surrounding whitespace shouldn't add a duplicate
        // or store a leading-space entry.
        let result = try expectNotNil(
            TagVocabulary.shared.addIfNovel("  spaced-tag  ", customTags: [])
        )
        try expectEqual(result, ["spaced-tag"])
    }

    s.test("addIfNovel returns nil for whitespace-only or empty input") {
        try expectTrue(TagVocabulary.shared.addIfNovel("", customTags: []) == nil)
        try expectTrue(TagVocabulary.shared.addIfNovel("   ", customTags: []) == nil)
    }

    return s
}
