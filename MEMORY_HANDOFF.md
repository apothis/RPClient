# Memory subsystem — current state and active issues

Self-contained handoff for picking up this work in a fresh context.

Pair this with [`MEMORY_AUDIT.md`](MEMORY_AUDIT.md) (the static contract / contract-violation diagnosis) and [`MEMORY_RESEARCH.md`](MEMORY_RESEARCH.md) (the §9.x research that drove design). This doc adds: what's shipped this round, what bit us, what's still open.

---

## Orientation

RPClient is a local macOS roleplay client targeting a koboldcpp server (default `http://192.168.1.201:5001`). The memory subsystem feeds the prompt at every send.

- Source: `Sources/RPClientCore/`
- Memory code: `Sources/RPClientCore/Memory/`, `Sources/RPClientCore/PromptBuilder.swift`, plus `Sources/RPClientCore/Models/{Chat,Chunk,Entity,SceneSummary,Fact}.swift`
- Tests: `Tests/RPClientCoreTests/` — homegrown TestKit (Xcode is **not** installed, only the CLT). Run with `swift run RPClientCoreTests`.
- Build: `./build.sh` produces `RPClient.app` with ad-hoc codesign.
- Launch: `./run.sh` — runs the binary directly so it inherits the user's Local Network TCC permission. Do **not** `open RPClient.app`; re-signing breaks TCC.
- Chats on disk: `~/Library/Application Support/RPClient/chats/<uuid>.json`. Atomic writes; safe to inspect with `jq`/`python3`.
- Settings: `~/Library/Application Support/RPClient/settings.json`.
- Debug log: `$TMPDIR/rpclient-debug.log` (tail with `tail -f`).
- Current schema: **Chat v3** (post-2026-05-03 migration).

---

## The memory contract (one paragraph)

Six layers feed the prompt. The contract is: **pinned memory and entity store carry timeless facts; verbatim turns are authoritative for "now"; rolling summary is authoritative for the immediate prior period; scene summaries are authoritative for completed prior arcs only — they must be framed as such and decoupled from "where are we now"; retrieval and tail digest are reinforcement aids, not sources of truth.**

Each layer's job is to surface what isn't already visible. Verbatim covers the active window; rolling/scene summaries cover the compressed past in compressed form; retrieval cherry-picks specific details from that compressed past when they're relevant. Layers stop fighting each other when their domains are non-overlapping.

---

## Current prompt layout (Gemma)

```
<start_of_turn>user
[FIRST USER TURN ONLY:]
  pinned memory
  scene summaries (past-tense framing, compressed if stale)
  rolling summary
  ↓ ↓ ↓ user-message text ↓ ↓ ↓
<end_of_turn>
<start_of_turn>model
… assistant reply …
<end_of_turn>
…
<start_of_turn>user
[LAST USER TURN — extras BEFORE user text]
  entities block (selective, on-stage only)
  retrieval block (Recall — bullet list of blurbs)
  ↓ ↓ ↓ user-message text ↓ ↓ ↓
  tail digest (pinned-mem reinforce)
  author's note at depth
  current-scene anchor
<end_of_turn>
<start_of_turn>model
```

Cache boundary nominally between preamble and the per-turn-volatile blocks. The retrieval block was moved *before* the user's actual message in the last user turn — that's load-bearing for the "model starts before my message" symptom.

---

## What shipped this round (chronological, 2026-05-03 → 2026-05-04)

All landed under schemaVersion=3.

### 1. Phase 2 of the tuning pass (per [MEMORY_AUDIT §4](MEMORY_AUDIT.md))

- **A. Typed scene summaries.** `Chat.sceneSummaries: [String]` → `[SceneSummary]` with optional `firstTurn`/`lastTurn` markers. Codable migration handles legacy `[String]` shape; legacy entries get nil markers (intentionally distinguishable from a real `0`). [Models/SceneSummary.swift](Sources/RPClientCore/Models/SceneSummary.swift), [Models/Chat.swift](Sources/RPClientCore/Models/Chat.swift), [AppState.markSceneBreak](Sources/RPClientCore/AppState.swift).
- **B. Past-tense framing in templates.** Header changed from `[Scene N]` to `[Earlier in the story — completed arc N, turns X–Y]` (range omitted when markers nil). Centralised in `PromptBuilder.SceneSummaryFormatter`.
- **C. Current-scene anchor.** New tail-of-last-user-turn block instructing the model to treat the recent verbatim as authoritative. `PromptBuilder.currentSceneAnchor`. Suppressed in continuation mode and when no scene summaries exist.
- **F. Entity-store dedup.** One-shot per-chat collapse of legacy `name="[type] X" / type=event` rows into their typed twins. `Chat.dedupeMigratedEntities`. Runs on decode for `schemaVersion < 3`; bumps to v3.

