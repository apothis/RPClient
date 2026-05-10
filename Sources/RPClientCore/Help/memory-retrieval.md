# Memory: retrieval

Retrieval is RPClient's vector search over the chat's own history. When enabled, every user turn embeds the user message and looks for past chunks of the chat that are semantically close. The top hits are attached to the prompt as a small "Recall" block — a reinforcement aid, not a source of truth.

It's the right tool for: *the model just forgot a specific detail from 30 turns ago and the rolling summary glossed over it*.

## Where it shows up

- **Inspector → Retrieval tab** — status (chunks indexed, last query, hits and their scores), and a **Re-index now** button.
- **Status bar** — the **pink** segment is what the retrieved hits cost in tokens this turn. Only present when retrieval is on and hits cleared the cosine threshold.

## Requirements

Retrieval is **off by default**. To turn it on:

1. Run KoboldCpp with an embeddings model loaded (`--embeddingsmodel <path>` on the server side).
2. RPClient → `Settings… → Retrieval` → **Enable vector retrieval**.
3. Tune **Top-K hits**, **Cosine threshold (0–1)**, and **Exclude last N turns** — see below.

If KoboldCpp doesn't have an embeddings model, RPClient detects this and the retrieval pane shows the reason it isn't running.

## Settings

| Setting | What it does |
|---|---|
| **Enable vector retrieval** | Master switch. |
| **Top-K hits** | Maximum number of chunks attached per turn. Default `4`. |
| **Cosine threshold** | Hits below this score are filtered out. Default around `0.7`. Lower = more recall, more noise. |
| **Exclude last N turns** | Skip the most recent turns when matching. Stops the engine from "retrieving" content that's already verbatim in the prompt. Default `8`. |

## Eligibility

A chunk is eligible to be retrieved if **both**:

1. Its `lastTurnIdx` is below the recency cutoff (`head − exclude-last-N`).
2. Its `lastTurnIdx` is below the rolling-summary cutoff (`summarizedThrough`).

Translated: a chunk only enters retrieval once it's been *both* old enough and *also* compressed away by the summarizer. Until those two cutoffs cross it, the chunk is still in the verbatim window and there's nothing to retrieve.

This is the usual reason a fresh chat shows `0 chunks indexed` even when retrieval is enabled — the rolling summary hasn't advanced yet.

## What the pane shows you

The Retrieval pane is mostly diagnostic. It tells you, for the latest query:

- How many chunks are currently indexed.
- The query embedding's nearest neighbours and their scores.
- Which hits cleared the threshold and made it into the prompt.
- The reason a chunk isn't eligible, if you click into one.

## When retrieval helps and when it doesn't

It **helps** when:

- The chat is long enough that older details are summarized away.
- The user's message is specific enough that a vector hit is meaningful.

It **doesn't help** when:

- The chat is short (everything is still verbatim).
- The user's message is generic ("what now?", "tell me more"). The embedding will match too many things and the threshold filters them all out.
- The fact you want surfaced is a *future* development the model is improvising — retrieval is over the chat history, not over future state.

## Worked example: nudging the model to remember a specific NPC name

40 turns ago you spoke to a barkeep named Hilda. The model has long forgotten her, the rolling summary lumped her into "the inn", and now you write `we should circle back and ask the barkeep what she said about the locked door`.

1. Make sure retrieval is on and the chat has been running long enough that the early scenes have summarized away (Retrieval pane shows non-zero chunks indexed).
2. Send the message.
3. Open the Retrieval pane after the reply lands. The pane should show the original Hilda scene as a hit.
4. If it didn't fire, lower the cosine threshold a notch and send a follow-up turn — `the barkeep, the one named Hilda` is more embedding-distinctive.

If retrieval still misses a fact you really want kept, that's a sign the fact should be **pinned** instead.
