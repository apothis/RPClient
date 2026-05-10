# Settings

`Settings… (⌘,)` opens the global settings sheet. These are app-wide defaults — chats keep their own per-chat overrides for template, sampler preset, and persona.

Settings are persisted to `~/Library/Application Support/RPClient/settings.json`.

## Servers

The Settings sheet's **Servers** section is the editor for the list of KoboldCpp instances RPClient can talk to. The default config is one entry called "Default" pointing at `http://localhost:5001`. Most users never touch this section.

If you run more than one KoboldCpp — typically a big model for chat replies and a small one for summaries — see the dedicated [Multi-server](multi-server) page. The short version:

- Each row is a profile (name + URL + Test button + status dot + delete).
- Below the list, four **role-assignment popups** decide which server handles which job: **Default (chat)**, **Summarizer**, **Extractor**, **Embeddings**. The three side-call roles can fall back to the default with `(use default)`.
- The chat header has a per-chat server picker that overrides the default for that one chat.

`File → Reload Server Info (⌘R)` re-probes the active server(s) and refreshes the status bar.

## Your name

A free-text display name. When non-empty, RPClient prepends `The user's name is {name}.` to the memory block so the model knows what to call you. Empty disables the injection.

If you want the model to know more than just your name, use a [persona](characters-personas) instead.

## Default template

The prompt template used when creating a new chat without an explicit template. **Gemma** or **Qwen3**. RPClient also auto-detects the template from the loaded model name when creating a chat — the default here is the fallback if detection fails.

See [Templates](templates) for the difference between Gemma and Qwen3.

## Default sampler preset

The sampler preset id new chats inherit. Existing chats keep whatever preset they were created with.

See [Sampler presets](presets) for what each preset does.

## Default persona

The persona new chats inherit when none is explicitly chosen. `nil` = anonymous (model just gets your name from `Your name`, no persona description).

## Max context (0 = server max)

Caps the effective context window below whatever the server reports as `true_max_context_length`. `0` means "use the server's max."

When to lower this:

- The server reports a context window larger than your VRAM can actually handle without being slow.
- You want to leave headroom for KV cache reuse on a rapidly-changing chat.

Most users should leave this at `0`.

## Reply token cap (0 = preset)

Per-reply max-token override that beats the active sampler preset's `max_length`. `0` means "use the preset's value."

Use this for one-off cap changes ("today I want short replies") without editing the preset.

## UI font size adjust

Stepper offset added to every UI font's base size. `0` = baseline, `+N` = larger, negative also works. The change applies live across every window via `AppNotification.fontChanged`.

## Memory: fact extraction

Two settings here:

- **Auto-extract fact suggestions after every N user turns** — master switch and cadence for the fact extractor side-call.
- **Run every N user turns** — the cadence (default 4).

See [Suggestions & extraction](memory-suggestions) for the user-facing flow.

### Priority topic library

A reusable list of topic phrases you can copy into a chat's per-chat extraction settings via the inspector's **Extraction → Library** picker. Editing the library does **not** retroactively change topics already added to a chat — the per-chat list is a copy.

## Retrieval

Vector search over chat history. Off by default. Requires KoboldCpp running with `--embeddingsmodel`.

| Setting | What it does |
|---|---|
| **Enable vector retrieval** | Master switch. |
| **Top-K hits** | Maximum chunks attached per turn. |
| **Cosine threshold (0–1)** | Hits below this score are filtered out. |
| **Exclude last N turns** | Skip the most recent turns when matching, so retrieval doesn't return content already verbatim in the prompt. |

See [Retrieval](memory-retrieval) for how the eligibility predicate works.

## Voice subsystem

Two settings in this group, plus a storage row.

- **Enable voice subsystem** — heavy switch. When ticked, RPClient loads the Kokoro TTS engine and listens for assistant-reply finish events. When unticked, the engine isn't loaded at all (no resident memory cost). Default off.
- **Voice storage** — read-only label showing the configured model path, plus **Set/Change location…** and **Voice library…** buttons. The path is where the base model and per-voice tensors land. The first time you enable the subsystem, RPClient prompts you to pick a path (cancelling the prompt rolls the subsystem back to off — see [Voices](voices)).

The chat-header speaker button is the runtime toggle (enabled only when the subsystem is on). The two are split because the subsystem is the heavyweight switch and the runtime toggle is the cheap mute.

For the full voice flow, see the dedicated [Voices](voices) page.

## Qwen 3: enable thinking mode

Toggle `<think>…</think>` reasoning passthrough for Qwen3 models. The trace is stripped from the persisted reply text before retrieval, summary, or the chunker see it. See [Templates](templates).

## Debug log

Not a setting in the sheet — but worth knowing about. RPClient writes a debug log to `$TMPDIR/rpclient-debug.log`. Tail it with `tail -f` from a Terminal when something looks off.

The `Debug → Fact extraction (eval)…` window in the menu bar is a separate diagnostic surface for inspecting raw extractor output without touching a real chat.

## Settings file format

`settings.json` is a single-file JSON document. Safe to inspect with `cat` / `jq`, and forward-compatible — unknown keys are ignored on decode and missing keys fall back to defaults ([Settings.swift:100](Sources/RPClientCore/Models/Settings.swift)). You can hand-edit while RPClient is closed.

## Worked example: moving the server

KoboldCpp now lives on a different machine on your LAN.

1. **Settings…** → **Server URL** → `http://other-machine.local:5001` (or the IP).
2. Save.
3. **File → Reload Server Info (⌘R)** to re-probe.
4. The status bar's leftmost label updates with the new model name. If it stays red, check the URL and confirm KoboldCpp is reachable on that host.

No restart needed.