### 2. Phase 2 follow-ups (when A/B/C alone failed live verification)

- **D. Scene-summary staleness compression.** Scenes whose `lastTurn` is more than 8 verbatim turns behind the head — or whose markers are nil — get their `text` compressed at render time to a clause-level headline (cut at first comma/sentence terminator within an 80-char cap), suffixed with `[…earlier scene compressed; refer back only for continuity.]`. **This was the load-bearing fix for the original 2026-05-03 regression** — A+B+C alone weren't enough because the 552-char vivid concert prose still out-pulled recent verbatim by sheer prose density.
- **E (clothing only). Render-time topic supersession on entity facts.** Per-fact bucket detection (currently `clothing`); within a bucket, only the most recent fact reaches the prompt. Pinned facts and topicless facts (timeless attributes) always survive. Storage untouched. `PromptBuilder.factTopic` + `supersedeStaleFactsByTopic`. Triggered by user reporting Sarah described as "topless and naked simultaneously".

### 3. Operational visibility

- **Extractor cadence visibility on the Extraction pane.** Reads `chat.lastExtractedTurn` (already persisted), shows `auto-extract: last user turn X · now Y · every Z · next in N user turns`. Added "Run now" button that calls `maybeAutoExtract(force: true)`. The cadence was already persisting; the user just couldn't see it.
- **Cadence default lowered 8 → 4** for fresh installs. Existing users keep their persisted value (Kevin had 6 → 4 by hand later).
- **Server reachability + alert.** New `AppState.serverReachable` flag, `serverReachableChanged` notification (transition-only). 30s health check timer, fast path on stream NSURLError. StatusBar shows red `⚠ server offline` with tooltip + sheet alert on transition. `AppState.isTransportError` distinguishes transport errors from HTTP-level errors.

### 4. Retrieval reformation (this is where today's drift bug was traced)

Original failure: model's reply began with content from a couple of turns ago, then "caught up" to the user's actual message.

- **Verbatim-window cutoff in retrieval.** New `RetrievalEngine.excludePredicate(turnsCount:summarizedThrough:recencyExclusion:)`. Two-rail exclusion: existing `recencyCutoff` (chunks within `recencyExclusion` turns of the head) + new `verbatimCutoff` (chunks whose `lastTurnIdx >= summarizedThrough`). Without the second rail, retrieval pulled 4-turn windows from the active scene that was already verbatim in the prompt.
- **Strip role prefixes from retrieved chunks.** The chunker emits `User: …\n\nAssistant: …`; the chunk text reaching the prompt no longer carries those line-start prefixes.
- **Reorder retrieval BEFORE user-text in the last user turn body.** New order: `entities + retrieval + USER MSG + digest + AN + anchor`. The user's actual message is the freshest "what to respond to" signal before the trailing instruction blocks.
- **Anthropic Contextual Retrieval recipe.** New `Chunk.contextBlurb: String?` field (Codable-optional, backward-compat). New `ContextBlurber` side-call generates a 1–2 sentence "place this snippet in the story" blurb per chunk, fed `pinned memory + scene summaries + rolling summary` as background. `RetrievalEngine.index` runs blurbs sequentially before embedding when `RetrievalSettings.contextual=true` (default true). Embeds `blurb + chunk.text` together so the contextual signal is in the vector.
- **Blurb-only retrieval injection.** With a blurb available, the prompt receives **only** the blurb; the dialog itself is no longer injected. This kills the "wall of past dialog right before the gen marker" symptom for good. Format: `• (turns X–Y) <blurb>`. Legacy chunks without a blurb fall back to a 400-char-capped dialog snippet. Header changed from `[Reference snippets …]` to `[Recall — facts from earlier in the story for continuity. These have already happened; do not continue from them, do not relocate the current scene to match them.]`

### 5. Direct chat-data surgery (one-off, not code change)

The canonical chat (`5D2AB609-…json`) was carrying a self-perpetuating artifact from turn 1: `<|channel>thought\n<channel|>` literal text the model occasionally copied into new replies. Stripped from turns 1 and 71 via Python script; turn 71 was a 33-char mid-stream cut-off and got dropped. Backup at `5D2AB609-…json.bak-pre-channel-strip`.

---

## Active issues / what to investigate next

### Issue: Model "jumps back in time a couple turns" then catches up

**Status:** seen in this session. **Last seen** after the contextual-retrieval ship. **Suspected fix landed** (blurb-only retrieval injection) but **not yet verified live** by the user — the conversation ended before re-test.

