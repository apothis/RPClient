import Foundation
import CoreGraphics
@testable import RPClientCore

/// Phase 7 §3.5 — pure tests for the chat-tree minimap layout.
///
/// Layout is layered top-down: y = depth × rowHeight, x is determined by
/// an in-order DFS walk so leaves get successive horizontal slots and
/// internal nodes are centered over their children. Sibling order is by
/// `Turn.ts` ascending — same rule the rest of the branching code uses
/// (gutter glyph popover, Branches pane), so the visual ordering matches
/// what the user sees elsewhere.
///
/// `activeEdges` returns the set of `(parent, child)` pairs that lie on
/// the chat's active path. The view uses this to thicken the active
/// trunk when it draws.
func minimapLayoutTests() -> TestSuite {
    let s = TestSuite("MinimapLayout")

    let row: CGFloat = 40
    let col: CGFloat = 60

    s.test("empty chat produces empty layout") {
        let chat = Chat(title: "Empty")
        let pos = MinimapLayout.layout(chat: chat, rowHeight: row, colWidth: col)
        try expectEqual(pos.count, 0)
    }

    s.test("single-turn chat places the root at the origin") {
        var chat = Chat(title: "Single")
        let root = Turn(role: .user, text: "hi")
        chat.turns = [root]
        chat.activePath = [root.id]

        let pos = MinimapLayout.layout(chat: chat, rowHeight: row, colWidth: col)
        try expectEqual(pos.count, 1)
        try expectEqual(pos[root.id]?.x, 0)
        try expectEqual(pos[root.id]?.y, 0)
    }

    s.test("linear chain stacks every turn at the same x, y stepping by rowHeight") {
        var chat = Chat(title: "Linear")
        let t0 = Turn(role: .user, text: "a")
        let t1 = makeAssistant(parentId: t0.id, text: "b")
        let t2 = makeUser(parentId: t1.id, text: "c")
        chat.turns = [t0, t1, t2]
        chat.activePath = [t0.id, t1.id, t2.id]

        let pos = MinimapLayout.layout(chat: chat, rowHeight: row, colWidth: col)
        try expectEqual(pos.count, 3)
        try expectEqual(pos[t0.id]?.x, 0)
        try expectEqual(pos[t1.id]?.x, 0)
        try expectEqual(pos[t2.id]?.x, 0)
        try expectEqual(pos[t0.id]?.y, 0)
        try expectEqual(pos[t1.id]?.y, row)
        try expectEqual(pos[t2.id]?.y, 2 * row)
    }

    s.test("single fork places siblings at distinct x, parent centered above") {
        // Tree:    root
        //          /  \
        //         A    B
        // Expected: A.x < B.x (siblings sorted by ts), root.x is the
        // mean of A.x and B.x. Y depths: root=0, A=B=row.
        var chat = Chat(title: "Fork")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let root = Turn(role: .user, text: "root", ts: now)
        let a = makeAssistant(parentId: root.id, text: "A", ts: now.addingTimeInterval(1))
        let b = makeAssistant(parentId: root.id, text: "B", ts: now.addingTimeInterval(2))
        chat.turns = [root, a, b]
        chat.activePath = [root.id, a.id]

        let pos = MinimapLayout.layout(chat: chat, rowHeight: row, colWidth: col)
        try expectEqual(pos.count, 3)
        let pa = try expectNotNil(pos[a.id])
        let pb = try expectNotNil(pos[b.id])
        let pr = try expectNotNil(pos[root.id])
        try expectTrue(pa.x < pb.x, "A should be to the left of B (earlier ts)")
        try expectEqual(pa.y, row)
        try expectEqual(pb.y, row)
        try expectEqual(pr.y, 0)
        try expectEqual(pr.x, (pa.x + pb.x) / 2, "root x is centered above its children")
    }

    s.test("nested fork — leaves consume successive x slots, ancestors center over them") {
        // Tree:    root
        //         /    \
        //        A      B
        //       / \      \
        //      A1 A2     B1
        // Expected leaves in DFS in-order: A1, A2, B1.
        // x slots: A1=0, A2=col, B1=2*col.
        // A is centered over (A1,A2) → 0.5*col. B is centered over B1 → 2*col.
        // root is centered over (A,B) → (0.5*col + 2*col)/2 = 1.25*col.
        var chat = Chat(title: "Nested")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let root = Turn(role: .user, text: "root", ts: now)
        let a = makeAssistant(parentId: root.id, text: "A", ts: now.addingTimeInterval(1))
        let b = makeAssistant(parentId: root.id, text: "B", ts: now.addingTimeInterval(2))
        let a1 = makeUser(parentId: a.id, text: "A1", ts: now.addingTimeInterval(3))
        let a2 = makeUser(parentId: a.id, text: "A2", ts: now.addingTimeInterval(4))
        let b1 = makeUser(parentId: b.id, text: "B1", ts: now.addingTimeInterval(5))
        chat.turns = [root, a, b, a1, a2, b1]
        chat.activePath = [root.id, a.id, a1.id]

        let pos = MinimapLayout.layout(chat: chat, rowHeight: row, colWidth: col)
        try expectEqual(pos.count, 6)
        try expectEqual(pos[a1.id]?.x, 0 * col)
        try expectEqual(pos[a2.id]?.x, 1 * col)
        try expectEqual(pos[b1.id]?.x, 2 * col)
        try expectEqual(pos[a.id]?.x, 0.5 * col)
        try expectEqual(pos[b.id]?.x, 2 * col)
        try expectEqual(pos[root.id]?.x, 1.25 * col)
        // Depth check.
        try expectEqual(pos[root.id]?.y, 0)
        try expectEqual(pos[a.id]?.y, row)
        try expectEqual(pos[a1.id]?.y, 2 * row)
    }

    s.test("layout is deterministic — same chat produces identical positions across runs") {
        // Build the same chat twice, layout each, compare. Determinism is
        // required so the minimap doesn't reshuffle on every chatTreeChanged
        // notification.
        func makeChat() -> Chat {
            var c = Chat(title: "Det")
            let now = Date(timeIntervalSince1970: 1_700_000_000)
            let r = Turn(role: .user, text: "r", ts: now)
            let a = makeAssistant(parentId: r.id, text: "a", ts: now.addingTimeInterval(1))
            let b = makeAssistant(parentId: r.id, text: "b", ts: now.addingTimeInterval(2))
            c.turns = [r, a, b]
            c.activePath = [r.id, a.id]
            return c
        }
        let c1 = makeChat()
        let c2 = makeChat()
        let p1 = MinimapLayout.layout(chat: c1, rowHeight: row, colWidth: col)
        let p2 = MinimapLayout.layout(chat: c2, rowHeight: row, colWidth: col)
        // Same UUIDs across c1 and c2 because Turn() generates fresh UUIDs
        // — so we compare by VALUES at the same node names instead.
        // Re-key by text for the comparison.
        let v1 = Dictionary(uniqueKeysWithValues: c1.turns.map { ($0.text, p1[$0.id]) })
        let v2 = Dictionary(uniqueKeysWithValues: c2.turns.map { ($0.text, p2[$0.id]) })
        try expectEqual(v1["r"]??.x, v2["r"]??.x)
        try expectEqual(v1["a"]??.x, v2["a"]??.x)
        try expectEqual(v1["b"]??.x, v2["b"]??.x)
    }

    // MARK: - activeEdges

    s.test("activeEdges returns parent/child pairs along activePath") {
        // Tree:    root → A → A1     (active)
        //               \
        //                B
        // Active edges: (root, A) and (A, A1).
        var chat = Chat(title: "Edges")
        let root = Turn(role: .user, text: "root")
        let a = makeAssistant(parentId: root.id, text: "A")
        let a1 = makeUser(parentId: a.id, text: "A1")
        let b = makeAssistant(parentId: root.id, text: "B")
        chat.turns = [root, a, a1, b]
        chat.activePath = [root.id, a.id, a1.id]

        let edges = MinimapLayout.activeEdges(chat: chat)
        try expectEqual(edges.count, 2)
        try expectTrue(edges.contains(MinimapEdge(parent: root.id, child: a.id)))
        try expectTrue(edges.contains(MinimapEdge(parent: a.id, child: a1.id)))
        // Off-path edge must NOT be in the active set.
        try expectFalse(edges.contains(MinimapEdge(parent: root.id, child: b.id)))
    }

    s.test("activeEdges is empty for a chat with no path or a single-node path") {
        // Empty chat.
        let empty = Chat(title: "Empty")
        try expectEqual(MinimapLayout.activeEdges(chat: empty), [])

        // Single-node chat — no edges to highlight.
        var single = Chat(title: "Single")
        let root = Turn(role: .user, text: "root")
        single.turns = [root]
        single.activePath = [root.id]
        try expectEqual(MinimapLayout.activeEdges(chat: single), [])
    }

    return s
}

// MARK: - Test helpers (mirrored from ChatBranchingTests.swift)

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
