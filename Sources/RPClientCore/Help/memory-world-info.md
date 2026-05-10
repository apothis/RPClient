# Memory: world info (lorebook)

World info is a keyword-triggered lorebook. Each entry has trigger keys and a body of text; when a key appears in the recent turns, the entry's body is injected into the prompt for that turn only. When no key fires, the entry uses no token budget.

Use it for lore that should appear *contextually* — a faction's history when its name comes up, a place's description when characters arrive there, a cultural rule when the relevant setting is on stage.

## Where it shows up

- **Inspector → World tab** — list of entries, an editor for the selected one, an enable toggle.
- **Status bar** — the **teal** segment is the total tokens contributed by entries that fired this turn.

## Anatomy of an entry

| Field | What it does |
|---|---|
| **Name** | A human label, distinct from the keys. Pure organisation. |
| **Keys** | Case-insensitive trigger words; matched on word boundaries. Any key firing is enough by default. |
| **Secondary keys** | Optional AND-gate. The entry fires only if a primary key **and** a secondary key both appear in scope. |
| **Content** | The lore text, injected when the entry fires. |
| **Token cap** | Per-entry maximum. Long entries get truncated. |
| **Enabled** | Master switch. |
| **Injection mode** | `keyword` (default), `always` (fires every turn), or `vectorized` (reserved for V2). |
| **Match scope** | `recentTurns(N)`, `lastUserTurn`, or `entireChat`. Where to look for the keys. |
| **Priority** | Tiebreaker when total firing entries exceed the budget. Higher wins. |

## How matching works

- Keys are matched **case-insensitively** on **word boundaries**, so `Mournbringer` matches `the Mournbringer hummed` but not `mournbringer-class destroyer` (the dash makes it a different word boundary, depending on the regex engine — test before relying on partial-word matches).
- Punctuation around the key is fine: `"Mournbringer."` matches.
- Substring inside a longer word does *not* match: `bringer` won't fire on `Mournbringer`.
- **Always** mode bypasses key matching entirely. **Vectorized** mode is reserved for a future similarity-based trigger and currently does nothing.

## Match scope

`matchScope` controls *where* RPClient looks for keys:

- **`recentTurns(N)`** — last N turns (user + assistant). Default `4`. The right choice for most lore.
- **`lastUserTurn`** — only the latest user message. Useful for entries that should respond to *intent* (e.g. when the user asks about a topic) rather than passive mentions.
- **`entireChat`** — the whole transcript. Rarely useful — the entry will fire forever once the key is mentioned even once.

## Priorities and budget

If too many entries fire and their total tokens would blow the world-info budget, RPClient sorts firing entries by **priority desc, then name asc**, and includes them top-to-bottom until the budget runs out. Empty-content entries are dropped before priority is considered.

## Worked example: a faction entry that fires only in the throne room

You want the Crow Court's history to appear when the user mentions the throne room *and* the Crow Court — not on a passing mention of either alone.

1. Inspector → **World** → **+ New Entry**.
2. **Name:** `Crow Court`.
3. **Keys:** `Crow Court`, `the Crows`.
4. **Secondary keys:** `throne room`, `audience hall`.
5. **Content:** the faction's history, kept to a few sentences (under 200 tokens is a good target).
6. **Match scope:** `recentTurns(4)`.
7. **Priority:** leave at `0`.

The entry now fires only when both groups have shown up within the last four turns.

## Tips

- **Test in the inspector.** When you click an entry, the pane shows whether it's currently firing for the active chat. If a key isn't matching the way you expect, that's where you'll see it.
- **Prefer specific keys to common words.** A key like `the king` will fire on every mention of any king; `Aldric` is more precise.
- **Use the `Always` injection mode sparingly.** It bypasses keys entirely — fine for one or two world-defining cues, expensive if overused.
