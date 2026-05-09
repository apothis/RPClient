import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.a — tests for the SmokeFixtures library. The smoke
// harnesses depend on these fixtures decoding cleanly into the same
// shape Storage produces on disk; if a future Chat schema bump
// breaks them silently, the smokes pass against malformed input
// (worse than failing visibly).
//
// What's covered:
//   - every synthetic chat round-trips through JSONEncoder/Decoder
//     without losing fields
//   - cast linkage holds for multi-cast chats (every assistant turn's
//     speakerId resolves to a member of `chat.cast`)
//   - characters with extensions / intimacy data round-trip with
//     extensions intact
//   - the fixture catalogue exposes every named fixture via byName()
//     and the all-list lengths match expectations
func smokeFixturesTests() -> TestSuite {
    let s = TestSuite("SmokeFixtures")

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

    s.test("synthetic chats round-trip") {
        for entry in SyntheticChats.all {
            let data = try encoder.encode(entry.chat)
            let decoded = try decoder.decode(Chat.self, from: data)
            try expectEqual(decoded, entry.chat, "fixture \(entry.name) failed round-trip")
        }
    }

    s.test("synthetic characters round-trip") {
        for entry in SyntheticCharacters.all {
            let data = try encoder.encode(entry.character)
            let decoded = try decoder.decode(Character.self, from: data)
            try expectEqual(decoded.id, entry.character.id, "character \(entry.name) id drift")
            try expectEqual(decoded.name, entry.character.name, "character \(entry.name) name drift")
            try expectEqual(decoded.description, entry.character.description, "character \(entry.name) description drift")
            try expectEqual(decoded.personality, entry.character.personality, "character \(entry.name) personality drift")
            try expectEqual(decoded.scenario, entry.character.scenario, "character \(entry.name) scenario drift")
            try expectEqual(decoded.firstMessage, entry.character.firstMessage, "character \(entry.name) firstMessage drift")
            try expectEqual(decoded.systemPrompt, entry.character.systemPrompt, "character \(entry.name) systemPrompt drift")
            try expectEqual(decoded.tags, entry.character.tags, "character \(entry.name) tags drift")
        }
    }

    s.test("character with extensions preserves keys") {
        let mira = SyntheticCharacters.mira
        // Mira is the spec exemplar — verify she carries an extensions
        // blob with the rpclient.intimacy nested keys (these come from
        // the CardGenExemplars intimacy_* field set).
        let ext = try expectNotNil(mira.extensions)
        let rpclient = try expectNotNil(ext["rpclient"])
        if case .object(let nested) = rpclient {
            _ = try expectNotNil(nested["intimacy"])
        } else {
            throw TestFailure(message: "Mira.extensions.rpclient should be an object", file: #file, line: #line)
        }

        let data = try encoder.encode(mira)
        let decoded = try decoder.decode(Character.self, from: data)
        try expectEqual(decoded.extensions, mira.extensions, "extensions blob lost on round-trip")
        try expectEqual(decoded.creatorNotes, mira.creatorNotes, "creatorNotes lost on round-trip")
        try expectEqual(decoded.messageExample, mira.messageExample, "messageExample lost on round-trip")
    }

    s.test("group-chat fixtures: cast linkage holds") {
        let groupChat = SyntheticChats.groupChat.chat
        try expectGreaterThan(groupChat.cast.count, 1)
        let castSet = Set(groupChat.cast)
        for t in groupChat.turns where t.role == .assistant {
            let sid = try expectNotNil(t.speakerId)
            try expectTrue(castSet.contains(sid), "assistant turn \(t.id) has speakerId \(sid) not in cast \(groupChat.cast)")
        }
        // The NSFW group scene is the second multi-cast fixture; same
        // invariant should hold there too.
        let nsfwGroup = SyntheticChats.nsfwGroupScene.chat
        try expectGreaterThan(nsfwGroup.cast.count, 1)
        let nsfwCast = Set(nsfwGroup.cast)
        for t in nsfwGroup.turns where t.role == .assistant {
            let sid = try expectNotNil(t.speakerId)
            try expectTrue(nsfwCast.contains(sid), "nsfwGroupScene assistant turn \(t.id) speakerId out of cast")
        }
    }

    s.test("fixture catalogue covers expected surface") {
        // The harness plan calls for at least 8 chat fixtures spanning
        // the surface table in V2_PHASE10_SMOKE_HARNESS_PLAN.md §1. If
        // someone trims the catalogue below that we want to know.
        try expectGreaterThan(SyntheticChats.all.count, 7)
        // Spot-check every named fixture is reachable by name (the
        // smokes look these up via --fixture <name>).
        let names = Set(SyntheticChats.all.map(\.name))
        for required in [
            "cold-start", "sfw-short", "sfw-long",
            "nsfw-innuendo", "nsfw-explicit", "nsfw-kink",
            "nsfw-group-scene", "group-chat",
            "post-conflict", "refusal-bait",
        ] {
            try expectTrue(names.contains(required), "fixture catalogue missing required entry '\(required)'")
            try expectTrue(SyntheticChats.byName(required) != nil, "byName(\(required)) returned nil")
        }
        // Characters mirror the seven CardGenExemplars archetypes.
        try expectEqual(SyntheticCharacters.all.count, 7)
        for required in ["mira", "monstergirl", "modern", "spacer", "biopunk", "companion", "domestic"] {
            try expectTrue(SyntheticCharacters.byName(required) != nil, "characters byName(\(required)) returned nil")
        }
    }

    s.test("sfw-long fixture provides summariser stress") {
        // §10.0.b's Summariser smoke loads this directly. ≥40 turns
        // is the empirical floor for triggering the rolling-summary
        // path on default chat settings (summaryTriggerRatio 0.85
        // against ~16k ctx).
        let long = SyntheticChats.sfwLong.chat
        try expectGreaterThan(long.turns.count, 39)
    }

    s.test("cold-start fixture has no assistant turn") {
        let cold = SyntheticChats.coldStart.chat
        let assistantTurns = cold.turns.filter { $0.role == .assistant && !$0.text.isEmpty }
        try expectEqual(assistantTurns.count, 0, "cold-start should have no non-empty assistant turn (model hasn't replied yet)")
    }

    s.test("real-chat loader round-trips a written-out fixture") {
        // Write a fixture chat into a temp directory styled like the
        // production chats dir, then have the loader read it back. This
        // exercises the same code path the smokes use when --chat is
        // passed at the CLI.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmokeFixturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let chat = SyntheticChats.sfwShort.chat
        let url = tmp.appendingPathComponent("\(chat.id.uuidString).json")
        let data = try encoder.encode(chat)
        try data.write(to: url)

        let loaded = try RealChatLoader.loadChat(id: chat.id.uuidString, in: tmp)
        try expectEqual(loaded, chat, "RealChatLoader should round-trip a chat written to disk")
    }

    s.test("real-chat loader resolves bare and stamped ids") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("SmokeFixturesTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let chat = SyntheticChats.sfwShort.chat
        let url = tmp.appendingPathComponent("\(chat.id.uuidString).json")
        try encoder.encode(chat).write(to: url)

        // bare id without .json suffix
        _ = try RealChatLoader.loadChat(id: chat.id.uuidString, in: tmp)
        // id with .json suffix accepted too
        _ = try RealChatLoader.loadChat(id: "\(chat.id.uuidString).json", in: tmp)
    }

    return s
}
