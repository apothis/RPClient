# Memory: pinned facts

Pinned facts are short statements you want the model to know about, **always**. They are injected near the top of every prompt RPClient builds, ahead of the rolling summary and ahead of the per-turn extras. Use them for things that are timeless and load-bearing: a character's allergy, a setting constraint, a continuity rule.

Pinned facts live in the **Memory** tab of the inspector (right-hand panel). Press **⌘I** if the inspector is hidden.

## What to pin

Good pinned facts are:

- **Timeless within the chat.** "Sarah is allergic to cats" stays true. "Sarah just walked into the kitchen" does not — that belongs in the verbatim turns or the rolling summary.
- **Short.** One clause per fact. The cap on the whole pinned block is roughly 800 tokens; long entries crowd everything else out.
- **Load-bearing.** If the fact stops being true, edit it. If the model already remembers it from recent turns, you don't need to pin it.

Bad candidates: scene-of-the-moment narration, model-tone preferences (use the **author's note** for that), or anything that's already obvious from the character card.

## Adding a pinned fact

1. Open the inspector → **Memory** tab.
2. Type into the input field at the bottom and press **Add**.
3. New facts append to the end. Drag the row handle to reorder; the model reads them top-to-bottom, so put the most important first.

## Editing and removing

Click any row to edit it inline. Use the row's **×** to delete. Edits take effect on the next send.

## How they appear in the prompt

The pinned block goes near the top of the first user turn (Gemma) or in the system position (Qwen3) — same content, template decides the placement. The status bar's **Memory & entities** segment (blue) is what they're contributing to the next-turn budget.

If you have **Reinforce in latest user turn** enabled (Memory tab footer), pinned facts also get a brief restatement attached to the latest user turn — useful on long Gemma chats where attention has drifted away from the top of the prompt.

## Worked example: a character allergy

Your character keeps offering Sarah cat-food puns and the model never connects that Sarah is allergic to cats — the allergy lives 60 turns back in the rolling summary and the model isn't pulling it forward.

1. Inspector → **Memory** → Add: `Sarah is severely allergic to cats; even being near one triggers a reaction.`
2. Send the next turn.

From now on, every prompt includes that fact near the top. The model has a much harder time forgetting it.

If you find yourself pinning the same set of facts on every new chat with the same character, those facts probably belong in the **character card** instead — see Characters & personas (forthcoming page).
