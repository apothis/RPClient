# Troubleshooting

A field guide to the symptoms you'll most plausibly hit, and the fix or diagnostic step for each.

## Server unreachable

**Symptom.** Status bar's leftmost label is **red** and reads `server unreachable`. A one-shot warning sheet popped the first time it went red.

**Check, in order:**

1. KoboldCpp is actually running. From a terminal: `curl http://<host>:<port>/api/v1/model`.
2. The URL in `Settings… → Servers` matches where KoboldCpp is listening. If you've configured multiple servers, the failing one is **whichever the active chat is using** — `(use default)` resolves to `Settings → Servers → Default (chat)`; a per-chat pin uses that pinned profile. Hit **Test** on the row to probe just that profile.
3. If KoboldCpp is on another machine, the host is reachable: `ping`, then `curl` against the same URL.
4. **File → Reload Server Info (⌘R)** to force a re-probe without restarting.

The status-bar marker clears automatically once a probe succeeds.

If you have multiple servers configured and only **side-calls** are failing (summarizer / extractor / embeddings) but the main reply works, the role-assignment popup for that side-call is pointing at a dead profile. See [Multi-server](multi-server).

## Empty replies / model echoes the prompt

**Symptom.** The assistant turn appears, but it's empty, or it just repeats your message back.

**Cause:** The chat's template doesn't match the loaded model. Look at the sidebar — the chat's template badge is probably **red**.

**Fix.** Switch templates from the chat header. See [Templates](templates) for which to pick.

## Reply cut off mid-sentence

**Symptom.** The model stops generating partway through a sentence.

**Causes, most common first:**

- **Reply token cap is too low.** Check `Settings… → Reply token cap` — if it's a small number, that's the ceiling. `0` falls back to the sampler preset's `max_length`.
- **Wrong template.** A stop sequence is firing earlier than it should. Switch templates.
- **Genuine end.** The model produced an end-of-turn token because it thinks the reply is done. Click **continue** on the assistant turn (or press Enter on an empty input field while the partial reply is still selected) to ask it to keep going.

## First reply on a long chat is very slow

**Symptom.** The first turn after opening a chat takes seconds before tokens start flowing; subsequent turns are fast.

**Cause.** KoboldCpp's KV cache was cold. RPClient's [prompt assembly](tech-prompt-assembly) is cache-aware, so reuse only kicks in turn-over-turn within the same session.

**Fix.** Nothing — this is expected. Subsequent turns within the same session will reuse the prompt prefix. If even *those* are slow, the cache is being invalidated every turn, which usually means a stable block (memory, summary, scene summaries) is changing more than it should. The most common culprits:

- The rolling summarizer is running every turn (cadence is too aggressive).
- Pinned facts are being edited per turn.
- A world-info entry with `injectionMode: always` carries a high-volatility key that flickers in and out.

## Garbled / nonsense output

**Symptom.** Replies are word salad, broken UTF-8, or full of repeated tokens.

**Causes:**

- **Wrong template** (most common). Switch.
- **Sampler temperature too high.** Try a more conservative preset (`Precise`).
- **Model itself is broken.** Some quantised models repeat tokens forever past a certain context length. Lower **Max context** in Settings to below the failure point.

## The model loops the same line

**Symptom.** `they walked in. they walked in. they walked in.`

**Fix.** Raise **rep-pen** in your sampler preset (try 1.10), and check **rep-pen range** is at least 512. If it persists, the loop is usually a model-quantisation issue rather than a sampler one — same fix as garbled output (lower max context, try a different model).

## Out of context

**Symptom.** Status bar's context fill bar is mostly red; the next reply gets weirdly truncated or the model loses track of recent details.

**Causes & fixes:**

1. The chat has outgrown its budget and the leading verbatim turns are being dropped. Look at the chat view — the **context divider** marks where the cut would land. Either accept the cut or raise the **Max context** setting (if KoboldCpp can serve a larger window).
2. The summarizer hasn't kept up. **File → Summarize Now (⇧⌘S)** to force a pass.
3. The pinned facts list has grown too large. The cap is ~800 tokens; long entries crowd everything else out.

## Inspector pane is empty / shows wrong chat

**Symptom.** You opened the inspector, switched chats, and the pane is showing data from the wrong chat (or shows empty when there should be data).

