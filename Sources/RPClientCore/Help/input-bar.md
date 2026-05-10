# Input bar & token cap

The input pill at the bottom of the window is where you type messages and where you stop generation. It's intentionally minimal — one text field, one button.

## Sending

- **Enter** sends.
- **Shift-Enter** inserts a newline.
- The send button is the round arrow on the right. It's only enabled when the field has non-whitespace content.

The send button changes appearance based on what the app is doing:

- **Blue arrow** — idle, has text. Click or press Enter to send.
- **Grey arrow** — idle, no text. Disabled.
- **Red stop circle** — busy. The model is streaming a reply, the summarizer is running, or the fact extractor is running. Click to abort whichever is in flight.

While anything is busy, Enter triggers the same stop action. You can still type into the field — your draft survives the abort.

## Per-reply token cap

By default each reply is bounded by the active sampler preset's `max_length`. Sometimes you want a one-off override — a single short reply, or a single long one — without editing the preset.

Set **Settings… → Reply token cap (0 = preset)** to override the cap. The override is global across chats. Set it to `0` to fall back to the preset.

A common pattern:

1. Set the cap to `120` for fast-paced dialogue.
2. Bump it to `0` (preset default, often 400+) when you want the model to write a longer descriptive passage.

The cap only applies to *replies* — summarizer and fact-extractor side-calls have their own internal limits.

## Drafts

The text field doesn't persist drafts across app launches. If you close the window mid-thought, the draft is gone. (This is a deliberate v1 trade-off — drafts may land in a later slice.)

## Worked example: stopping a reply that's gone too long

The model is mid-monologue and clearly past the natural beat. To cut it short without losing what's there:

1. Click the red **stop** button (or press Enter, since the field is empty).
2. The stream halts; the partial text stays in place as the latest assistant turn.
3. If the cut is awkward, click the turn to **edit** and trim the trailing fragment, or **regenerate** with a tighter cap (Settings → Reply token cap) to ask for a more concise take.
