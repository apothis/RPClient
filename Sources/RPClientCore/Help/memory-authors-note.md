# Memory: author's note

The author's note is a short free-text instruction injected near the **end** of the prompt, right before the model writes its reply. Where pinned facts and the summary sit at the top of the prompt and tell the model *what's true*, the author's note sits at the bottom and tells the model *how to write the next reply*.

It's the right tool for tone, pacing, and style — anything you want reinforced *just before* the model picks up the pen.

## Where it shows up

- **Inspector → Author's Note tab** — text field plus a depth stepper.
- **Status bar** — the **orange** segment of the context-fill bar is the note's contribution to the next-turn budget.
- **In the prompt** — placed at the configured depth before the model's turn.

## Depth

The depth value controls *how many turns from the end* the note is injected:

- **Depth 0** — placed immediately before the model's reply token. Strongest steering; the model has the note in its working set as it starts writing.
- **Depth 4** (default) — placed four turns from the end. The note influences the broader near-context, not just the next sentence.
- Higher depths — fade the influence further back into the conversation.

If you want the note to feel like an instruction to the model right *now*, use a low depth. If you want it to flavour an ongoing arc without becoming a hammer, raise the depth.

## What to put in it

Good author's notes are short, in second-person, and prescriptive about *style* not *content*:

- `Write the next reply slowly. Stay in the kitchen scene; emphasise small physical details.`
- `Keep replies under 80 words. Use short sentences. No internal monologue.`
- `Lean into dry humour. Avoid melodrama.`

Bad author's notes:

- Long world-building dumps — those belong in pinned facts or world info.
- Per-turn one-shots — just edit the user turn instead.
- Plot directives — the model will treat them as facts and try to *write* them happening, which usually feels heavy-handed.

## Author's note vs. pinned facts vs. world info

| Tool | When |
|---|---|
| **Pinned facts** | Always-true statements about the world / characters. Top of prompt. |
| **World info** | Lore that should appear *only* when relevant keys are mentioned. Mid prompt. |
| **Author's note** | How to write the next reply. End of prompt. |

If a fact keeps drifting away, pin it. If a faction's lore should appear only when its name is mentioned, put it in world info. If the model's tone keeps slipping, that's the author's note.

## Worked example: rescuing tone mid-scene

The model has been writing in fast-paced action-novel cadence and the scene has shifted to a quiet conversation. Replies still feel like a thriller.

1. Inspector → **Author's Note** tab.
2. Set text to: `Slow down. This is a quiet conversation, not action. Use longer sentences. Lean into pauses and small gestures.`
3. Set depth to **0** so the cue is right at the model's elbow.
4. Continue the chat.

When the scene wraps, you can either clear the note or raise its depth so its influence fades.
