# Entity store

[Models/Entity.swift](Sources/RPClientCore/Models/Entity.swift) for the data shape; [PromptBuilder.entitiesBlock](Sources/RPClientCore/PromptBuilder.swift) for the injection logic. The entity store is the structured cousin of pinned facts: typed records with per-fact provenance, with the load-bearing constraint that **only on-stage entities pay token budget**.

User-facing description: [Entities](memory-entities).

## Data shape

```swift
struct Entity {
    let id: UUID
    var name: String
    var kind: EntityKind          // .character | .location | .faction | .object | .event
    var facts: [Fact]
    var pinnedByUser: Bool
    // …
}

struct Fact {
    let id: UUID
    var text: String
    var pinnedByUser: Bool
    var addedTurn: Int            // when this fact was first added
    var lastReinforcedTurn: Int   // when it was last seen / promoted
    var mentionCount: Int         // how many times it's been seen
}
```

`Fact.text` is the only piece the model sees. The metadata fields (`addedTurn`, `lastReinforcedTurn`, `mentionCount`, `pinnedByUser`) drive **salience sort** and **eviction** at injection time.

## On-stage gating

`Entity.mentioned(in:)` checks whether the entity's name appears in a lowered text. `entitiesBlock` builds the lower-text from the **last 6 turns** by default and walks every entity to find on-stage ones.

Off-stage entities cost **zero tokens**. This is the load-bearing property — it's why the entity store can hold dozens of entities cheaply.

## Salience sort

Within an on-stage entity, facts are sorted by:

1. **`pinnedByUser`** desc — pinned facts always come first.
2. **`lastReinforcedTurn`** desc — recently reinforced facts beat stale ones.
3. **`mentionCount`** desc — frequently mentioned beats rarely.
4. **`addedTurn`** asc — earlier-added is the stable tiebreak.

The ordering is what the model reads top-to-bottom; recency at the top, history at the bottom.

## Topic supersession

`PromptBuilder.supersedeStaleFactsByTopic` ([PromptBuilder.swift:475](Sources/RPClientCore/PromptBuilder.swift)) is the **render-time** dedup layer. Within a topic bucket (currently only `clothing`), only the latest fact survives at injection time. Storage keeps the full history.

```swift
// Inputs:
//   "Sarah was topless"       (lastReinforcedTurn 12)
//   "Sarah was naked"         (lastReinforcedTurn 18)
// Output (clothing bucket → keep latest):
//   "Sarah was naked"
```

Topicless facts (timeless attributes — names, ages, occupations, traits) bypass the dedup. Pinned facts also bypass.

`factTopic(of:)` ([PromptBuilder.swift:507](Sources/RPClientCore/PromptBuilder.swift)) is a small heuristic — currently looks for clothing-related verbs and nouns. Adding a topic = adding a case to this function plus tests.

The whole supersession layer was added in response to Sarah-described-as-topless-and-naked-simultaneously. The fix was deliberately render-time-only so the user can still see fact history in the Entities pane.

## Block budget and eviction

`entitiesBlock` has a `maxChars: Int = 600` cap. When the formatted block exceeds it:

1. Build an **eviction order** of non-pinned entities, ranked ascending by max-fact-salience (`entitySalience(_)`).
2. Drop one entity at a time from the eviction order until the block fits or only pinned entities remain.

Pinned entities never drop, even at overflow — that's the contract of a pin.

## Block header

The block prepends a header phrased as **prose, not a section title**:

```
(Reference only — character details for continuity. Do NOT restate, quote,
or copy these lines into your reply. Use them silently to keep facts
consistent.)
```

The wording is iterated. An earlier `[Entities currently on-stage — keep details consistent]` header was getting *echoed back* at the top of replies by Qwen3 in thinking mode — Qwen3 treats labeled bracket sections as scene preambles to reproduce. The plain-prose framing avoids the trigger.

The bracket markers on individual entity lines are kept because they're needed for the model to parse the tag/content split — but the framing line is plain English.

## Migration: legacy entries

Pre-Chat-v3 schemas could have entries like `name="[character] Sarah"` with `kind=.event`. These are the result of an early pipeline that didn't separate name from kind cleanly.

`Chat.dedupeMigratedEntities` runs on decode for `schemaVersion < 3` and:

1. Detects entries with bracket-prefixed names.
2. Strips the prefix.
3. Looks for a typed twin (an entity with the same cleaned name and a real kind).
4. If found, merges the legacy entry's facts into the twin and drops the legacy entry.
5. If not, sets `kind` to the bracket value and renames.

After the migration, `chat.schemaVersion` bumps to 3. This is the only data migration in the codebase.

## Editing

Entities are edited from `Inspector → Entities` ([EntitiesPane.swift](Sources/RPClientCore/UI/Inspector/EntitiesPane.swift)) and persist through the standard `AppState.updateCurrent { c in c.entities = … }` funnel. There's no special API for entity edits — they're just chat mutations.

Promoted suggestions land here when the user hits ✓ on a typed fact in the Suggestions pane.
