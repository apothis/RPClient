import Foundation
import CoreGraphics

/// Phase 7 §3.5 — pure layout for the chat-tree minimap. Layered top-down:
/// y is depth from root × `rowHeight`; x is determined by an in-order DFS
/// walk over leaves so siblings stay adjacent and ancestors center over
/// their descendants.
///
/// Algorithm in three passes (each O(n) on a tree with n turns, low
/// branching factor — measured constants are tiny for chats <500 turns):
///
///  1. Find the root (the one turn with `parentId == nil`). Empty chat →
///     empty layout.
///  2. DFS in-order walk from the root, sorting children by `ts` ascending
///     (matches the ordering used by the gutter glyph popover and the
///     Branches pane). Leaves get successive integer x slots — `0, 1, 2, …`
///     — in the order they're visited. Internal nodes get the mean of their
///     children's slot positions.
///  3. Multiply slots by `colWidth` and depths by `rowHeight` to produce
///     the final `CGPoint` per turn id.
///
/// Determinism is required: same chat → same positions on every call.
/// Anything reading `Turn.ts` for ordering is fine because `ts` is a stored
/// property and stable across decode.
///
/// This file lives under `Memory/` alongside the other pure data-shape
/// helpers (Chunker, SceneSummary, etc.) — it's not strictly memory, but
/// "pure logic over Chat" is the right neighborhood and keeps it out of the
/// AppKit `UI/` directory so tests can link it without dragging the view
/// layer in.
enum MinimapLayout {
    /// Compute the position of every turn in `chat`. Returns an empty
    /// dictionary for an empty chat.
    static func layout(chat: Chat, rowHeight: CGFloat, colWidth: CGFloat) -> [UUID: CGPoint] {
        guard !chat.turns.isEmpty else { return [:] }
        // Find the single root. Validation in Chat.init guarantees exactly
        // one; defend against in-memory invariant violations by picking the
        // first nil-parent turn we see and treating the rest as orphans.
        guard let root = chat.turns.first(where: { $0.parentId == nil }) else {
            return [:]
        }

        // Slot indices via in-order DFS over leaves.
        var slot: [UUID: CGFloat] = [:]
        var nextLeafSlot: CGFloat = 0
        var depth: [UUID: Int] = [:]

        func visit(_ turnId: UUID, currentDepth: Int) {
            depth[turnId] = currentDepth
            let kids = chat.children(of: turnId)
            if kids.isEmpty {
                slot[turnId] = nextLeafSlot
                nextLeafSlot += 1
                return
            }
            for k in kids {
                visit(k.id, currentDepth: currentDepth + 1)
            }
            // Internal node: center over the mean of its children's slots.
            let kidSlots = kids.compactMap { slot[$0.id] }
            guard !kidSlots.isEmpty else { return }
            let mean = kidSlots.reduce(0, +) / CGFloat(kidSlots.count)
            slot[turnId] = mean
        }
        visit(root.id, currentDepth: 0)

        var out: [UUID: CGPoint] = [:]
        for (id, s) in slot {
            let d = CGFloat(depth[id] ?? 0)
            out[id] = CGPoint(x: s * colWidth, y: d * rowHeight)
        }
        return out
    }

    /// The set of `(parent, child)` edges that lie on the chat's active
    /// path. Used by the view to thicken the trunk visually.
    static func activeEdges(chat: Chat) -> Set<MinimapEdge> {
        let path = chat.activePath
        guard path.count >= 2 else { return [] }
        var edges: Set<MinimapEdge> = []
        for i in 0..<(path.count - 1) {
            edges.insert(MinimapEdge(parent: path[i], child: path[i + 1]))
        }
        return edges
    }
}

/// Identifier for a directed edge in the chat tree. Hashable so callers
/// can stash them in `Set` for membership tests during draw.
struct MinimapEdge: Hashable {
    let parent: UUID
    let child: UUID
}
