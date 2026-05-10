# Chats & sidebar

The left-hand sidebar lists every chat you have. Each row is a self-contained, persisted conversation with its own history, memory, sampler preset, template, and (optionally) character.

## Creating a chat

The **+ New** button at the top of the sidebar is a pull-down menu with two options:

- **New Chat** — a blank chat using the global defaults (template, preset, persona). Equivalent to **⌘N**.
- **New Chat with Character…** — pops a picker over the imported characters; selecting one creates a chat seeded with that character's persona, scenario, and greeting. Equivalent to **⇧⌘N**.

You can also drag a SillyTavern card PNG or JSON file directly onto the sidebar to import the character (and then start a chat with it from the menu).

## Switching chats

Click any row to switch. The chat view, inspector, and status bar all repopulate from the chat's saved state. There is no "save" step — every edit (turn changes, pinned facts, world info, etc.) is written to disk atomically when it happens.

## Row contents

Each sidebar row shows three lines:

1. **Title** — auto-generated from the first user message, or whatever you renamed it to.
2. **Subtitle** — `turn N · K sent`. `N` is the total turn count (user + assistant), `K` is the number of user turns. The user-turn count is what cadence settings (fact extraction every N user turns, etc.) compare against.
3. **Template badge** — the prompt template this chat is configured to use (e.g. `gemma`, `qwen3`). If the badge is **red**, the loaded model on the server doesn't match this chat's template — replies will probably be empty or echoed until you switch templates. Hover for the detected mismatch.

## Deleting a chat

Right-click any row to bring up the context menu and choose **Delete**. A confirm dialog appears showing the chat title; **Delete** is destructive — there is no trash and no undo.

## Renaming a chat

Currently chats are renamed indirectly: titles auto-update from the first user turn. A first-class rename will land in a later slice; for now, edit the first user turn to retitle (the sidebar refreshes immediately).

## Per-chat settings vs. global

A chat carries three things that override the global defaults:

- **Template** (Gemma vs. Qwen3) — set in the chat header / per-chat picker.
- **Sampler preset** — set in the chat header.
- **Persona** — the user's side of the conversation (see [Characters & personas] in a later slice).

Everything else (server URL, retrieval settings, font size, fact-extraction cadence) is global and lives in `Settings…`.

## Worked example: spinning up a fresh roleplay

1. `File → Import Character…`, pick a SillyTavern v2 card.
2. Sidebar **+ New → New Chat with Character…**, choose the character you just imported.
3. The chat opens with the character's greeting already in place. Type your reply.
4. Press **⌘I** to open the inspector. Pin the character's allergy or backstory cue you want to keep on stage indefinitely.

You now have a chat that won't lose that fact even after the rolling summary kicks in.
