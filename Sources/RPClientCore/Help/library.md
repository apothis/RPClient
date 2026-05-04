# Library window

The library window is where you manage characters and personas independently of any chat. **File → Show Library (⇧⌘L)** to open.

Implementation: [LibraryWindowController.swift](Sources/RPClientCore/UI/LibraryWindowController.swift).

## Characters tab

A grid of cards, each showing the avatar, name, and a tag/creator line.

- **+ Import…** — opens an open-panel for `.png` or `.json` SillyTavern cards. Same code path as `File → Import Character…` and as drag-drop onto the sidebar.
- **Start Chat** — creates a new chat using the selected card. Equivalent to `New Chat with Character…` for the selected entry.
- **Delete** — permanent removal of the card and its avatar. Does **not** delete chats that already use the card; those keep their snapshot of the character fields.

The detail strip below the grid shows name, creator, version, tags, and the first 220 chars of the description. Useful for sanity-checking a card before starting a chat with it.

Cards on disk live in `~/Library/Application Support/RPClient/characters/`:

```
characters/
├── <uuid>.json
└── avatars/
    └── <uuid>.png
```

## Personas tab

A flat list of personas, each with name + first-line-of-description preview.

- **+ New Persona** — opens an editor sheet for a fresh persona (name + description).
- **Edit** — opens the same sheet for the selected persona.
- **Delete** — removes the persona JSON and avatar. Chats that reference the deleted persona fall back to the default persona (or anonymous) on next load.

Avatars: drop a PNG onto a persona row to set its avatar; you can also drop one in the editor sheet.

Personas on disk:

```
personas/
├── <uuid>.json
└── avatars/
    └── <uuid>.png
```

## Lorebooks (forthcoming tab)

Lorebook management currently lives **inside the chat's Inspector → World tab** rather than in the library. There is no global lorebook tab today — lorebook entries are per-chat.

When a SillyTavern character card carries a `character_book`, those entries are merged into the chat's `worldInfo` at chat-creation time (see `AppState.mergedWorldInfo`). This is one-shot, not a live link — editing the character's card book later does not retroactively touch chats that have already been seeded from it.

A library-level lorebook tab is on the long-tail list; it will land when the cross-chat lorebook reuse pattern needs first-class UI.

## What the library does *not* manage

- **Chats.** They live in the sidebar, not here. The library is the catalogue of *reusable* assets; the sidebar is the catalogue of *active* conversations.
- **Sampler presets.** Custom presets land in `Settings…` (today) or — once the planner gets to it — a dedicated presets manager.
- **Settings as a whole.** `Settings…` (⌘,) is the right surface; the library is just for character/persona assets.

## Worked example: cleaning up old characters

After a few weeks of trying cards you don't want most of them. The cleanup loop:

1. **File → Show Library**.
2. Click each card you don't want and hit **Delete**. Existing chats that use the card keep working — their character info is held in the chat's own snapshot.
3. If you want to also clean up *the chats* that used those cards, switch to the sidebar and right-click → **Delete** there.

The two are intentionally decoupled: deleting a card doesn't delete chats, and deleting a chat doesn't delete a card. This is what you want when a card was for a one-off chat and you keep both, *or* when a chat was a quick test and you keep neither.
