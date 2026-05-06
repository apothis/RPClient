import Foundation
@testable import RPClientCore

func phase9CharacterTests() -> TestSuite {
    let s = TestSuite("Phase9Character")

    // MARK: - JSONValue

    s.test("JSONValue round-trips primitives") {
        let cases: [JSONValue] = [
            .null,
            .bool(true),
            .bool(false),
            .int(0),
            .int(42),
            .int(-7),
            .double(3.14),
            .string(""),
            .string("hello"),
        ]
        for v in cases {
            let encoded = try JSONEncoder().encode(v)
            let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
            try expectEqual(decoded, v)
        }
    }

    s.test("JSONValue preserves int vs double on round-trip") {
        let i = JSONValue.int(42)
        let d = JSONValue.double(42.0)
        let iEnc = try JSONEncoder().encode(i)
        let dEnc = try JSONEncoder().encode(d)
        // 42 (no decimal) for int; either is acceptable for double, just don't
        // get back .int when we wrote .double.
        try expectEqual(String(data: iEnc, encoding: .utf8), "42")
        let iDec = try JSONDecoder().decode(JSONValue.self, from: iEnc)
        let dDec = try JSONDecoder().decode(JSONValue.self, from: dEnc)
        try expectEqual(iDec, .int(42))
        // double 42.0 may decode as int (Swift's JSONSerialization collapses
        // .0 numerics to integer-shaped). Either is fine — assert it's
        // numeric and equal-as-double.
        switch dDec {
        case .int(let n): try expectEqual(Double(n), 42.0)
        case .double(let n): try expectEqual(n, 42.0)
        default: try expectTrue(false, "expected numeric, got \(dDec)")
        }
    }

    s.test("JSONValue round-trips arrays + nested objects") {
        let v: JSONValue = .object([
            "depth_prompt": .object([
                "prompt": .string("[OOC: explicit content allowed]"),
                "depth": .int(4),
                "role": .string("system"),
            ]),
            "agnai/voice": .object([
                "service": .string("elevenlabs"),
                "voiceId": .string("EXAVITQu4vr4xnSDxMaL"),
            ]),
            "tags_extra": .array([.string("nsfw"), .string("dom")]),
            "feature_count": .int(7),
            "is_premium": .bool(true),
            "score": .double(0.85),
            "deprecated_field": .null,
        ])
        let encoded = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        try expectEqual(decoded, v)
    }

    s.test("JSONValue dictionary preserves arbitrary key order across round-trip") {
        let dict: [String: JSONValue] = [
            "a": .int(1),
            "b": .int(2),
            "c": .int(3),
        ]
        let v = JSONValue.object(dict)
        let encoded = try JSONEncoder().encode(v)
        let decoded = try JSONDecoder().decode(JSONValue.self, from: encoded)
        if case .object(let out) = decoded {
            try expectEqual(out, dict)
        } else {
            try expectTrue(false, "expected .object, got \(decoded)")
        }
    }

    s.test("JSONValue rejects non-JSON inputs") {
        // Trying to decode non-JSON bytes throws.
        let bad = Data("not json".utf8)
        do {
            _ = try JSONDecoder().decode(JSONValue.self, from: bad)
            try expectTrue(false, "expected throw")
        } catch {
            // ok
        }
    }

    // MARK: - Character v2-mappable additions (§5.2a)

    s.test("Character defaults messageExample / creatorNotes / extensions to empty/nil") {
        let c = Character(name: "Test")
        try expectEqual(c.messageExample, "")
        try expectTrue(c.creatorNotes == nil)
        try expectTrue(c.extensions == nil)
    }

    s.test("Character init carries Phase 9 v2-mappable fields verbatim") {
        let ext: [String: JSONValue] = [
            "depth_prompt": .object([
                "prompt": .string("[stay in character]"),
                "depth": .int(4),
                "role": .string("system"),
            ]),
        ]
        let c = Character(
            name: "Marin",
            description: "Captain.",
            messageExample: "{{user}}: Hi\nMarin: Hello.",
            creatorNotes: "NSFW; dom-leaning; tested on llama3-70b.",
            extensions: ext
        )
        try expectEqual(c.messageExample, "{{user}}: Hi\nMarin: Hello.")
        try expectEqual(c.creatorNotes, "NSFW; dom-leaning; tested on llama3-70b.")
        try expectTrue(c.extensions != nil)
        if case .object(let depthPromptObj) = c.extensions!["depth_prompt"]! {
            try expectEqual(depthPromptObj["prompt"], .string("[stay in character]"))
            try expectEqual(depthPromptObj["depth"], .int(4))
            try expectEqual(depthPromptObj["role"], .string("system"))
        } else {
            try expectTrue(false, "extensions[depth_prompt] should be .object")
        }
    }

    s.test("Character Codable round-trips Phase 9 v2-mappable fields") {
        let original = Character(
            name: "Marin",
            messageExample: "Marin: example",
            creatorNotes: "notes here",
            extensions: ["custom/key": .string("value")]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(Character.self, from: encoded)
        try expectEqual(decoded.name, original.name)
        try expectEqual(decoded.messageExample, original.messageExample)
        try expectEqual(decoded.creatorNotes, original.creatorNotes)
        try expectEqual(decoded.extensions?["custom/key"], .string("value"))
    }

    s.test("Character decodes legacy on-disk JSON (without Phase 9 fields)") {
        // Pre-Phase-9 record: name/description but none of the new fields.
        // Existing on-disk Characters look like this.
        let legacy = """
        {
            "id": "11111111-2222-3333-4444-555555555555",
            "name": "Legacy",
            "description": "from before Phase 9",
            "personality": "",
            "scenario": "",
            "firstMessage": "",
            "alternateGreetings": [],
            "tags": [],
            "charBook": [],
            "created": 0
        }
        """.data(using: .utf8)!
        let c = try JSONDecoder().decode(Character.self, from: legacy)
        try expectEqual(c.name, "Legacy")
        try expectEqual(c.description, "from before Phase 9")
        try expectEqual(c.messageExample, "")
        try expectTrue(c.creatorNotes == nil)
        try expectTrue(c.extensions == nil)
    }

    s.test("Character extensions preserves unknown app-namespaced keys on round-trip") {
        let ext: [String: JSONValue] = [
            "agnai/voice": .object(["service": .string("elevenlabs")]),
            "risuai": .object([
                "additionalText": .string("kink list..."),
                "viewScreen": .string("emotion"),
            ]),
            "rpclient": .object([
                "default_voice_id": .string("kokoro:af_bella"),
            ]),
            "depth_prompt": .object([
                "prompt": .string("dp"),
                "depth": .int(4),
                "role": .string("system"),
            ]),
        ]
        let c = Character(name: "X", extensions: ext)
        let data = try JSONEncoder().encode(c)
        let decoded = try JSONDecoder().decode(Character.self, from: data)
        // Every key survives. Unknown keys aren't dropped.
        try expectTrue(decoded.extensions != nil)
        try expectEqual(decoded.extensions!.keys.count, 4)
        try expectTrue(decoded.extensions!["agnai/voice"] != nil)
        try expectTrue(decoded.extensions!["risuai"] != nil)
        try expectTrue(decoded.extensions!["rpclient"] != nil)
        try expectTrue(decoded.extensions!["depth_prompt"] != nil)
    }

    return s
}
