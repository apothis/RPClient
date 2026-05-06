import Foundation
@testable import RPClientCore

/// Phase 7 §3.1 — turn-tree branching data model and path helpers.
///
/// Covers the additions to `Turn` (`parentId`, `activeChildId`) and `Chat`
/// (`activePath` + the helper API), the spine-tree migration of legacy chats,
/// the validation rules at decode time (dangling parents, disconnected paths,
/// multiple roots, cycles), and the `switchBranch` semantics including the
/// drill-to-deepest-descendant rule borrowed from Open WebUI's
/// `Messages.svelte:179`.
///
/// All tests here are pure — no AppKit, no AppState. The branching surface
/// is testable end-to-end at the model layer.
func chatBranchingTests() -> TestSuite {
    let s = TestSuite("ChatBranching")

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

    // MARK: - Spine migration (legacy chats with no branching fields)

    s.test("legacy chat without parentId/activePath migrates to a spine tree") {
        // Pre-Phase-7 chat: turns are a flat array with no parent links.
        // After decode, every turn should have parentId pointing at its
        // predecessor (root has nil), activeChildId nil throughout, and
        // activePath == turns.map(\.id).
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID(), id2 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "hi", "ts": "\(now)", "edited": false},
                {"id": "\(id1.uuidString)", "role": "assistant", "text": "hello", "ts": "\(now)", "edited": false},
                {"id": "\(id2.uuidString)", "role": "user", "text": "how are you", "ts": "\(now)", "edited": false}
            ]
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.turns.count, 3)
        try expectEqual(chat.turns[0].parentId, nil)
        try expectEqual(chat.turns[1].parentId, id0)
        try expectEqual(chat.turns[2].parentId, id1)
        try expectEqual(chat.turns[0].activeChildId, nil)
        try expectEqual(chat.turns[1].activeChildId, nil)
        try expectEqual(chat.turns[2].activeChildId, nil)
        try expectEqual(chat.activePath, [id0, id1, id2])
    }

    s.test("empty-turns chat migrates to empty activePath") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Empty",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": []
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectEqual(chat.turns.count, 0)
        try expectEqual(chat.activePath, [])
    }

    s.test("migration is idempotent — re-encoded chat decodes unchanged") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID()
        let legacy = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "hi", "ts": "\(now)", "edited": false},
                {"id": "\(id1.uuidString)", "role": "assistant", "text": "hello", "ts": "\(now)", "edited": false}
            ]
        }
        """
        let first = try decoder.decode(Chat.self, from: Data(legacy.utf8))
        let reEncoded = try encoder.encode(first)
        let second = try decoder.decode(Chat.self, from: reEncoded)
        try expectEqual(second.turns[0].parentId, first.turns[0].parentId)
        try expectEqual(second.turns[1].parentId, first.turns[1].parentId)
        try expectEqual(second.activePath, first.activePath)
    }

    s.test("chat created via the no-arg initializer has empty activePath") {
        let chat = Chat(title: "Fresh")
        try expectEqual(chat.activePath, [])
        try expectEqual(chat.turns, [])
    }

    // MARK: - Helper API

    s.test("activeTurns walks activePath in order") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        let t2 = Turn(role: .user, text: "c")
        chat.turns = [t0, t1, t2]
        chat.activePath = [t0.id, t1.id, t2.id]
        let active = chat.activeTurns
        try expectEqual(active.map(\.text), ["a", "b", "c"])
    }

    s.test("activeTurns skips turn IDs not present in turns") {
        // Defensive: a stale activePath entry pointing to a deleted turn
        // should be silently dropped from the renderable list. (Decode-time
        // validation prevents this via the connected-path check, but the
        // helper itself should also be robust.)
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        chat.turns = [t0, t1]
        chat.activePath = [t0.id, UUID(), t1.id]
        try expectEqual(chat.activeTurns.map(\.text), ["a", "b"])
    }

    s.test("turn(id:) returns the matching turn or nil") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        chat.turns = [t0, t1]
        try expectEqual(chat.turn(id: t0.id)?.text, "a")
        try expectEqual(chat.turn(id: t1.id)?.text, "b")
        try expectEqual(chat.turn(id: UUID()), nil)
    }

    s.test("activePosition(of:) returns index for path turns, nil for off-path") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "a")
        let t1 = Turn(role: .assistant, text: "b")
        let off = Turn(role: .assistant, text: "off-path")
        chat.turns = [t0, t1, off]
        chat.activePath = [t0.id, t1.id]
        try expectEqual(chat.activePosition(of: t0.id), 0)
        try expectEqual(chat.activePosition(of: t1.id), 1)
        try expectEqual(chat.activePosition(of: off.id), nil)
        try expectEqual(chat.activePosition(of: UUID()), nil)
    }

    s.test("children(of:) returns siblings sorted by ts (creation order)") {
        var chat = Chat(title: "Test")
        let parentTs = Date(timeIntervalSince1970: 1_700_000_000)
        let parent = Turn(role: .user, text: "parent", ts: parentTs)
        // Three siblings created in non-monotonic order; children() should
        // sort them by ts so iteration is deterministic regardless of how
        // they were appended to the turns array.
        let childA = makeAssistant(parentId: parent.id, text: "A", ts: parentTs.addingTimeInterval(10))
        let childB = makeAssistant(parentId: parent.id, text: "B", ts: parentTs.addingTimeInterval(5))
        let childC = makeAssistant(parentId: parent.id, text: "C", ts: parentTs.addingTimeInterval(15))
        chat.turns = [parent, childA, childB, childC]
        let kids = chat.children(of: parent.id)
        try expectEqual(kids.map(\.text), ["B", "A", "C"])
    }

    s.test("children(of:) returns empty for a leaf turn") {
        var chat = Chat(title: "Test")
        let t0 = Turn(role: .user, text: "leaf")
        chat.turns = [t0]
        try expectEqual(chat.children(of: t0.id), [])
    }

    // MARK: - switchBranch + descend-to-leaf

    s.test("switchBranch(to:) on a leaf updates activePath through to that leaf") {
        // Tree:    root
        //          /  \
        //         A    B
        // Active path starts on A; switching to B should produce [root, B].
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let a = makeAssistant(parentId: root.id, text: "A")
        let b = makeAssistant(parentId: root.id, text: "B")
        chat.turns = [root, a, b]
        chat.activePath = [root.id, a.id]

        chat.switchBranch(to: b.id)
        try expectEqual(chat.activePath, [root.id, b.id])
    }

    s.test("switchBranch(to:) descends to the deepest descendant via activeChildId") {
        // Tree:    root → A → A1 → A1a
        //               \
        //                B
        // Switching to A drills via activeChildId chain to A1a.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        var a = makeAssistant(parentId: root.id, text: "A")
        var a1 = makeUser(parentId: a.id, text: "A1")
        let a1a = makeAssistant(parentId: a1.id, text: "A1a")
        let b = makeAssistant(parentId: root.id, text: "B")
        a.activeChildId = a1.id
        a1.activeChildId = a1a.id
        chat.turns = [root, a, a1, a1a, b]
        chat.activePath = [root.id, b.id]

        chat.switchBranch(to: a.id)
        try expectEqual(chat.activePath, [root.id, a.id, a1.id, a1a.id])
    }

    s.test("switchBranch(to:) descends via earliest child when activeChildId unset") {
        // Tree:    root → A → A1 (ts=10)
        //                   ↘ A2 (ts=5)
        // A.activeChildId = nil → descend via earliest by ts → A2.
        var chat = Chat(title: "Test")
        let parentTs = Date(timeIntervalSince1970: 1_700_000_000)
        let root = Turn(role: .user, text: "root", ts: parentTs)
        let a = makeAssistant(parentId: root.id, text: "A", ts: parentTs.addingTimeInterval(1))
        let a1 = makeUser(parentId: a.id, text: "A1", ts: parentTs.addingTimeInterval(10))
        let a2 = makeUser(parentId: a.id, text: "A2", ts: parentTs.addingTimeInterval(5))
        chat.turns = [root, a, a1, a2]
        chat.activePath = []

        chat.switchBranch(to: a.id)
        try expectEqual(chat.activePath, [root.id, a.id, a2.id])
    }

    s.test("switchBranch(to:) on a turn already on the path is a no-op") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let leaf = makeAssistant(parentId: root.id, text: "leaf")
        chat.turns = [root, leaf]
        chat.activePath = [root.id, leaf.id]

        chat.switchBranch(to: root.id)
        try expectEqual(chat.activePath, [root.id, leaf.id])
    }

    s.test("switchBranch(to:) updates the parent's activeChildId so subsequent loads stick") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let a = makeAssistant(parentId: root.id, text: "A")
        let b = makeAssistant(parentId: root.id, text: "B")
        chat.turns = [root, a, b]
        chat.activePath = [root.id, a.id]

        chat.switchBranch(to: b.id)
        try expectEqual(chat.turn(id: root.id)?.activeChildId, b.id)
    }

    // MARK: - summarizedThrough clamp on branch switch (Phase 7 §3.2.D)

    s.test("switchBranch(to:) clamps summarizedThrough to the new path's length when shorter") {
        // Long path A summarized through turn 5; switch to short path B
        // (length 3) — summarizedThrough must clamp to 3 so
        // PromptBuilder.verbatimTurns doesn't try to slice past the end.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let a1 = makeAssistant(parentId: root.id, text: "A1")
        let a2 = makeUser(parentId: a1.id, text: "A2")
        let a3 = makeAssistant(parentId: a2.id, text: "A3")
        let a4 = makeUser(parentId: a3.id, text: "A4")
        let a5 = makeAssistant(parentId: a4.id, text: "A5")
        let b1 = makeAssistant(parentId: root.id, text: "B1")
        let b2 = makeUser(parentId: b1.id, text: "B2")
        chat.turns = [root, a1, a2, a3, a4, a5, b1, b2]
        chat.activePath = [root.id, a1.id, a2.id, a3.id, a4.id, a5.id]
        chat.summarizedThrough = 5

        chat.switchBranch(to: b1.id)
        try expectEqual(chat.activePath, [root.id, b1.id, b2.id])
        try expectEqual(chat.summarizedThrough, 3, "clamped to the new path length")
    }

    s.test("switchBranch(to:) leaves summarizedThrough alone when new path is longer") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let a1 = makeAssistant(parentId: root.id, text: "A1")
        let b1 = makeAssistant(parentId: root.id, text: "B1")
        let b2 = makeUser(parentId: b1.id, text: "B2")
        let b3 = makeAssistant(parentId: b2.id, text: "B3")
        chat.turns = [root, a1, b1, b2, b3]
        chat.activePath = [root.id, a1.id]
        chat.summarizedThrough = 1

        chat.switchBranch(to: b1.id)
        try expectEqual(chat.activePath, [root.id, b1.id, b2.id, b3.id])
        try expectEqual(chat.summarizedThrough, 1, "no clamp needed; new path is longer")
    }

    s.test("switchBranch(to:) on a turn already on the path is a no-op") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.turns = [root]
        chat.activePath = [root.id]

        chat.switchBranch(to: UUID())
        try expectEqual(chat.activePath, [root.id])
    }

    // MARK: - Validation in decode

    s.test("decode throws on dangling parentId pointing to a missing turn") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Bad",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "x", "ts": "\(now)", "edited": false, "parentId": "\(UUID().uuidString)"}
            ],
            "activePath": ["\(id0.uuidString)"]
        }
        """
        try expectThrows {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("decode throws on disconnected activePath") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID()
        // Two turns, both rooted (parentId nil), activePath claims they're in
        // sequence — but id1's parent is nil, not id0.
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Bad",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false, "parentId": null},
                {"id": "\(id1.uuidString)", "role": "assistant", "text": "b", "ts": "\(now)", "edited": false, "parentId": null}
            ],
            "activePath": ["\(id0.uuidString)", "\(id1.uuidString)"]
        }
        """
        try expectThrows {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("decode throws on multiple roots") {
        let now = ISO8601DateFormatter().string(from: Date())
        let id0 = UUID(), id1 = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Bad",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(id0.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false, "parentId": null},
                {"id": "\(id1.uuidString)", "role": "user", "text": "b", "ts": "\(now)", "edited": false, "parentId": null}
            ],
            "activePath": ["\(id0.uuidString)"]
        }
        """
        try expectThrows {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    s.test("decode throws on a parentId cycle") {
        // Two-turn cycle: A.parent = B, B.parent = A. parentId-walk from any
        // turn should never reach a nil parent within turns.count steps.
        let now = ISO8601DateFormatter().string(from: Date())
        let idA = UUID(), idB = UUID()
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Bad",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": [
                {"id": "\(idA.uuidString)", "role": "user", "text": "a", "ts": "\(now)", "edited": false, "parentId": "\(idB.uuidString)"},
                {"id": "\(idB.uuidString)", "role": "assistant", "text": "b", "ts": "\(now)", "edited": false, "parentId": "\(idA.uuidString)"}
            ],
            "activePath": ["\(idA.uuidString)"]
        }
        """
        try expectThrows {
            _ = try decoder.decode(Chat.self, from: Data(json.utf8))
        }
    }

    // MARK: - appendTurn (Phase 7 §3.3a — production-mutation helper)

    s.test("appendTurn on an empty chat seeds the root and activePath") {
        // Mirrors `AppState.newChat(withCharacter:)`'s greeting seed: the
        // first turn becomes the root (parentId nil) and activePath is just
        // its id.
        var chat = Chat(title: "Fresh")
        let greeting = Turn(role: .assistant, text: "Hi.")
        chat.appendTurn(greeting)
        try expectEqual(chat.turns.count, 1)
        try expectEqual(chat.turns[0].parentId, nil)
        try expectEqual(chat.activePath, [greeting.id])
    }

    s.test("appendTurn on a non-empty chat sets parentId to the active leaf") {
        // Mirrors `AppState.sendUserMessage`: appending against an existing
        // path makes the new turn a child of the current leaf.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.appendTurn(root)
        let asst = Turn(role: .assistant, text: "")
        chat.appendTurn(asst)
        try expectEqual(chat.turns.count, 2)
        try expectEqual(chat.turn(id: asst.id)?.parentId, root.id)
        try expectEqual(chat.activePath, [root.id, asst.id])
    }

    s.test("appendTurn updates the previous leaf's activeChildId to the new turn") {
        // `switchBranch(to:)` drills via activeChildId; on a freshly extended
        // path that pointer should point at the just-appended turn so a later
        // branch-switch-and-back lands on the leaf we just wrote.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.appendTurn(root)
        let asst = Turn(role: .assistant, text: "reply")
        chat.appendTurn(asst)
        try expectEqual(chat.turn(id: root.id)?.activeChildId, asst.id)
    }

    s.test("appendTurn overwrites a pre-set parentId with the active leaf") {
        // Defensive: callers pass freshly-constructed turns with parentId
        // nil; if a stale parentId leaks through, the helper still produces
        // a connected path rather than corrupting state.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.appendTurn(root)
        var t = Turn(role: .assistant, text: "x")
        t.parentId = UUID() // bogus
        chat.appendTurn(t)
        try expectEqual(chat.turn(id: t.id)?.parentId, root.id)
    }

    s.test("appendTurn after switchBranch extends the new branch, not the previous one") {
        // After switching to branch B, appending should add a child of B's
        // leaf, not inadvertently extend the abandoned branch A.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let a = makeAssistant(parentId: root.id, text: "A")
        let b = makeAssistant(parentId: root.id, text: "B")
        chat.turns = [root, a, b]
        chat.activePath = [root.id, a.id]

        chat.switchBranch(to: b.id)
        let next = Turn(role: .user, text: "follow-up on B")
        chat.appendTurn(next)
        try expectEqual(chat.turn(id: next.id)?.parentId, b.id)
        try expectEqual(chat.activePath, [root.id, b.id, next.id])
    }

    // MARK: - fork (Phase 7 §3.3b — sibling-add primitive)

    s.test("fork(parentId:newTurn:) appends the new turn as a sibling under parent") {
        // Tree: root → user → asstA. fork on user produces asstB as a
        // sibling of asstA. activePath becomes [root, user, asstB].
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let user = makeUser(parentId: root.id, text: "u")
        let asstA = makeAssistant(parentId: user.id, text: "A")
        chat.turns = [root, user, asstA]
        chat.activePath = [root.id, user.id, asstA.id]

        let asstB = Turn(role: .assistant, text: "B")
        chat.fork(parentId: user.id, newTurn: asstB)

        try expectEqual(chat.turns.count, 4)
        try expectEqual(chat.turn(id: asstB.id)?.parentId, user.id)
        try expectEqual(chat.activePath, [root.id, user.id, asstB.id])
        // Old branch survives in storage.
        try expectEqual(chat.turn(id: asstA.id)?.text, "A")
    }

    s.test("fork overwrites the new turn's parentId to the requested parent") {
        // Defensive: caller passes a fresh turn whose parentId may be nil
        // or stale; fork unconditionally rewrites it.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.turns = [root]
        chat.activePath = [root.id]

        var t = Turn(role: .assistant, text: "x")
        t.parentId = UUID() // bogus — should be overwritten
        chat.fork(parentId: root.id, newTurn: t)
        try expectEqual(chat.turn(id: t.id)?.parentId, root.id)
    }

    s.test("fork sets parent.activeChildId to the new turn") {
        // After a fork, switching away and back should land on the new
        // sibling, not the original child. The activeChildId update is
        // what makes that drill-down deterministic.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let asstA = makeAssistant(parentId: root.id, text: "A")
        chat.turns = [root, asstA]
        chat.activePath = [root.id, asstA.id]

        let asstB = Turn(role: .assistant, text: "B")
        chat.fork(parentId: root.id, newTurn: asstB)
        try expectEqual(chat.turn(id: root.id)?.activeChildId, asstB.id)
    }

    s.test("fork truncates activePath when forking off a non-leaf ancestor") {
        // Tree: root → t1 → t2 → t3 (active). Fork off t1 producing t1b
        // → activePath becomes [root, t1, t1b]. t2 / t3 remain in
        // chat.turns for later switchBranch-back.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let t1 = makeAssistant(parentId: root.id, text: "t1")
        let t2 = makeUser(parentId: t1.id, text: "t2")
        let t3 = makeAssistant(parentId: t2.id, text: "t3")
        chat.turns = [root, t1, t2, t3]
        chat.activePath = [root.id, t1.id, t2.id, t3.id]

        let t1b = Turn(role: .user, text: "t1b")
        chat.fork(parentId: t1.id, newTurn: t1b)
        try expectEqual(chat.activePath, [root.id, t1.id, t1b.id])
        // Old subtree still discoverable via children.
        try expectEqual(chat.children(of: t1.id).map(\.text).sorted(), ["t1b", "t2"])
    }

    s.test("fork is a no-op when parentId doesn't exist in turns") {
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        chat.turns = [root]
        chat.activePath = [root.id]

        let bogus = Turn(role: .assistant, text: "x")
        chat.fork(parentId: UUID(), newTurn: bogus)
        try expectEqual(chat.turns.count, 1)
        try expectEqual(chat.activePath, [root.id])
    }

    s.test("fork + switchBranch round-trip keeps both branches reachable") {
        // Fork twice off the same parent, then switchBranch back to the
        // first child. activePath should land on that child's leaf, with
        // both siblings still in chat.turns.
        var chat = Chat(title: "Test")
        let root = Turn(role: .user, text: "root")
        let asstA = makeAssistant(parentId: root.id, text: "A")
        chat.turns = [root, asstA]
        chat.activePath = [root.id, asstA.id]

        let asstB = Turn(role: .assistant, text: "B")
        chat.fork(parentId: root.id, newTurn: asstB)
        try expectEqual(chat.activePath, [root.id, asstB.id])

        chat.switchBranch(to: asstA.id)
        try expectEqual(chat.activePath, [root.id, asstA.id])

        chat.switchBranch(to: asstB.id)
        try expectEqual(chat.activePath, [root.id, asstB.id])
    }

    // MARK: - Round-trip with explicit branching state

    s.test("round-trip preserves parentId, activeChildId, and activePath") {
        let stamp = Date(timeIntervalSince1970: floor(Date().timeIntervalSince1970))
        var chat = Chat(title: "Branched")
        chat.created = stamp
        chat.modified = stamp
        let root = Turn(role: .user, text: "root", ts: stamp)
        var a = makeAssistant(parentId: root.id, text: "A", ts: stamp.addingTimeInterval(1))
        let b = makeAssistant(parentId: root.id, text: "B", ts: stamp.addingTimeInterval(2))
        a.activeChildId = nil
        chat.turns = [root, a, b]
        chat.activePath = [root.id, b.id]

        let data = try encoder.encode(chat)
        let decoded = try decoder.decode(Chat.self, from: data)
        try expectEqual(decoded.turns.count, 3)
        try expectEqual(decoded.activePath, [root.id, b.id])
        try expectEqual(decoded.turn(id: root.id)?.parentId, nil)
        try expectEqual(decoded.turn(id: a.id)?.parentId, root.id)
        try expectEqual(decoded.turn(id: b.id)?.parentId, root.id)
    }

    return s
}

// MARK: - Test helpers

private func makeAssistant(parentId: UUID, text: String, ts: Date = Date()) -> Turn {
    var t = Turn(role: .assistant, text: text, ts: ts)
    t.parentId = parentId
    return t
}

private func makeUser(parentId: UUID, text: String, ts: Date = Date()) -> Turn {
    var t = Turn(role: .user, text: text, ts: ts)
    t.parentId = parentId
    return t
}
