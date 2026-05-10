# World-info injector

[Memory/WorldInfoInjector.swift](Sources/RPClientCore/Memory/WorldInfoInjector.swift). Pure-function matching layer for the lorebook entries on a chat. Per turn, decides which entries fire and returns their content blocks for the prompt.

User-facing description: [World info](memory-world-info).

## API

Two static entry points:

```swift
static func matchingEntries(
    entries: [WorldInfoEntry], turns: [Turn]
) -> [WorldInfoEntry]

static func contentBlocks(
    entries: [WorldInfoEntry], turns: [Turn]
) -> [String]
```

The first returns the matched entries (used by the inspector to highlight which entries are firing for the current chat); the second returns just the content strings (used by `PromptBuilder.worldInfoHits`).

## Match algorithm

For each enabled entry, in `injectionMode`:

| Mode | Behaviour |
|---|---|
| `.always` | Always fires. Bypasses key matching. |
| `.keyword` (default) | `matchesKeyword(entry:turns:)` — see below. |
| `.vectorized` | Reserved. Currently a no-op (returns false). |

`matchesKeyword` flow:

1. Resolve the **scope text** via `scopedText(for:turns:)`:
   - `.recentTurns(N)` — last N turns concatenated.
   - `.lastUserTurn` — the latest user message only.
   - `.entireChat` — every turn concatenated.
2. Lowercase the scope text once.
3. Check **primary keys**: `anyKeyMatches(entry.keys, in: lowerText)`. Need at least one hit.
4. If `entry.secondaryKeys` is non-empty, check **secondary keys** the same way. Need at least one hit. (AND-gate.)
5. If both pass and `entry.content` is non-empty, fire.

## Word-boundary matching

`matchesAsWord(needle:in:)` ([WorldInfoInjector.swift:72](Sources/RPClientCore/Memory/WorldInfoInjector.swift)) scans the lowered text for the needle and verifies it starts and ends on **non-word-character** boundaries. `isWordChar` is letters, digits, underscore.

Cases:

- Key `Mournbringer` matches `the Mournbringer hummed`. ✓
- Key `Mournbringer` matches `"Mournbringer."` (punctuation around). ✓
- Key `bringer` does **not** match `Mournbringer` (substring inside word). ✗
- Match is case-insensitive.

Using a custom matcher rather than NSRegularExpression keeps the code grep-able and avoids regex-engine surprises on Unicode scalars.

## Sorting and budget

`PromptBuilder.worldInfoHits` ([PromptBuilder.swift:326](Sources/RPClientCore/PromptBuilder.swift)) sorts firing entries by **priority desc, then name asc** and truncates each entry's content to its `tokenCap` (estimated via `charsPerToken * tokenCap`).

When the total cost would still blow the world-info budget, the prompt builder packs greedily in sorted order — high-priority entries always make it; low-priority ones are dropped first.

Empty-content entries are filtered out before sorting.

## Match scope

The three scopes serve different roles:

- **`recentTurns(N)`** — default. The right choice for "lore that should appear when its topic comes up in the recent conversation."
- **`lastUserTurn`** — fires only on the latest user message. Useful for entries that should react to *intent* (the user explicitly asks about a topic) rather than passive mentions in narration.
- **`entireChat`** — searches the whole transcript. Rarely useful; an entry will fire forever once its key has appeared even once. Mostly here for completeness.

The default scope on legacy entries (those decoded from the pre-V5 `keys + content + tokenCap` JSON) is `.recentTurns(4)` ([WorldInfoEntry custom Decodable](Sources/RPClientCore/Models/WorldInfoEntry.swift)).

## What this doesn't do

- **No vector matching.** `.vectorized` mode is reserved for a future similarity-based trigger; today it's a no-op so configured entries don't accidentally fire.
- **No fuzzy matching.** Misspelled keys don't match. This is intentional — fuzzy matching produces too many false positives and there's no UI to surface "this entry almost fired."
- **No turn-level dedup.** If two entries have overlapping content and both fire, both get injected. Use the `priority` field to disambiguate.

## Test coverage

[WorldInfoInjectorTests.swift](Tests/RPClientCoreTests/WorldInfoInjectorTests.swift) covers the matrix:

- Case-insensitive, word-boundary respected.
- Substring-inside-word excluded.
- Punctuation around keys still matches.
- Disabled entries never fire.
- Always-mode bypasses key check.
- Vectorized-mode skipped today.
- Secondary-key AND-gate.
- Each `matchScope` honoured correctly.
- Priority desc / name asc sort.
- Empty-content entries skipped even with key matches.

If you change the matching semantics, the tests are the contract.