**Fix.** Probably a notification ordering bug. Switch tabs and switch back, or switch chats and switch back. If it persists, file an issue with the steps that reproduce it — this is the kind of bug that's easy to fix once it's repro'd reliably.

## The fact extractor / summarizer is silent

**Symptom.** You expect a side-call to fire and it never does.

**Check:**

- For the **summarizer**: it fires when the verbatim window outgrows the budget. On a short chat there's nothing to compress. **File → Summarize Now (⇧⌘S)** force-runs it.
- For the **fact extractor**: cadence is N user turns. If you've sent 1 and N=4, it won't fire yet. Inspector → **Extraction** → **Run now** force-runs it.
- KoboldCpp must be reachable. A red status bar means side-calls fail silently.

The activity spinner in the status bar shows when a side-call is in flight. If you trigger one and the spinner doesn't appear, it didn't actually fire.

## Retrieval shows "0 chunks indexed"

**Symptom.** You enabled retrieval, the chat has plenty of history, and the Retrieval pane shows `0 chunks indexed`.

**Cause.** The eligibility predicate. A chunk is eligible only when its turn index is below **both** the recency cutoff (`head − exclude-last-N`) and the rolling-summary cutoff (`summarizedThrough`). On a fresh chat the rolling summary hasn't advanced yet, so nothing is eligible.

**Fix.** Wait for the summarizer to fire (or force it with ⇧⌘S). Once the summary advances, the chunks behind that boundary become eligible.

See [Retrieval](memory-retrieval) for the full eligibility logic.

## Debug log

Most diagnostics — request payloads, side-call timings, error strings — get written to `$TMPDIR/rpclient-debug.log`. Tail it from Terminal:

```
tail -f $TMPDIR/rpclient-debug.log
```

Most of what's in there is uninteresting; the bits that matter are stack traces from caught errors and the per-request timing breakdowns.

## Voices

### "Speak replies" button is greyed out

**Cause.** The voice subsystem is off. The chat-header speaker button is disabled until `Settings… → Enable voice subsystem` is ticked.

**Fix.** Enable the subsystem in Settings; the button becomes active. If it's still disabled after that, see the next item.

### Voice subsystem is on but nothing speaks

**Check, in order:**

1. **espeak-ng installed?** Open `Voice library…` from the Settings storage row. The top status row reads `✓ found at <path>` if installed, or `◯ not installed` with a copy-paste `brew install espeak-ng`. Without it, only the AVKit fallback voices work; Kokoro voices are silent.
2. **Base model downloaded?** Same window, base-model row. State should read `✓ ready`. If not, download it (~325 MB).
3. **At least one voice downloaded?** Per-voice rows show their state. Voice download is disabled until the base model is ready (the engine is useless without it).
4. **Volume reachable?** If the storage path is on an external drive that's been unplugged, the banner reads `⚠︎ volume unavailable`. Replug, or `Change location…` to a different path.

### Base-model download fails repeatedly

**Cause.** Most often a SHA-256 mismatch — the partial download didn't match the canonical hash. The download manager discards the temp file and marks the task failed rather than installing a corrupt model.

**Fix.** Click **Download** again on the base-model row. The retry starts fresh. If it keeps failing, your network is rewriting the file in transit (corporate proxy, captive portal) or HuggingFace served a different artifact — try from a different network.

### Wrong voice plays

**Cause.** The single-voice path always uses the configured "current" voice. Per-character attribution (different voices for different speakers in a turn) is a future feature; the codebase is not there yet.

**Fix.** This is by design today.

## Side-call ran on the wrong server

**Symptom.** You configured a small fast model for summaries, but the summarizer is clearly running on your main workstation.

**Cause.** The role popup for that side-call is set to `(use default)`, or the assigned profile was deleted (in which case the resolver falls back to the default — see [Multi-server](multi-server)).

**Fix.** `Settings → Servers` → set the role popup to the intended profile. Save.

## Where settings and chats live

Sometimes the right fix is "delete the file." The relevant paths:

```
~/Library/Application Support/RPClient/
├── settings.json          ← can hand-edit while RPClient is closed
├── chats/<uuid>.json      ← one per chat
├── vectors/<uuid>.json    ← per-chat vector store; safe to delete to force re-index
├── characters/            ← imported cards
└── personas/              ← user personas
```

Atomic writes mean you can't end up with half-written files, but you *can* end up with a chat in a state RPClient struggles to load. Quitting, fixing the JSON, and relaunching is sometimes the right move.
