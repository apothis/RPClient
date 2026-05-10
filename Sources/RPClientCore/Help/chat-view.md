# The chat view

The middle pane is the chat view: a scrolling list of turns plus a context divider that visualises which turns will actually be sent to the model on the next request.

## Turns

Each turn is a card with the speaker name, the body text, and a small action footer that appears on hover. The body is rendered with light markdown — `**bold**`, `*italic*`, `` `inline code` ``, and fenced code blocks all work. Everything else is shown verbatim.

User turns appear right-aligned with a tinted bubble; assistant turns are full-width.

## Streaming

When you send a message, the assistant turn appears immediately and tokens fill in as the model produces them. Two things happen at the same time:

- The **status bar** bottom-right shows tokens-per-second and the cumulative prompt/reply totals for the chat.
- The input bar's send button turns into a red **stop** button. Click it to abort. Aborted turns keep the partial text — you can edit, regenerate, or delete from there.

## Editing a turn

Click any turn to open the edit affordance. You can:

- **Edit the body** — type your changes and confirm. If the edited turn is the latest assistant turn (and it isn't currently streaming), this is non-destructive.
- **Regenerate from this turn** — discards everything after this turn and re-runs the model from there. Useful for steering the conversation back on track.
- **Delete the turn** — removes it and everything after.

## Swipes (alternative continuations)

After an assistant reply lands, you can ask for an alternative without losing the original. Swipes are stored as variants on a single turn, not as separate branches.

- **⌘→** — next variant. If you're on the last existing variant, this generates a new one (up to a per-chat cap to keep storage sane).
- **⌘←** — previous variant.

The variant indicator on the turn footer shows `2 / 4`-style counts. A small **stale** badge appears on a variant if the chat has changed since it was generated (e.g. you edited an earlier turn) — that's a hint to regenerate before relying on it.

## The context divider

Somewhere along the chat there's a thin horizontal divider with a token count label. **Everything below the divider gets sent verbatim** in the prompt; everything above has been compressed into the rolling summary or dropped from the working window. Drag the divider to move the boundary if you want to force more (or less) verbatim history into the prompt.

If the chat is short enough to fit entirely in context, no divider appears.

## Speaker button

The chat header has a small speaker glyph just to the right of the template / preset / server pickers. It controls whether the next reply will speak through your default audio device:

- **Disabled (faded)** — the voice subsystem is off in `Settings… → Enable voice subsystem`. Enabling the subsystem activates the button.
- **Enabled (speaker icon)** — replies will speak.
- **Enabled (slashed speaker)** — replies are muted at the runtime level. Toggling this is a quick mute without unloading the engine.
- **Orange tint** — a reply is actively speaking right now. The colour clears when the reply finishes (or when speaking is interrupted by a new turn / chat switch).

For the full TTS story, see [Voices](voices).

## Empty state

A new chat with no turns shows an empty state with a hint. If you started the chat from a character card, the character's greeting (if any) is already populated as the first assistant turn — you don't see the empty state, you just type a reply.

## Worked example: rescuing a chat that drifted

The model went off-rails three turns ago. To get back on track without losing the early scene-setting:

1. Find the user turn just before things went wrong.
2. Click it to edit; tweak the wording to reinforce what you actually wanted.
3. **Regenerate from this turn**. Everything after is replaced.
4. If the new direction is also off, ⌘← / ⌘→ to flip through variants, or regenerate again on the same turn.

If the issue is a recurring tone problem rather than a one-shot detour, set an **author's note** instead — see the (forthcoming) Author's note page.
