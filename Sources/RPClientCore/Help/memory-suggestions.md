# Memory: suggestions & extraction

The fact extractor is a separate side-call to the model that scans recent turns for facts worth remembering — a relationship, a stated preference, a new entity — and surfaces them as **pending suggestions** for you to approve or dismiss. It's the lazy half of the memory loop: the model proposes, you curate.

Two inspector panes are involved:

- **Suggestions** — the review queue. Approve a suggestion to promote it to a pinned fact (or, for typed facts, into the entity store); dismiss to drop it.
- **Extraction** — the controls: cadence, priority topics, save-to-library.

## When the extractor runs

The extractor runs on a cadence you set: every **N user turns**. Defaults to `4`. The status bar's activity spinner shows `extracting facts…` while the call is in flight.

You can disable it entirely from `Settings… → Memory (fact extraction) → Auto-extract fact suggestions after every N user turns`.

You can also force it once: this is mostly useful right before a scene break, when you want to capture the arc's facts before the rolling summary compresses them.

## Reviewing suggestions

The **Suggestions** tab in the inspector shows the queue for the current chat. Each entry has:

- A short body (the proposed fact).
- A **✓** button — promotes the fact to pinned memory.
- A **✗** button — dismisses the suggestion.
- An optional **edit** affordance so you can tighten the wording before promoting.

The tab label shows an unread badge when there are pending suggestions you haven't seen since you last opened the tab.

## Promoting vs. dismissing

Promote when the fact is **timeless within the chat** and not already obvious from recent turns or the character card. The criteria are the same as for [pinned facts](memory-pinned-facts):

- Timeless — won't be invalidated by the next scene.
- Short — one clause, not a paragraph.
- Load-bearing — the model would otherwise drift.

Dismiss freely. False positives are part of the design — the extractor is a junior collaborator, not an oracle. A well-curated pinned-facts list is more valuable than an exhaustive one.

## Extraction settings

The **Extraction** pane is where you tune the side-call's behaviour for the current chat:

- **Run every N user turns** (mirrors the global setting).
- **Priority topic library** — a list of phrases to nudge the extractor's attention toward specific kinds of facts (relationships, locations, fears, etc.). The library is global (`Settings… → Priority topic library`) and can be applied per-chat from this pane.
- **Save active topics to library** — promotes the topics you've added to this chat into the global library so the next chat can reuse them.

If you find yourself manually pinning the same kinds of facts every time, that's a sign you should add a corresponding topic so the extractor catches them automatically.

## Worked example: catching relationship facts

You're 20 turns into a chat and the model keeps forgetting that Sarah and Aldric used to be married. You'd rather not hand-pin every relationship, so you:

1. Inspector → **Extraction**.
2. Add topic: `relationships and prior history between named characters`.
3. **Save active topics to library** so future chats inherit it.
4. Wait for the next extraction cadence to fire (or trigger one manually).
5. Inspector → **Suggestions**. The next batch should include something like `Sarah and Aldric were once married`.
6. Click **✓** to promote.

From then on, the relationship is pinned and the extractor will keep watching for similar updates.