**How to check whether it's gone:**
1. Confirm the running build has the blurb-only retrieval rendering — `git log` should show the latest [PromptBuilder.swift](Sources/RPClientCore/PromptBuilder.swift) edit converting `formatRelevantMemories` to a bullet list.
2. Open the canonical chat in the running app, tail `$TMPDIR/rpclient-debug.log`.
3. Send (or regen) a turn. Look at the most recent `retrieval:` line in the log.
4. **Expected:** `blockChars` should now be ≈ 600–800 (down from 17,000+). If it's still big, retrieval is rendering legacy chunks (no blurbs) — most chunks already have blurbs (`contextblurb: ok` lines from prior indexing). New chunks added since then should also have them.
5. Read the model's reply. Does it start with content overlapping the user's most-recent message vs. inventing text from earlier? If the latter persists, the retrieval block size will tell us whether this is a retrieval issue at all.

**If still happening after blurb-only:** the next suspects are
1. The anchor's wording — `Continue the story from exactly where the most recent turns above leave off` may be too literal; a model might interpret "from where they leave off" as "begin by recapping where they left off".
2. The compressed scene summary — the canonical chat's scene[0] is compressed, but the *content* of the compression may still pull. If `lastTurn` markers got lost during the legacy-`[String]` decode (they will be nil), compression is permanent for that chat.
3. Stale rolling summary — `summary` says "now at the car" while verbatim is at the apartment. We've never touched the rolling-summary content for staleness; it still lands in the preamble verbatim.

### Issue: Extractor cadence felt "broken"

**Status:** resolved as visibility-only. The extractor *was* running on cadence; the user just couldn't see when it last ran. Now visible on the Extraction pane.

**How to check:** open Extraction pane on any chat. The header line shows `auto-extract: last user turn N · now M · every K · next in P user turns`. P should decrement as the user adds turns and reset after each run. Persists across app restarts (`chat.lastExtractedTurn` is a Codable field).

### Issue: Server crashes silently mid-session

**Status:** detection added. Server crashed once in this session; user noticed only because model name disappeared from status bar.

**How to check:** kill the koboldcpp server process during a session. Within ~30s an alert sheet should pop on the chat window: "Lost connection to the koboldcpp server" with the underlying NSURLError. Status bar shows red `⚠ server offline · Gemma`. Restart the server; within ~30s the marker clears, embed model is re-probed.

### Open follow-ups (not bitten yet)

From [MEMORY_AUDIT §4.4](MEMORY_AUDIT.md):
- Other transient-state buckets in entity-fact supersession: `location-of-character`, `mood`, `activity`. Currently only `clothing`. Each carries more false-positive risk than clothing (figurative usage of mood words, etc.). Defer until empirically needed.
- **Stale rolling-summary suppression**, listed in the audit as the next likely lever and re-listed here under the active drift-back issue.
- **Pronoun-aware selective entity injection** — the substring match on name+aliases misses entities only referred to by pronouns.
- **Paraphrased-suggestion dedup** — same fact extracted twice with different phrasing currently both queue.
- **Embedding-similarity dedup for suggestions.**

---

## How to verify each behaviour quickly

### Look at the prompt that was actually sent

There isn't a built-in "dump the prompt" facility. Closest is the `cache:` line in the debug log, which prints fragments around the prompt-overlap split and is useful for spotting unexpected content. Tail with:

```
tail -f "$TMPDIR/rpclient-debug.log"
```

Expected lines around a send (in order):
- `trigger: send (userTextChars=N)` or `trigger: regen`
- `stream-start: …`
- `retrieval: enabled=… hits=N scores=[…] blockChars=N injected=yes`
- `send: turns=N summarizedThrough=N truncated=N usage=NNN/NNN tok …`
- `cache: prev=… new=… match=… ratio=…`
- (after streaming) `perf: ttft=…s process=…s eval=…s tokens=N tps=…`

Key invariants:
- `blockChars` for retrieval should be **≤ ~1 KB** when most chunks have blurbs. >5 KB suggests too many legacy chunks or the blurb-only path isn't taking effect.
- `summarizedThrough` should never decrease across sends (it can stay the same or advance).
- `usage` `prompt + replyReserve` should fit under `ctx`. If you see truncation (`truncated=N` non-zero), the budget is squeezed.

### Inspect chat state on disk

```
python3 -c "
import json
with open('/Users/kevinappleyard/Library/Application Support/RPClient/chats/<uuid>.json') as f:
    c=json.load(f)
print('turns:', len(c['turns']))
print('summarizedThrough:', c['summarizedThrough'])
print('schemaVersion:', c.get('schemaVersion'))
print('scenes:', [(s.get('firstTurn'), s.get('lastTurn'), len(s.get('text', ''))) if isinstance(s, dict) else ('legacy', None, len(s)) for s in c.get('sceneSummaries', [])])
print('entities:', len(c.get('entities', [])))
print('lastExtractedTurn:', c.get('lastExtractedTurn'))
"
```

### Run the test suite

