# Voices

RPClient can speak assistant replies aloud. The TTS engine is **Kokoro 82M** running locally via ONNX Runtime — small, fast, and far better-sounding than the previous AVKit fallback. There is no cloud component; once the model and voices are downloaded, everything runs offline.

The voice subsystem is opt-in. Default install ships with the engine code but no model — you decide whether to enable it, where to store the model, and which voices to download.

## Quick start

1. Install **espeak-ng** (one-time, system-level): `brew install espeak-ng`. Required because Kokoro was trained on espeak-ng's IPA phonemes; no other G2P matches.
2. `Settings… → Enable voice subsystem`. The first time you tick this, RPClient asks where to put the model. Pick a folder (external SSD if you have one — the base model is ~325 MB and each voice is ~520 KB).
3. Click **Voice library…** in the Settings storage row. The window opens.
4. Download the **base model** (button in the row at the top of the table). Wait for it to finish.
5. Pick a voice from the table and click **Download** in its row.
6. Close the library. Send a message in any chat — the assistant reply will speak through your default output device.

## The two-tier toggle

There are two switches, deliberately separate:

| Toggle | Where | What it controls |
|---|---|---|
| **Enable voice subsystem** | `Settings… → Enable voice subsystem` | Whether the voice subsystem is active *at all*. Off = no model loading, no synthesis ever. The chat-header speaker button is disabled with a "subsystem off" tooltip. |
| **Speak replies** (active toggle) | Chat-header speaker button (next to the template / preset pickers) | Whether replies actually speak right now. Quick mute without unloading the engine. |

The split exists because loading the engine has a real cost (~325 MB resident, model warm-up on first speak). The subsystem toggle is "do I want this feature at all"; the runtime toggle is "should the next reply be silent because someone walked into the room."

The chat-header speaker button shows orange while a reply is actively speaking, so you always know whether the model is producing audio.

## Voice library window

Reachable from `Settings… → Voice storage row → Voice library…`. The window shows everything about the voice subsystem in one place:

- **Storage banner** — `Storage: ~/...`. The currently-configured model path, or "No storage location set" if none.
- **espeak-ng status** — `✓ found at <path>` (when present), or `◯ not installed` with a copy-paste `brew install espeak-ng` cell and a Re-check button.
- **Base model row** — the 82M Kokoro ONNX. State (`✓ ready` / `◯ not downloaded` / `⚠︎ volume unavailable`) plus Download / Cancel / Remove buttons.
- **Filter bar** — Language popup (All + 9 languages) + Gender popup (All / Female / Male) + voice count.
- **Voice table** — 54 voices with columns Voice / Language / Gender / State / Action.
- **Per-voice actions** — Download / Cancel / Remove. Voice download is disabled until the base model is `ready` (voices alone produce nothing).

You can browse the catalogue even when the subsystem is off — the window just shows "—" for state cells. This is intentional so you can survey languages before committing to download.

## Languages

54 voices across 9 languages (the espeak-ng voice mapping):

- American English (`en-US`), British English (`en-GB`)
- Spanish (`es`), French (`fr`), Italian (`it`), Portuguese-BR (`pt-BR`)
- Japanese (`ja`), Mandarin (`zh`), Hindi (`hi`)

Each is downloaded independently. Removing a voice only removes that one — the base model and other voices are untouched.

## Storage

The base model is ~325 MB; each voice is ~520 KB. Realistically you might end up with 20–50 MB of voices on top of the base model. RPClient writes to the folder you picked at first-enable; you can change it any time from `Settings… → Voice storage row → Change location…`.

If the volume goes away (e.g. unplugging an external SSD), the library window's banner turns to `⚠︎ volume unavailable` and per-voice rows show that state. Plugging the volume back in restores access without restart — the next save or library refresh picks up the path again.

## What gets spoken

Currently: **the latest assistant turn**, top to bottom, with markdown stripped and `<think>…</think>` blocks removed. The single-voice path doesn't do per-character attribution yet — that's planned for a later phase.

Speaking is interrupted on:

- Sending a new user message (you don't want the previous reply still going).
- Switching chats.
- Toggling either tier of the voice toggle from speaking to silent.
- App quit.

## When to leave it off

The voice subsystem is the heaviest non-network feature in the app. If you don't use TTS, leaving the subsystem unticked means **none** of the model is loaded — no resident memory, no warm-up cost. The default is off, deliberately.

## Worked example: setting up American English voices on first launch

1. `brew install espeak-ng` (terminal, one-time).
2. `Settings… → Enable voice subsystem`. The storage prompt appears with a few suggested locations from `VoiceStorageScout`. Pick one — an external SSD is ideal.
3. Click **Voice library…** in the Settings sheet.
4. **Base model row** — click **Download**. Watch the progress (~325 MB; on a fast connection, under a minute).
5. Filter Language → **American English (en-US)**.
6. Pick a voice (the catalogue has descriptive names — pick one that sounds appealing; you can always download more). Click **Download** in its row.
7. Close the library. The chat-header speaker button is now active.
8. Send a message. The reply speaks.

If anything fails along the way, see [Troubleshooting](troubleshooting) — the voice section there covers the most common issues (missing espeak-ng, volume disappeared, base-model checksum mismatch, etc.).

## See also

- [Settings](settings) — for the voice subsystem and storage settings.
- [Troubleshooting](troubleshooting) — voice failure modes.
- [tech-voices](tech-voices) — implementation: RPClientVoice target isolation, ONNX session, the espeak → tokenizer → engine → audio-player pipeline, download manager.
