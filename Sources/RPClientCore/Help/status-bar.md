# Status bar

The thin bar across the bottom of the window is a fixed-height status strip that tells you, in one glance, what the server is, how full the prompt is, and how fast tokens are arriving. It updates live during generation.

## Reading left to right

1. **Model · Template** — the model name reported by KoboldCpp followed by the prompt template the current chat is configured to use (e.g. `gemma-3-12b · Gemma`). If the server is unreachable, this turns red and reads **server unreachable**; the most recent error string is in the tooltip.
2. **Embeddings indicator** — if you have vector retrieval enabled, this shows the embeddings model name. Hidden when retrieval is off.
3. **Activity spinner & label** — appears when a side-call is running: `summarizing…`, `extracting facts…`, etc. The chat reply itself does not pop the spinner — the input bar's stop button is the indicator for that.
4. **Context fill bar** — coloured stacked bar showing how the prompt budget is allocated for the next request. See below.
5. **Context label** — `prompt-tokens / context-window` for the next send.
6. **Tokens-per-second** — measured from KoboldCpp's perf endpoint after each reply. Reset between turns.
7. **Cumulative totals** — `prompt-tokens / reply-tokens` for the current chat, summed across every turn. Useful as a rough cost / time-spent gauge.

## The context fill bar

The bar is stacked, with each colour standing for one slice of the upcoming prompt. Hover any segment to see its label and exact token count. The colours, in left-to-right order:

- **Blue — Memory & entities.** Pinned facts and any entity facts the entity store decided to put on stage.
- **Purple — Summary.** The rolling auto-summary plus any frozen scene summaries.
- **Teal — World info.** Keyword-triggered lorebook entries that fired for this turn.
- **Orange — Author's note.** Style/scene cues injected near the end of the prompt.
- **Grey — Template overhead.** Role markers and any scaffolding the template adds.
- **Green — Verbatim turns.** Recent user/assistant messages sent in full.
- **Pink — Retrieval.** Vector-search hits attached to the latest user turn.
- **Dim red — Reply reserve.** Tokens held back so the model has room to reply without truncating itself.

If the bar is mostly green, your verbatim history dominates. If the bar is mostly purple, the summary is doing most of the work — that's the natural shape of long chats. If the bar is mostly red, you're nearly out of room and the next turn will probably trigger a summarizer pass.

## Server unreachable

When RPClient can't reach the configured KoboldCpp server, the leftmost text turns red and a one-shot warning sheet pops the *first* time it goes from reachable to unreachable. The status bar's red marker stays up continuously after that — there is no need to dismiss it. Once the server comes back, the marker clears automatically.

## Worked example: spotting an imminent summarize

You're 40 turns into a chat. Glance at the bar:

- Verbatim (green) is creeping past 60% of the bar.
- Summary (purple) is small.

Next user turn, you notice the activity spinner says `summarizing…` and the green slice shrinks while the purple slice grows. That is the rolling summarizer compressing older turns into the summary so the verbatim window can keep advancing. After it finishes, the chat continues normally — the only side-effect you should see is a new entry in the inspector's **Summary** pane.
