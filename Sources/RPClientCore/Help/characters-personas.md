# Characters & personas

A **character** is who the model is roleplaying as; a **persona** is who *you* are roleplaying as. Both feed the prompt at every turn. Both are stored independently of any chat — you build them once in the library, then attach them to as many chats as you like.

## Characters

A character bundles the description, personality, scenario, and (optionally) a first message and a small lorebook. Fields ([Character.swift](Sources/RPClientCore/Models/Character.swift)):

| Field | What it does |
|---|---|
| **Name** | Display name. Used to label assistant turns. |
| **Description** | The character's identity, appearance, background. The biggest field. |
| **Personality** | Behavioural traits. Optional; some cards merge this into Description. |
| **Scenario** | The situation the chat opens in. |
| **First message** | The character's opening line. Pre-populated in a new chat. |
| **Alternate greetings** | Other opening lines you can pick from. |
| **System prompt** | Optional override for the chat's system instruction. |
| **Post-history instructions** | An author's-note-style cue carried by the card. |
| **Tags / creator / version** | Library metadata. |
| **Character book (`charBook`)** | A small lorebook bundled with the card. Merged into the chat's world info on import. |

### Importing

Drop a SillyTavern v2 card (`.png` or `.json`) onto the sidebar, or use **File → Import Character… (⌘O)**. RPClient extracts the embedded JSON from PNG cards via the `chara` text chunk and stores everything atomically.

Cards live in `~/Library/Application Support/RPClient/characters/<uuid>.json` with the avatar at `characters/avatars/<uuid>.png`.

### Starting a chat with a character

Two paths:

- **Sidebar → + New → New Chat with Character… (⇧⌘N)** — pops the picker.
- **File → New Chat with Character… (⇧⌘N)** — same picker from the menu.

The new chat is seeded with the character's persona (description / personality / scenario), the character's first message as the opening assistant turn, and any character-book lorebook entries merged into `Chat.worldInfo`.

### Editing

Characters live in the **Library** window (`File → Show Library` (⇧⌘L) → Characters tab). Edit there; changes apply to **future** chats started with the character. Existing chats hold a snapshot of the relevant fields, so editing a character does not retroactively rewrite chat memory.

## Personas

A persona has just two load-bearing fields: **name** and **description**. Description is the part the model reads.

```
You are roleplaying as Iris, a 24-year-old field cartographer. Iris is
quiet, methodical, and prefers maps to people. She carries a battered
journal everywhere.
```

### Creating

Library → Personas tab → **+ New Persona**. Fill in name and description. Optionally drop a PNG onto the row to set an avatar.

### Picking the active persona

Three places affect which persona a chat uses, in priority order:

1. **The chat itself** — `Chat.personaId`. Once set, the chat keeps that persona forever (until you change it).
2. **The default persona** — `Settings… → Default persona`. Used when a new chat is created without an explicit persona.
3. **Anonymous** — falls back to whatever you typed in `Settings… → Your name`, with no persona description.

In the prompt, the persona block is rendered by [PromptBuilder.renderPersonaBlock](Sources/RPClientCore/PromptBuilder.swift). Gemma folds it into the first user turn; Qwen3 puts it in the system block.

### When to use a persona vs. just a name

- A name in `Settings… → Your name` is enough if you just want the model to *address* you correctly. The model gets `The user's name is Kev.` and that's it.
- A persona is right when you want the model to know *who you are playing*. Same field is doing the work that a character card does for the assistant side.

You can have many personas and switch between them per-chat — useful for running the same character in different POVs.

## Avatars

Drop a PNG onto a character row in the Library (or a persona row) to set its avatar. Avatars show up:

- **Sidebar** — 32 px circular avatar to the left of each chat row, sourced from the chat's character.
- **Chat view** — 32 px avatar at the top-left of each assistant turn (matches Open WebUI styling). Character-less chats fall back to a `✦` glyph.

Persona avatars on user turns and entity avatars in turns are deferred — see V2_PLAN §6.4 for the rationale. Today the avatar slot is character-only.

The same image works at every site (sidebar, chat view, library card) — RPClient resizes at draw time. Use a square PNG; non-square images get centre-cropped.

## Library window

`File → Show Library` (⇧⌘L). Two tabs:

- **Characters** — grid of cards. Click to select. **Start Chat** creates a new chat using the selected card. **Delete** removes the card and its avatar (does not delete chats that use it).
- **Personas** — list. **+ New Persona** opens a sheet. **Edit** opens the same sheet for an existing persona. **Delete** removes the persona (does not modify chats that reference it; those simply fall back to default-persona / anonymous on next load).

For more on the library window, see [Library window](library).

## Worked example: importing a card and giving yourself a persona

You downloaded a SillyTavern character card and want to drop into a chat as a specific viewpoint character.

1. Drag the `.png` onto the sidebar (or **File → Import Character…**).
2. **File → Show Library** → **Personas** tab → **+ New Persona**. Name it; describe yourself.
3. **Settings… → Default persona** → pick the new persona.
4. Sidebar **+ New → New Chat with Character…** → pick the imported card.

The new chat opens with the character's greeting, your persona injected, and you can start typing.
