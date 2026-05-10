# Quick start

RPClient is a chat client for one or more [KoboldCpp](https://github.com/LostRuins/koboldcpp) servers. Generation happens on whichever machine is running KoboldCpp — there is no cloud component and no account to sign into. This page gets you from a fresh install to a streaming reply in about two minutes; for a multi-machine setup see [Multi-server](multi-server).

## What you need

1. A running KoboldCpp server with a model loaded. The default RPClient setting points at `http://localhost:5001`, which is also KoboldCpp's default.
2. RPClient launched (via `./run.sh` during development, or by opening `RPClient.app`).

If KoboldCpp isn't running yet, start it first — RPClient probes the server on launch and the status bar will turn red until it can reach it.

## First chat

1. Look at the **status bar** along the bottom edge of the window. The leftmost text shows the model name and template (e.g. `gemma-3-12b · Gemma`). If it shows `—` or a red **server unreachable** marker, fix the server connection before continuing — see [Status bar](status-bar) for what each segment means.
2. Click **+ New** in the sidebar (top-left) and pick **New Chat**. A fresh, untitled chat appears.
3. Type a message into the input pill at the bottom. Press **Enter** to send (Shift-Enter for a newline).
4. Tokens stream into the chat as the model produces them. The send button becomes a red **stop** button while a reply is in flight — click it (or press Enter again) to abort.

That is the whole loop. Everything else — memory, characters, lorebooks, retrieval — is layered on top of this.

## Common next moves

- **Pick a sampler preset.** Go to `Settings… → Default sampler preset` to set one globally, or open the preset picker on a per-chat basis. The shipped presets cover most situations.
- **Match the template to the model.** If the sidebar shows a chat's template badge in red, the model RPClient detected doesn't match what the chat is configured to send. Switch templates via the per-chat selector or change the default in Settings.
- **Import a character.** `File → Import Character…` accepts SillyTavern v2 PNG cards or JSON. A new chat with that character pre-fills the persona, scenario, and first message — see the (forthcoming) Character cards & personas page.
- **Open the inspector.** Press **⌘I** or use `View → Toggle Inspector`. The inspector is the right-hand panel that exposes every memory layer.

## When something looks wrong

- **Replies are empty or repeat your prompt back.** The chat's template doesn't match the loaded model. Switch templates.
- **First reply is very slow on a long chat.** Normal once context exceeds the cache window — subsequent turns within the same chat will be much faster because KoboldCpp's SmartCache reuses the prompt prefix.
- **Status bar shows red.** RPClient can't reach the server. Check the URL in `Settings… → Server URL` and confirm KoboldCpp is running.

For deeper troubleshooting, see the dedicated Troubleshooting page (shipping in a later slice).
