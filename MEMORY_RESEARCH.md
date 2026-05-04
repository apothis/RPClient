# Memory architecture research — V2 scoping

This document evaluates the ten memory-retention ideas in `PLAN.md` §9 against current state-of-practice (May 2026). Each item gets one of four verdicts: **Adopt** (build into V2), **Experiment** (cheap prototype to validate before committing), **Defer** (revisit later), **Reject** (not worth the cost in our stack).

The MVP already ships: pinned-fact memory, single rolling summary with auto-trigger at 70% ctx, token-budgeted prompt assembly with truncation, author's-note injection at fixed depth. This doc is about everything beyond.

---

## TL;DR — V2 scope

**Adopt now (high confidence, modest implementation cost):**

1. **Vector retrieval over chat history** (§9.1) — using koboldcpp's *own* embedding endpoint (no sidecar) + sqlite-vec or flat in-memory cosine.
2. **Prompt-cache awareness** (§9.10) — operational rules baked into prompt assembly. The single highest-leverage thing in this doc.
3. **Per-AN-entry depth** (§9.5) — small UI change, large quality impact.
4. **Style block** (§9.8) — separate prompt slot, manual-first.
5. **Tail-injection memory reinforcement toggle** (§9.6) — fixes Gemma's first-turn-fold drift cheaply.
6. **Cross-chat persistent memory schema** (§9.9) — file layout only; manual promotion.

**Experiment in V2 (prototype, gate full adoption on results):**

7. **Manual scene-break button + scene-summary array** (§9.2 reduced) — 80% of tiered summarization without scene-detection complexity.
8. **Entity fact store with grammar-constrained extraction** (§9.3 reduced) — mem0's *pattern* without the Python/Qdrant/Neo4j footprint.

**Defer:**

9. **Salience/decay scoring** (§9.7) — build the data fields; skip auto-eviction until needed.

**Reject (for now):**

10. **Full MemGPT/letta-style self-managed memory** (§9.4) — local 8–12B tool-call reliability isn't there yet, infra footprint is heavy. Revisit when 32B+ is our default. *Tiny version of the idea — single `remember(fact)` tool via kobold's function calling — is folded into §9.3 as the extraction mechanism.*

---

## What our stack can actually do (verified)

These facts changed my recommendations vs. the original plan; flagging them up front.

