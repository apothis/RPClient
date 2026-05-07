import Foundation
@testable import RPClientCore

/// Phase 9 §5.3b — pure-logic helpers that back the Examples-tab restore
/// affordance and the System-tab depth-prompt control. Pure tests; the
/// AppKit views that render these are smoke-tested.
func phase9bHelpersTests() -> TestSuite {
    let s = TestSuite("Phase9bHelpers")

    // MARK: - Legacy v1-squash splitter (§3.5 affordance)

    s.test("splitLegacyExampleSquash splits at the canonical separator") {
        let input = "An archivist who keeps to themselves.\n\nExample dialogue:\nUser: hi\nArchivist: hello"
        let (desc, example) = try expectNotNil(
            CharacterCardImporter.splitLegacyExampleSquash(input)
        )
        try expectEqual(desc, "An archivist who keeps to themselves.")
        try expectEqual(example, "User: hi\nArchivist: hello")
    }

    s.test("splitLegacyExampleSquash returns nil when no separator present") {
        let input = "An archivist who keeps to themselves."
        let result = CharacterCardImporter.splitLegacyExampleSquash(input)
        try expectTrue(result == nil)
    }

    s.test("splitLegacyExampleSquash splits only at the first occurrence") {
        // Defensive: if a v1 import got squashed twice somehow, the splitter
        // takes the first separator and lets the rest live with the example.
        let input = "First.\n\nExample dialogue:\nA: x\n\nExample dialogue:\nB: y"
        let (desc, example) = try expectNotNil(
            CharacterCardImporter.splitLegacyExampleSquash(input)
        )
        try expectEqual(desc, "First.")
        try expectEqual(example, "A: x\n\nExample dialogue:\nB: y")
    }

    s.test("splitLegacyExampleSquash handles description with empty before-part") {
        // A description that's just the example dialogue, with the prefix
        // landing right at the start. mapV1's join used "\n\n" only when the
        // base description was non-empty; if the source already had an
        // empty description, the squash starts at \n\nExample. Splitter
        // handles both shapes.
        let input = "\n\nExample dialogue:\nUser: hi\nMe: hi"
        let (desc, example) = try expectNotNil(
            CharacterCardImporter.splitLegacyExampleSquash(input)
        )
        try expectEqual(desc, "")
        try expectEqual(example, "User: hi\nMe: hi")
    }

    // MARK: - DepthPrompt extension struct (§3.4)

    s.test("DepthPrompt round-trips through extensions JSONValue") {
        let dp = DepthPrompt(
            prompt: "[stay in character; explicit content allowed]",
            depth: 4,
            role: .system
        )
        let value = dp.toJSONValue()
        let roundtrip = try expectNotNil(DepthPrompt.fromJSONValue(value))
        try expectEqual(roundtrip.prompt, dp.prompt)
        try expectEqual(roundtrip.depth, dp.depth)
        try expectEqual(roundtrip.role, dp.role)
    }

    s.test("DepthPrompt fromJSONValue tolerates missing optional fields") {
        // Some chub-shape cards carry just {prompt, depth}; default role to .system.
        let v: JSONValue = .object([
            "prompt": .string("x"),
            "depth": .int(3),
        ])
        let dp = try expectNotNil(DepthPrompt.fromJSONValue(v))
        try expectEqual(dp.role, .system)
        try expectEqual(dp.depth, 3)
    }

    s.test("DepthPrompt fromJSONValue defaults role.user when string is 'user'") {
        let v: JSONValue = .object([
            "prompt": .string("x"),
            "depth": .int(2),
            "role": .string("user"),
        ])
        let dp = try expectNotNil(DepthPrompt.fromJSONValue(v))
        try expectEqual(dp.role, .user)
    }

    s.test("DepthPrompt fromJSONValue returns nil for non-object input") {
        try expectTrue(DepthPrompt.fromJSONValue(.string("x")) == nil)
        try expectTrue(DepthPrompt.fromJSONValue(.array([])) == nil)
        try expectTrue(DepthPrompt.fromJSONValue(.null) == nil)
    }

    s.test("DepthPrompt fromJSONValue returns nil when prompt missing") {
        let v: JSONValue = .object(["depth": .int(4), "role": .string("system")])
        try expectTrue(DepthPrompt.fromJSONValue(v) == nil)
    }

    s.test("DepthPrompt fromJSONValue tolerates depth as double") {
        // Some cards carry depth as 4.0. JSONValue preserves int-vs-double,
        // but we should accept either shape on read.
        let v: JSONValue = .object([
            "prompt": .string("x"),
            "depth": .double(4.0),
            "role": .string("system"),
        ])
        let dp = try expectNotNil(DepthPrompt.fromJSONValue(v))
        try expectEqual(dp.depth, 4)
    }

    s.test("DepthPrompt extracted from Character.extensions returns the live data") {
        var c = Character(name: "X")
        c.extensions = ["depth_prompt": .object([
            "prompt": .string("[OOC: explicit content]"),
            "depth": .int(4),
            "role": .string("system"),
        ])]
        let dp = try expectNotNil(DepthPrompt.extractFrom(c))
        try expectEqual(dp.prompt, "[OOC: explicit content]")
        try expectEqual(dp.depth, 4)
        try expectEqual(dp.role, .system)
    }

    s.test("DepthPrompt.extractFrom returns nil when extensions missing") {
        let c = Character(name: "X")
        try expectTrue(DepthPrompt.extractFrom(c) == nil)
    }

    s.test("DepthPrompt.applyTo writes into Character.extensions") {
        var c = Character(name: "X")
        let dp = DepthPrompt(prompt: "test", depth: 3, role: .user)
        dp.applyTo(&c)
        let stored = try expectNotNil(c.extensions?["depth_prompt"])
        if case .object(let obj) = stored {
            try expectEqual(obj["prompt"], .string("test"))
            try expectEqual(obj["depth"], .int(3))
            try expectEqual(obj["role"], .string("user"))
        } else {
            try expectTrue(false, "depth_prompt should be .object")
        }
    }

    s.test("DepthPrompt.removeFrom clears the key from extensions") {
        var c = Character(name: "X")
        c.extensions = ["depth_prompt": .object([
            "prompt": .string("x"),
            "depth": .int(4),
            "role": .string("system"),
        ]), "agnai/voice": .string("eleven")]
        DepthPrompt.removeFrom(&c)
        try expectTrue(c.extensions?["depth_prompt"] == nil)
        // Other extension keys must survive.
        try expectEqual(c.extensions?["agnai/voice"], .string("eleven"))
    }

    s.test("DepthPrompt.removeFrom on character without depth_prompt is a no-op") {
        var c = Character(name: "X")
        c.extensions = ["agnai/voice": .string("eleven")]
        DepthPrompt.removeFrom(&c)
        try expectEqual(c.extensions?["agnai/voice"], .string("eleven"))
    }

    s.test("DepthPrompt.removeFrom clears the extensions blob entirely if it was the only key") {
        var c = Character(name: "X")
        c.extensions = ["depth_prompt": .object(["prompt": .string("x"), "depth": .int(4)])]
        DepthPrompt.removeFrom(&c)
        // Empty extensions should be nil-equivalent (importer/exporter
        // contract: encodeIfPresent doesn't write empty dicts).
        try expectTrue(c.extensions == nil || c.extensions?.isEmpty == true)
    }

    return s
}