```
swift run RPClientCoreTests
```

~60 tests, all should pass. Notable test files:
- `MemoryAuditRegressionTests.swift` — the 2026-05-03 regression (concert vs. apartment).
- `PromptBuilderTests.swift` — anchor, scene compression, topic supersession, retrieval injection shape.
- `ChatCodableTests.swift` — Codable migrations including legacy `[String]` scene summaries and entity dedup.
- `VectorStoreTests.swift` — including `excludePredicate` (verbatim-cutoff invariant).
- `ChunkerTests.swift` — including `Chunk.embeddingText` (blurb prepending).

### Probe the koboldcpp server directly

```
curl -s --max-time 5 http://192.168.1.201:5001/api/v1/model
curl -s --max-time 5 http://192.168.1.201:5001/v1/models
```

If these don't respond, the in-app `⚠ server offline` should be showing.

---

## File map

Memory subsystem files touched this round:

| File | Role |
|---|---|
| [`PromptBuilder.swift`](Sources/RPClientCore/PromptBuilder.swift) | Prompt assembly entry point. Scene-block formatter, current-scene anchor, retrieval format, entity rendering, topic supersession. |
| [`Memory/RetrievalEngine.swift`](Sources/RPClientCore/Memory/RetrievalEngine.swift) | Per-chat vector index lifecycle, retrieval predicate, blurb-gen wiring. |
| [`Memory/ContextBlurber.swift`](Sources/RPClientCore/Memory/ContextBlurber.swift) | New side-call for chunk blurbs (Anthropic contextual retrieval). |
| [`Memory/Chunker.swift`](Sources/RPClientCore/Memory/Chunker.swift) | Unchanged — still 4-turn / 1-overlap windows. |
| [`Memory/Summarizer.swift`](Sources/RPClientCore/Memory/Summarizer.swift) | Unchanged. |
| [`Memory/FactExtractor.swift`](Sources/RPClientCore/Memory/FactExtractor.swift) | Now reads `scene.text` (typed `SceneSummary`). |
| [`Memory/TokenBudget.swift`](Sources/RPClientCore/Memory/TokenBudget.swift) | Routes through `renderableScenes` so token math reflects compressed reality; counts the anchor; handles userName-prepended memory. |
| [`Models/Chat.swift`](Sources/RPClientCore/Models/Chat.swift) | Schema v3, `sceneSummaries: [SceneSummary]`, `dedupeMigratedEntities`. |
| [`Models/SceneSummary.swift`](Sources/RPClientCore/Models/SceneSummary.swift) | New typed scene container. |
| [`Models/Chunk.swift`](Sources/RPClientCore/Models/Chunk.swift) | New `contextBlurb` + `embeddingText`. |
| [`Models/Entity.swift`](Sources/RPClientCore/Models/Entity.swift) | Unchanged. |
| [`Models/Fact.swift`](Sources/RPClientCore/Models/Fact.swift) | Unchanged; existing `lastReinforcedTurn` / `pinnedByUser` used by the new supersession. |
| [`Models/Settings.swift`](Sources/RPClientCore/Models/Settings.swift) | `userName`, `factExtractionEveryNTurns` default 4 (was 8). |
| [`AppState.swift`](Sources/RPClientCore/AppState.swift) | Server-reachable state + 30s health check, transport-error fast path, scene-break marker synthesis. |
| [`UI/Inspector/ExtractionPane.swift`](Sources/RPClientCore/UI/Inspector/ExtractionPane.swift) | Cadence readout + "Run now" button. |
| [`UI/Inspector/RetrievalPane.swift`](Sources/RPClientCore/UI/Inspector/RetrievalPane.swift) | `contextual=on/off` in status, blurb shown per-hit. |
| [`UI/StatusBar.swift`](Sources/RPClientCore/UI/StatusBar.swift) | Red offline marker + sheet alert. |
| [`GemmaTemplate.swift`](Sources/RPClientCore/GemmaTemplate.swift), [`QwenTemplate.swift`](Sources/RPClientCore/QwenTemplate.swift) | New `currentSceneAnchor` param, retrieval+entities reordered before user text. |

---

## Recommended opening prompt for a new context

> Open `MEMORY_HANDOFF.md` and `MEMORY_AUDIT.md`. The memory subsystem has been heavily reworked; the most recent change was switching retrieval to inject blurb-only bullets instead of full dialog (Anthropic contextual-retrieval recipe). The user previously reported a "model jumps back in time a couple turns then catches up" symptom; that was traced to the retrieval block being a wall of dialog right before the gen marker. The blurb-only fix landed but the user has not re-verified live yet. If they confirm it works, mark MEMORY_AUDIT §4 status accordingly. If it still drifts backward, the next suspects are the anchor wording and stale rolling-summary content — see "Active issues" in this file.

