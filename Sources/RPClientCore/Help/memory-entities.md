# Memory: entities

The entity store is structured memory for *named things in the chat* — characters, locations, factions, objects. Where pinned facts are free-text statements, entities are typed records with a name, a kind, and a list of facts about them.

The store's job is to keep specific, queryable facts about specific entities — and to inject *only the entities currently on stage* into the prompt. If a character isn't mentioned in the last few turns, their facts don't take up token budget that turn.

## Where it shows up

- **Inspector → Entities tab** — the list of entities for the current chat, the editor for the selected one, and a button to add a new one.
- **Status bar** — the **Memory & entities** segment (blue) is the combined budget for pinned facts plus on-stage entity facts.

## Anatomy of an entity

| Field | What it does |
|---|---|
| **Name** | Display name. Used for matching against recent turns. |
| **Kind** | `character`, `location`, `faction`, `object`, etc. Drives default formatting. |
| **Facts** | A list of short statements about the entity. Each fact is independently editable. |

Facts on an entity are subject to **topic supersession** at render time: within a topic bucket (currently `clothing`), only the most recent fact reaches the prompt. This is what stops a character being described as *topless and naked simultaneously* when both states have been narrated and both ended up as facts.

Pinned facts and topicless facts (timeless attributes — names, ages, relationships) always survive supersession.

## On-stage selection

An entity is "on stage" if its name has appeared in the recent verbatim turns. Only on-stage entities have their facts injected into the prompt. This is what lets the store hold dozens of entities cheaply — most of the time, only a handful are paying tokens.

If you want an entity *always* on stage (e.g. a player character), the right move is to mirror the most important facts in pinned memory rather than over-using the entity store. The entity store is best at *contextual recall*; pinned memory is best at *unconditional presence*.

## Editing

Click any entity to open the editor:

- Edit the name and kind directly.
- Add / edit / delete facts in the fact list.
- The editor is autosaving — there's no "save" step.

To delete an entity, select it and use the row's **Delete** affordance. Deletion is permanent for that chat; entities aren't shared across chats.

## Where entities come from

Today, the main flow is:

1. The fact extractor runs.
2. Some suggestions are typed (relationship, attribute about a character/location/faction) and are surfaced as entity-store updates rather than free-text facts.
3. You approve, and the entity store gets the new fact.

You can also create and edit entities by hand from the Entities pane.

## Migration note

Older chats may have entries with names like `[character] Sarah` and `kind: event`. RPClient runs a one-shot dedup pass on schema upgrade to collapse these into their typed twins (`Sarah`, kind `character`). This happens automatically the first time an old chat opens — you don't need to do anything.

## Worked example: a recurring side character

You introduce a character — Borin the smith — who appears in the village every few scenes.

1. Inspector → **Entities** → **+ New**.
2. Name: `Borin`. Kind: `character`.
3. Facts: `Smith of the village`, `Missing left eye, lost in a fire`, `Reluctant friend of Aldric`.
4. Send the next turn.

When the chat is in the village and Borin's name shows up, his facts are injected. When you're elsewhere and he isn't mentioned, the facts use no budget. If he eventually loses his right eye too (don't ask), edit his entity rather than adding a contradicting pinned fact.
