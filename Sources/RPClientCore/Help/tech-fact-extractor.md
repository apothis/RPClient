# Fact extractor

[Memory/FactExtractor.swift](Sources/RPClientCore/Memory/FactExtractor.swift). A grammar-constrained side-call that scans recent turns for state worth remembering and emits structured facts. Output goes to `Chat.pendingFactSuggestions` for user review, never directly to memory.

## Output shape

```swift
struct ExtractedFact: Equatable {
    var entityType: String   // "character" | "location" | "item" | "relationship" | "event"
    var entityName: String
    var fact: String
}
```

A `FactExtractionResult` wraps the facts plus diagnostic metadata (`rawText`, `parseError`, `promptChars`, `latencyMs`, `turnsScanned`, `knownBlockChars`). The `Debug → Fact extraction (eval)…` window reads these to inspect raw extractor output without touching a real chat.

## GBNF grammar

The grammar is the load-bearing piece. KoboldCpp applies it at sampling time, so the model **literally cannot** emit invalid JSON or invent new entity categories. From [FactExtractor.swift:36](Sources/RPClientCore/Memory/FactExtractor.swift):

```
root ::= "[" ws (entry (ws "," ws entry)*)? ws "]"
entry ::= "{" "\"entity_type\":" etype "," "\"entity_name\":" str "," "\"fact\":" str "}"
etype ::= "character" | "location" | "item" | "relationship" | "event"
```

Sampling-time constraint > prompt-engineered constraint. Without the grammar, ~15-20% of small-model outputs come back malformed JSON or with hallucinated category names like `"action"` or `"thought"`. With the grammar, parse errors are essentially zero.

## Instruction shape

The instruction at [FactExtractor.swift:45](Sources/RPClientCore/Memory/FactExtractor.swift) is iterated. Several decisions baked in:

1. **Past-tense declarative sentences.** "Sarah was wearing a green coat." not "Sarah is wearing…". Past tense matches the framing we want at injection time (the entity store represents historical state).
2. **High-priority categories called out.** Names, ages, appearance — these get stated once and never repeated, so they're explicitly listed as priorities.
3. **Off-stage / referenced characters.** Setup turns and stage-direction prose count as transcript; the extractor must not skip a character because they "haven't done anything yet."
4. **"Already known" awareness.** The prompt includes a block listing existing pinned facts and prior summary. The extractor is told not to re-emit knowledge already in there — but that an entity appearing in known facts does **not** mean all its attributes are known. Specific listed facts only.
5. **No moderation.** Fiction-state tracking — sexual, violent, taboo content is part of the story state. Omitting it produces wrong memory.

## Window

`lastN` defaults to **15 user turns**. The extractor walks backwards from the head, counting user messages, until 15 cycles are included. Assistant turns between and around them come along for free so the model sees complete dialogue context.

The cadence setting (every N user turns) is independent — the extractor *runs* every N turns but each run scans the last 15 user turns regardless. This redundancy is intentional: facts that drifted past on the previous run get a second look.

## Priority topics

Per-chat priority topics ([Chat.factExtractionPriorities](Sources/RPClientCore/Models/Chat.swift)) are appended to the instruction as soft hints — phrases like "relationships and prior history between named characters" — that steer the model's attention. Topics are **soft hints**, not filters: a fact about something not in the topics list still gets emitted if the model thinks it's important.

The reusable library lives in `Settings.priorityTopicLibrary`; per-chat lists are *copies* from the library so editing the library doesn't surprise active chats.

## Trust layer

The extractor is treated as a **junior collaborator**, not an oracle. The contract:

1. The extractor writes to `Chat.pendingFactSuggestions`.
2. The user reviews them in the Inspector → Suggestions pane.
3. Promotion (✓) appends the fact to `chat.memory` (pinned) or to the entity store (typed).
4. Dismissal (✗) drops the suggestion silently.

There is no auto-promote path. The extractor cannot pollute memory; the worst case is a backlog of unreviewed suggestions, which the Suggestions tab's unread badge surfaces.

## Trigger

- **Auto** — `AppState.maybeAutoExtract` after every user turn, gated by `factExtractionEnabled` and `factExtractionEveryNTurns`.
- **Manual** — Inspector → Extraction → **Run now**, or `Debug → Fact extraction (eval)…` for a stand-alone diagnostic run.

While running, `AppState.isExtracting = true` drives the activity spinner.

## Failure modes

- **`parseError` non-nil.** The grammar made this nearly impossible, but if it happens, `facts` is empty and the raw text is preserved on the result. The eval window surfaces this.
- **Empty array.** Legitimate result — the model decided nothing new happened. No suggestions are added.
- **Generation failure.** Side-call error; logged and ignored. Cadence picks up at the next user turn.

For the user-facing review flow, see [Suggestions & extraction](memory-suggestions).
