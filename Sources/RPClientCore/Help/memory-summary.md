# Memory: rolling summary

The rolling summary is RPClient's automatic compression of older turns into a paragraph or two of prose. Once the chat outgrows the verbatim window, the summarizer picks up the oldest turns that no longer fit, asks the model to summarise them, and stores the result.

The summary is not a transcript — it is a *recap*. It is authoritative for the immediate prior period, in the way a "previously, on…" intro is authoritative.

## Where it shows up

- **Inspector → Summary tab** — the current summary text, editable.
- **Status bar** — the **purple** segment of the context-fill bar is the summary's contribution to the next-turn budget. The cap is roughly 350 tokens.
- **In the prompt** — placed near the top of the first user turn, just below the pinned facts and any frozen scene summaries.

## When it triggers

The summarizer is a separate side-call to the model. It runs automatically when the verbatim turn count exceeds an internal threshold relative to your context window. The status bar's activity spinner shows `summarizing…` while the call is in flight; it does **not** block your next reply unless you send while the call is still running.

You can force it to run on demand: **File → Summarize Now** (**⇧⌘S**). Useful when you're about to start a new arc and want the prior arc condensed before the next user turn fires.

## Editing the summary

Click into the **Summary** pane and type. The summary is just a string — you own it. Edits persist and feed the next prompt.

When to edit by hand:

- The summarizer drifted (treated a side joke as a major plot beat).
- You want to nudge the framing — e.g. shorten the recap before a tone change.
- You moved the chat into new ground and the auto-summary is still anchored on the old arc.

When **not** to edit:

- Don't use the summary as a scratchpad for facts you want kept indefinitely. Pin them instead.
- Don't paste a transcript back in. The summary is a recap by design.

## Scene summaries

A more rigid cousin: when a scene wraps and a new arc begins, the chat captures a **frozen scene summary** that survives even after newer turns push the rolling summary forward. Scene summaries are framed in the past tense ("Earlier in the story — completed arc 2, turns 14–32") and decoupled from "where are we now."

You don't manage scene summaries directly today — they're produced when you mark a scene break. (UI for managing them is on the long-tail list; for now, scene-break marking happens via the summarizer's natural triggers and the entity-store dedup pipeline.)

## Worked example: pre-empting a summarize before a tone shift

You're 35 turns in, the early chapter is wrapping, and you want to start a new dynamic without the model still echoing the opening tone.

1. **File → Summarize Now**. Wait for the spinner to clear (a few seconds).
2. Inspector → **Summary** tab. Read what landed. Tighten or rephrase if needed.
3. Optionally pin one or two facts the summary glossed over but you want kept on stage.
4. Send the first user turn of the new arc.

The model now opens with a clean recap of what came before instead of a long verbatim tail mixing tones.