- **KoboldCpp has had a first-class embeddings endpoint since v1.87 (April 2025).** Load any GGUF embedding model with `--embeddingsmodel <path>`; it serves on `/v1/embeddings` and `/api/extra/embeddings`. Configurable max-ctx via `--embeddingsmaxctx`; optional GPU offload via `--embeddingsgpu` (note: minimal speedup on small embedding models — keep on CPU). The `"embeddings": false` we saw on `/api/extra/version` just means no embedding model was loaded for that session — *the capability is there*. Sources: [KoboldCpp Wiki](https://github.com/LostRuins/koboldcpp/wiki), [v1.87 release](https://newreleases.io/project/github/LostRuins/koboldcpp/release/v1.87).
- **Context Shifting is default-on**, not opt-in. When the prompt overflows ctx, kobold slides the window and preserves KV state for the surviving prefix. `--smartcache` is *additionally* opt-in for snapshotting *across* contexts (multiple chats / persona swaps / RNN+hybrid models like Qwen3-Next). Use `--noshift` to disable. Source: [KoboldCpp issue #1956](https://github.com/LostRuins/koboldcpp/issues/1956).
- **KoboldCpp supports OpenAI-compatible function calling** with auto-applied GBNF grammar to constrain output JSON. Tools sent in OpenAI format are ingested into the prompt; the response grammar is generated automatically; `tool_choice: "forced"` constrains to a single tool. GBNF grammar sampling is also exposed standalone. Sources: [KoboldCpp PR #981](https://github.com/LostRuins/koboldcpp/pull/981), [Wiki](https://github.com/LostRuins/koboldcpp/wiki).
- **sqlite-vec** is alive in 2026 (latest 0.1.9, March 2026), brute-force search only — no HNSW/IVF/DiskANN yet. At our scale (low tens of thousands of vectors at 384–768d) brute force on Apple Silicon is sub-50ms; HNSW absence is a non-issue for V2. Source: [sqlite-vec releases](https://github.com/asg017/sqlite-vec/releases).

The combination of these three is significant: **embeddings + structured tool calls + grammar constraints are all available in-process from our existing kobold server, with no extra daemons.** Most of section 9's "we'd need a sidecar" caveats dissolve.

---

## §9.1 — Vector / semantic retrieval over chat history

**Verdict: Adopt.** This is the highest-impact item in the doc.

### Findings

The pattern is well-established. Open WebUI ([docs](https://docs.openwebui.com/features/chat-conversations/memory/)) and SillyTavern's Vector Storage ([docs](https://docs.sillytavern.app/extensions/chat-vectorization/)) both implement essentially the same flow:
1. Chunk the chat history (per-turn or rolling N-message windows with overlap).
2. Embed each chunk; store in a vector index keyed to chat id.
3. On each generation, build a query from the last 1–2 messages, embed, retrieve top-K above a similarity threshold, *exclude chunks whose source messages are in the most recent window*, and inject either as a "Relevant earlier moments" block or by reordering history.
4. SillyTavern's Vector Storage explicitly supports koboldcpp embeddings as a backend ([PR #3795](https://github.com/SillyTavern/SillyTavern/pull/3795)).

Open WebUI defaults to `all-MiniLM-L6-v2` running on CPU. The retrieval process filters by user.id and applies a relevance threshold; with native tool calling enabled, the model can also actively manage its memory via five built-in tools (an Open WebUI feature called "Memory Tool"; community-built [Adaptive Memory v3](https://openwebui.com/f/alexgrama7/adaptive_memory_v2) extends this).

Failure modes documented across all implementations:
- **Off-topic pollution** is the #1 issue. Top-K=5 with no threshold dredges up unrelated old turns and derails the model. Always combine threshold + K cap.
- **Retrieval echo:** if you don't exclude the recent window from the retrieval pool, you'll retrieve the user's own recent statements. Always set a recency exclusion.
- **Chunking granularity:** per-turn is too small for chat (queries match on filler words); rolling 3–5 message windows work better.
- **Index invalidation on edit:** if a turn gets edited or regenerated, the chunk containing it must be re-embedded.

### Recommendation for our app

**Use kobold's own embedding endpoint.** Eliminates the sidecar dependency entirely. User launches kobold with `--embeddingsmodel ./bge-small-en-v1.5.gguf` (or nomic-embed-text); we hit `/v1/embeddings`.

Concrete plan:
- **Default model: bge-small-en-v1.5** (384d, ~130MB) for strong English quality at small footprint. **Alternative: nomic-embed-text-v1.5** (768d, ~270MB, Matryoshka — truncatable to 256d for storage savings) when multilingual or longer context matters.
- **Storage: sqlite-vec** behind GRDB.swift, or — at our likely scale (a single-user RP client probably accumulates <50k chunks even over months) — flat float arrays with `vDSP` cosine. Either is fine; sqlite-vec is the more future-proof choice if we expect to ship to other users.
- **Chunking:** rolling 4-message windows, 1-message overlap. Store `(chunkId, chatId, firstTurnIdx, lastTurnIdx, text, embedding, contentHash)`.
- **Query construction:** embed `lastUserMessage + previousAssistantMessage` (concatenated) at prompt-build time.
- **Retrieval:** top-K=5, cosine threshold ≥ 0.55 (tune per-model), exclude chunks whose `lastTurnIdx > totalTurns - 20`, dedupe.
- **Injection point:** *after the cache boundary* — see §9.10. As a "Relevant earlier moments" block sitting between the verbatim recent turns and the rolling summary's tail. Critically: **placement must be cache-aware.**
- **Chunk lifecycle:** when a turn is edited, look up chunks where `firstTurnIdx ≤ turn ≤ lastTurnIdx` and re-embed. When a turn is deleted, remove + re-window.
- **UI:** show a small "Relevant memories" expandable below each assistant turn, listing which chunks were retrieved + their similarity score. Lets the user audit retrieval and dial the threshold.

### Open questions

- Empirical threshold tuning per embedding model — needs a small test corpus. bge-small's 0.55 may need to drop to 0.50 for nomic.
- Whether kobold's embedding endpoint accepts batch input efficiently or requires per-chunk calls — affects rebuild speed for long chats.

---

## §9.2 — Hierarchical / tiered summarization

**Verdict: Experiment (reduced scope).**

### Findings

Canonical academic anchor: [Wu et al. 2021 "Recursively Summarizing Books with Human Feedback"](https://arxiv.org/abs/2109.10862) — chunk a long doc, summarize leaves, summarize summaries. Maps to chat as scenes → acts → arc.

Practitioner state: SillyTavern's built-in Summarize extension is single-rolling (like our MVP); community extensions (Memory Books / qvink-memory family) do scene/chapter level but typically chunk by token threshold rather than detecting scene boundaries semantically. mem0 is *not* hierarchical; letta's hierarchy is by access pattern (core/recall/archival), not narrative compression.

Scene-boundary detection options:
1. **Token/message threshold** (simplest): every N messages, summarize.
2. **Time-jump regex**: detect "the next morning", "three days later", "meanwhile" — cheap, low recall.
3. **Cheap classifier prompt**: side-call to local model with last ~10 turns, "Did the scene change? Y/N + 1-line reason." Reliable on Gemma 4 / Qwen 3 at 4B+, but cost is one short prompt per N turns.
4. **Embedding-shift**: cosine distance jump between sliding windows flags boundary (TextTiling-style). Adds embedding dependency we'd already have.
5. **Explicit user marker**: a "new scene" button. Highest precision, lowest tech.

### Recommendation

For our 8k–32k models in chat-length sessions, the marginal gain over the current rolling summary is modest until users hit very long arcs. Start with the lowest-cost mechanism that captures most of the benefit:

- **Add a manual "Scene break" button** that freezes the current rolling summary into an immutable `scene_summaries: [String]` array on the chat, and starts a fresh summary. Zero-side-call, zero ambiguity.
- **Assembly:** inject the most recent K scene summaries (say K=3) plus the live rolling summary plus the verbatim recent turns. Older scene summaries get further compressed (re-summarize-the-scene-summaries side-call) only when the array exceeds N entries.
- **Defer auto-detection** until we see whether users actually press the button. If they don't, we add the cheap-classifier approach as a "suggest scene break" prompt that surfaces a one-click confirmation.

This is 80% of the value of full tiered summarization for ~10% of the implementation cost.

### Open questions

- Whether re-summarizing summaries causes appreciable fact drift versus re-summarizing from raw turns. Our SQLite chat history makes raw re-summarization cheap; we might just always do that.
- Do users naturally segment their RP? We won't know until we ship the button.

---

## §9.3 — Entity / knowledge-graph memory

**Verdict: Experiment (reduced scope).**

### Findings

[mem0](https://github.com/mem0ai/mem0) is the reference: two-LLM architecture (extraction LLM identifies fact candidates from new turns; update LLM compares against existing store and emits ADD/UPDATE/DELETE/NOOP — that's the contradiction-detection mechanism). Storage is *freeform fact strings* keyed to user/agent IDs, not a rigid entity-attribute schema. Hybrid search: dense embeddings + BM25 keyword + entity linking. Active in 2026 (315 releases, last April 2026); self-hostable via Docker with Qdrant + optional Neo4j + Ollama as full local stack ([self-host docs](https://mem0.ai/blog/self-host-mem0-docker)).

Self-hosted mem0 is heavy for a single-user Mac app: requires Docker + Qdrant + Postgres or Neo4j + an LLM endpoint. Doable but a lot of moving parts. The *pattern*, however, is the right target.

[Letta](https://github.com/letta-ai/letta) memory blocks are user-named text (e.g. `human`, `persona`); not entity-typed by default. Closer to "scratchpad with sections" than "entity DB."

SillyTavern's [World Info / Lorebook](https://docs.sillytavern.app/) is keyword-triggered manual entries. Auto-lorebook community extensions exist but have a reputation for noisy duplicates — they show the cost of automation without contradiction detection.

Schema rigidity tradeoff:
- **Rigid schema** (`Character{name, traits[], relationships{}, status}`): better for prompt assembly, worse for extraction quality with weaker models — they drop info or wrong-slot it.
- **Freeform fact-per-entity** (mem0's choice): more robust extraction, prompt assembly bloats unless capped.
- **Hybrid that works in practice:** freeform facts indexed by entity ID, plus a small required slot per entity type (e.g. `current_status` overwritten on update).

### Recommendation

Don't run mem0 as a sidecar. Implement the *pattern* natively in Swift:

- **Storage:** add an `entities` table to the chat JSON (or a separate per-chat sqlite if we move there). Schema:
  ```
  Entity { id, type: character|location|item, name, aliases[], facts: [Fact] }
  Fact { id, text, addedTurn, lastSeenTurn, source: extracted|userPinned }
  ```
- **Extraction:** every N turns (default 4) or on scene break, side-call to kobold with an OpenAI-format function call (`record_entity_fact(entity_name, entity_type, fact_text)`) using kobold's native [function calling support](https://github.com/LostRuins/koboldcpp/pull/981). The auto-applied GBNF grammar enforces clean JSON — this is the load-bearing piece that makes local-model extraction tractable.
- **Update:** simple append-with-supersedes for V2. If a new fact about an entity contradicts an old one, append both and inject the most recent N. Skip mem0's UPDATE/DELETE LLM-judge step until we see drift become visible.
- **Injection:** keyword/alias-triggered, World-Info-style. When entity name or alias appears in last K turns, inject that entity's most recent N facts into the prompt. Cheap substring match, no embedding round-trip needed for retrieval.
- **UI:** "Entities" tab in inspector, grouped by type, with manual edit/pin/delete. Important for trust — users will want to see and control what's stored.

### Open questions

- Tool-call reliability for entity extraction on Gemma 4 12B / Qwen 3 14B with grammar constraints. Worth a benchmark on a 100-turn RP transcript before committing. Existing comparisons ([Gemma 4 vs Qwen 35B tool calling](https://docs.bswen.com/blog/2026-04-03-gemma-4-vs-qwen-35b-tool-calling/)) suggest Qwen 3.6 is more reliable on nested params; Gemma 4 is faster but shakier on complex calls.
- Whether keyword/alias injection is enough or if entity recall via embeddings is needed (e.g. "the knight" referring to Alice without naming her). Tentatively start with keyword; add embedding fallback if drift shows up.

---

## §9.4 — MemGPT / letta-style self-managed memory

**Verdict: Reject for V2.**

### Findings

[MemGPT paper](https://arxiv.org/abs/2310.08560) gives the model function-call tools (`core_memory_append`, `core_memory_replace`, `archival_memory_insert`, `archival_memory_search`, `conversation_search`) and lets it decide when to invoke them. Three-tier architecture: core (always-in-context, small, model-edited), recall (full conversation log, searchable), archival (vector DB for arbitrary writes).

[Letta](https://github.com/letta-ai/letta) is the productized version — Postgres-backed agent server with REST/Python/TS clients, Docker deployment. Their README explicitly recommends "Opus 4.5 and GPT-5.2 for best performance," signaling local-model support is best-effort. Memory blocks are user-named text; not entity-typed.

The central problem with this approach for our stack is **local-model tool-call reliability under sustained agent loops**:
- The MemGPT paper relied on GPT-4. The original paper notes degradation on smaller models.
- Community consensus through 2025–2026 is that this approach needs a model with *strong native tool calling* — practical lower bound is ~32B (Qwen 3 32B / Mixtral-tier). At 8B, expect noticeable failure rates.
- Recent comparisons ([best local models for agent loops 2026](https://hermes-agent.ai/blog/best-local-models-for-hermes-2026)) confirm Qwen 3.5+ family is the most reliable choice but still has rough edges; Gemma 4 12B is "good enough for most use cases" but not for sustained agentic work.
- Documented failure modes: model forgets to call memory tools, hallucinates memory contents, infinite tool-call loops, prompt-budget bleed from tool defs + memory blocks consuming context that would otherwise be conversation.

Letta's deployment footprint (Postgres + Docker + agent server process) is heavy for a single-user Mac app. Re-implementing the protocol against kobold directly is possible — koboldcpp's [function calling support](https://github.com/LostRuins/koboldcpp/pull/981) gives us the primitives — but we'd be doing it without the safety net of letta's tested loop logic.

### Recommendation

Don't adopt the full pattern. The combination of (a) patchy 8–12B tool-call reliability, (b) heavy infra for a single-user app, (c) prompt-budget cost, makes this the highest-cost-highest-risk option of the three structured-memory approaches.

The *idea* of a single tool call to remember a fact is folded into §9.3's extraction mechanism — that's MemGPT-lite at 1% of the protocol surface, and it tells us cheaply whether our default models are reliable enough to justify more.

Revisit when 32B+ is our default model class, *or* when koboldcpp ships hardened agent-loop helpers. Smallest revisit experiment: wire a single `remember_fact(text)` tool, count failure rate over 100 turns, decide.

### Open questions

- Tool-call reliability of Gemma 4 12B/27B and Qwen 3 14B/32B specifically on agentic memory loops — needs an eval harness. The community comparisons we have are for one-shot tool calls, not sustained loops.

---

## §9.5 — Author's-note depth experiments

**Verdict: Adopt** (small UI change with disproportionate quality impact).

### Findings

Community guidance from [SillyTavern AN docs](https://docs.sillytavern.app/usage/core-concepts/authorsnote/) and r/SillyTavernAI threads, distilled:

| Cue type | Sweet-spot depth | Rationale |
|---|---|---|
| Immediate scene state ("it's raining") | 1–2 | Fresh enough to drive next reply |
| Style / prose rules | 4 | Ambient, persistent, doesn't dominate |
| Long-term reminders | 8 | Findable, non-intrusive |
| Pinned critical fact | 2 | Override default character drift |
| Immediate steering ("respond in 1 paragraph") | 0 | Strongest, but risks model treating as user instruction |

Different cue types want different depths. SillyTavern handles this via Lorebook entries with per-entry depth settings.

### Recommendation

- **Multiple AN entries with per-entry depth** rather than a single-AN-with-single-depth. Each entry = `{ text, depth, enabled }`.
- **Defaults baked into UI:** when adding a new AN entry, pick a sensible default depth based on a "purpose" picker (Scene state / Style / Reminder / Override) that maps to depths 2/4/8/2.
- **Cache cost warning** in the AN editor: "Higher depth = stronger influence but reduces prompt cache effectiveness. See §9.10."

### Open questions

- For Gemma's first-user-turn fold, "depth" is fictional — everything's in one turn. Approximate by ordering within the fold, or skip AN-depth entirely for Gemma? Likely: order within fold (mirroring the depth semantics positionally) and document the limitation.
- Verify with kobold's `--debugmode` whether the AN actually lands at the requested position for both Gemma and Qwen prompt templates.

---

## §9.6 — Memory re-injection at every user turn

**Verdict: Adopt** as a tail-injection toggle.

### Findings

The "lost in the middle" effect ([Liu et al. 2023](https://arxiv.org/abs/2307.03172)) is real and well-documented: critical facts in the early-middle of long contexts get attended to less reliably. For Gemma's no-system-role fold, this is the worst case — pinned memory sits at the start of the first user turn and gets buried as the chat grows past ~3–4k tokens.

The naive countermeasure (re-inject the full memory block at the *top* of every prompt) is catastrophic for prompt caching — see §9.10. Re-injecting in the *latest user turn* (the tail) costs only the latest-turn KV recompute, which is negligible.

Token cost on Apple Silicon: prompt processing on M-series via Metal is roughly 5–15× faster than token generation for Gemma 3/4 and Qwen 3 at 8k context (community llama.cpp benchmarks). Re-injecting 200–400 tokens at the tail every turn adds ~0.3–1s of prefill, vs. the catastrophic 15–60s cost of invalidating the prefix cache.

### Recommendation

- Per-chat toggle: **"Reinforce memory in latest turn"**. When on, prepend a *compact memory digest* (200–400 tokens, not the full pinned block) to the user's current message before sending.
- Default: **off for Qwen** (system-role models don't need it), **on for Gemma** when the chat exceeds 20 turns OR the first-turn fold position falls below 25% depth in context.
- The digest extracts: top-N salience facts (when §9.7 ships) plus any fact whose entity was mentioned in the last 3 turns. Until §9.7 ships, just truncate the pinned-fact block to the most recent 300 tokens.
- Crucially: the digest goes in the **latest user turn**, not at the top. This preserves cache for everything before it.

### Open questions

- A/B effectiveness of 200-token digest vs. full re-injection — only knowable from real-chat telemetry. Default 200; expose a slider.

---

## §9.7 — Salience / decay scoring

**Verdict: Defer** (build infrastructure, skip auto-eviction).

### Findings

mem0's pattern is *semantic supersedes* (UPDATE op rewrites old facts when contradicted), not arithmetic decay. Letta uses LLM-driven eviction. SillyTavern doesn't do decay scoring — Vector Storage handles "what's relevant now" via embeddings.

ACT-R-style activation decay is academically clean (`A = ln(Σ tᵢ⁻ᵈ)`), but RP communities don't use it. The practitioner pattern is "recency-weighted summary" — newer events get more verbose summary entries, older ones get squeezed. That's decay-by-summarization, which §9.2 already addresses.

The "character left for 30 turns and returns" problem is exactly where pure time-decay fails. Better signal: **entity-mention recency** — keep facts whose entity was mentioned recently warm.

### Recommendation

- V2: add `lastReinforced: Date` and `mentionCount: Int` to every fact. Reinforce on entity-name match in user OR assistant turn. Pinned-by-user facts have salience locked at max.
- Don't auto-evict in V2. Use the score as a *tiebreaker* when token budget forces eviction, and as a **sort order** in the inspector's Memory pane (so users see fresh-vs-stale at a glance).
- Full decay scoring with auto-eviction is V2.5 territory. The hard problem isn't the decay function — it's the extraction pipeline that creates fact candidates in the first place. Solve §9.3 first.

### Open questions

- Visible vs. internal salience: showing it invites tweaking; hiding it surprises users when facts evict. Lean visible-but-internal-default: Inspector shows it on hover.

---

## §9.8 — Style / "author voice" block

**Verdict: Adopt** (manual-first, auto-extraction later).

### Findings

This is genuinely underexplored in mainstream RP tooling. SillyTavern character cards ([V2 spec](https://github.com/malfoyslastname/character-card-spec-v2), [V3 spec](https://github.com/kwaroran/character-card-spec-v3)) have static `personality`, `scenario`, `mes_example` — no evolving style block. The community workaround is hand-authored Author's Note prose ("Write in present tense, second person, gothic register").

Few-shot example messages (`mes_example`) are the de facto style anchor. r/LocalLLaMA consensus: models pattern-match prose style from 2–3 representative AI turns more reliably than from descriptive rules. **"Show, don't tell" beats "be poetic."**

Effective style-block format synthesized from community practice:

```
[STYLE]
Tone: gothic, melancholic, restrained
Pacing: slow-burn; avoid resolving tension within a single reply
POV: third-limited on {{char}}
Idioms: British English; occasional Latinate diction
Avoid: modern slang, action-movie beats, summarizing emotions
Sample: "The candle guttered. He did not look up."
[/STYLE]
```

Mixing rules + a one-line sample outperforms either alone. Sample tokens do most of the work.

### Recommendation

- **V2 ships the style block as a separate prompt-assembly slot.** New inspector tab "Style". Manual editing only in V2.
- **Injection point:** for Qwen, system block after FACTS, before chat history. For Gemma, in the first-user-turn fold after pinned facts, before rolling summary. Style benefits from front-loading (tone-locking happens early in generation).
- **Auto-extraction** (V2.1, behind a button): side-call asking for a style snapshot from the last 10 assistant turns. Show a diff and require user approval before applying — users have strong opinions about prose voice and will revolt if it shifts under them.

### Open questions

- Multi-character chats where each `{{char}}` has distinct voice. Per-character style blocks add complexity fast; defer until V2 character cards land.

---

## §9.9 — Cross-chat memory

**Verdict: Adopt schema in V2** (pairs naturally with V2 character cards).

### Findings

SillyTavern V2/V3 character cards treat the character definition as static. The community pattern for cross-chat persistence is manual lorebook editing — user promotes important events from a chat into the character's lorebook for future chats. mem0 supports per-user/per-agent persistent memory across sessions, which is closer to the goal.

### Recommendation

File layout:
```
~/Library/Application Support/RPClient/
  characters/
    alice/
      card.json          # static: name, description, personality, mes_example
      persistent.json    # evolving: established_facts[], relationships[], style_overrides
      chats/
        2026-04-30.json  # per-chat: events, summary, ephemeral facts
```

`persistent.json` gets edited via:
1. **Manual** "promote to character memory" action on a chat fact (V2).
2. **Auto-suggest promotion** when a fact is reinforced across N chats with the same character (V2.1).

Conform to V2/V3 character-card spec for `card.json` so users can import/export with SillyTavern.

### Open questions

- Detecting "fact has appeared in 3+ chats" for auto-suggestion requires cross-chat indexing — adds storage complexity. Punt to V2.1.

---

## §9.10 — Prompt-cache awareness

**Verdict: Adopt** (operational rules — the highest-leverage thing in this doc).

### Findings

- **Context Shifting** (default-on) handles "prompt overflows ctx" by sliding the window and preserving KV for what survives. Doesn't help when prefix changes.
- **`--smartcache`** is opt-in: KV state snapshots keyed by prompt prefix hashes. Useful for swapping between contexts (multiple chats, persona swaps, RNN/hybrid models). Costs RAM (each snapshot ≈ full ctx KV size).
- **Invalidation rule (with or without smartcache):** the cache is valid up to the **first differing token** between new prompt and cached prompt. Any change to memory, summary, or early turns invalidates everything from that point onward. There's no patch-the-middle-and-keep-the-tail.
- **Latency stakes:** prefill on Apple Silicon at Q4_K_M for a 7–14B model is roughly 100–400 tok/s. A 6–10k-token prompt:
  - **Cache hit:** only ~200 tail tokens prefill → ~0.5–2s before first generated token.
  - **Cache miss:** full 6–10k prefill → 15–60s.
  - **The practical win is 10–30× time-to-first-token** for stable prefixes. This is the single most-impactful operational lever in our memory design.

### Recommendation

**Bake a cache-friendly prompt layout into PromptBuilder as a design contract.** Top to bottom:

1. System prompt (immutable per session)
2. **Style block** (§9.8 — changes rarely)
3. **Pinned-fact memory** (changes occasionally; accept the cache miss when it does)
4. **Rolling summary** (changes occasionally; same)
5. **Scene summaries** (§9.2 — append-only, so changes are at the boundary)
6. **Stable older turns**
7. **— CACHE BOUNDARY —**
8. **Vector retrieval block** (§9.1 — recomputed each turn)
9. **Recent N turns** (verbatim)
10. **Author's-note entries at depth ≥ 1** (§9.5)
11. **Tail memory reinforcement** (§9.6 — in latest user turn)
12. **New user turn**

Operational rules:

- **Vector retrieval results that change every turn** must live below the boundary. Never inject them above the verbatim recent turns.
- **Summary updates: only between turns, never mid-stream.** Already implied by our >70% trigger; make it explicit in code.
- **Author's-note depth tradeoff (§9.5):** higher depth = stronger influence but reduces cache effectiveness. Document in the AN editor UI.
- **Vector retrieval re-run frequency:** consider re-running every K turns (default K=1; configurable). At K=3 we keep cache warm 2/3 of the time at the cost of recency.
- **Telemetry:** log `prompt_eval_count` from each kobold response. If it's >> the number of new tokens we appended, we had a cache miss. Surface this in a debug HUD so we see when assembly broke caching.
- **Recommend `--smartcache`** in the launch-helper docs (especially if user has multiple chats they switch between).

### Open questions

- Exact behavior of `--smartcache` on prefix divergence at varying depths — multi-snapshot LRU vs strict "best-prefix wins"? Reading the source would settle it; for V2, design as if it's strict best-prefix.
- Real-world prefill numbers on the user's specific hardware/model combos — only knowable by benchmarking.

---

## V2 build order (proposed)

In rough priority order, weighted by impact-per-effort:

1. **Prompt-cache-aware layout** (§9.10). Refactor PromptBuilder to enforce the cache boundary contract. Add `prompt_eval_count` telemetry to status bar (debug HUD). **2–3 days.** This unlocks everything else.
2. **Per-AN-entry depth + multiple AN entries** (§9.5). UI + assembly change. **1–2 days.**
3. **Style block** (§9.8). New inspector tab + assembly slot. Manual-only first cut. **1 day.**
4. **Vector retrieval over chat history** (§9.1). Embedding via kobold's own endpoint, sqlite-vec storage, retrieval at prompt-build time, "Relevant memories" debug pane. **3–5 days** (the meatiest item).
5. **Tail memory reinforcement toggle** (§9.6). Per-chat toggle + digest builder. **0.5–1 day.**
6. **Manual scene-break button + scene-summary array** (§9.2 reduced). Button + assembly support. **1 day.**
7. **Cross-chat persistent.json schema** (§9.9). File layout + manual promote action. **1–2 days.** Pairs with V2 character cards.
8. **Entity fact store + grammar-constrained extraction** (§9.3 reduced). The biggest experiment — start with extraction quality eval before committing UI. **3–7 days plus eval time.**
9. **Salience fields** (§9.7). Add `lastReinforced` and `mentionCount` to facts; show in inspector; no auto-evict. **0.5 day.**

Total V2 envelope: roughly 2–3 weeks of focused work, plus the Topic 8 evaluation.

## Empirical work to do before locking the design

- **Tool-call extraction reliability** for our default models (Gemma 4 12B, Qwen 3 14B) on a 100-turn RP transcript. Measure: % of extractions that produce valid JSON, % of facts that match human-extracted ground truth. Outcome decides whether §9.3 is feasible at our default model size or needs to be 32B-only.
- **Prefill benchmark** with and without `--smartcache` on a representative 10k-token RP prompt. Logs `prompt_eval_count` and time-to-first-token. Outcome: hard numbers to back the cache-friendly-layout argument.
- **Cosine-threshold tuning** for bge-small vs. nomic-embed-text on a small RP retrieval test set. Outcome: per-model default thresholds in Settings.

---

## Appendix — what we rejected and why

- **Full mem0 sidecar:** Docker + Qdrant + Postgres/Neo4j + Ollama is too heavy for a single-user Mac app. Native Swift implementation of the *pattern* (§9.3) gets us most of the value.
- **Full letta/MemGPT:** Postgres + Docker + agent server. Local 8–12B tool-call reliability isn't there. Wait for 32B-default.
- **HNSW/IVF vector index:** unnecessary at our scale. Brute-force cosine via Accelerate or sqlite-vec serves <50k vectors comfortably.
- **Auto scene-boundary detection:** premature. Manual button first; revisit if users actually use it.
- **ACT-R-style decay function:** academically clean, no community traction. Recency-weighted summary already gives us most of the benefit via §9.2.
