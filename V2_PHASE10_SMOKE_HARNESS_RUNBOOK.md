# Phase 10 — Smoke harness runbook

**Audience: future sessions of Claude Code, and the user when running solo.**

This is the operational guide for the model-interaction smoke harness suite (Phase 10 §10.0). It tells you (a) how to run the full suite against any model, (b) how to action the results, and (c) how the per-EXACT-model isolation invariant is preserved so fixes for one model never erase fixes for another.

Sister docs:
- [V2_PHASE10_SMOKE_HARNESS_PLAN.md](V2_PHASE10_SMOKE_HARNESS_PLAN.md) — the phase plan (sub-step staging, scope).
- [V2_PHASE10_CHAT_TUNING_RESEARCH.md](V2_PHASE10_CHAT_TUNING_RESEARCH.md) — empirical findings + per-model log + fix-registry roadmap.
- [V2_PHASE10_CHAT_TUNING_SCOPING.md](V2_PHASE10_CHAT_TUNING_SCOPING.md) — phase-level scoping; `ServerCapabilities` sketch.

---

## TL;DR

**To run the suite against the currently-loaded model, ask the user's Claude session:**

> "Run the Phase 10 smokes against the current model and action the results."

I'll then: probe the server, run every available smoke, append observations to the per-model JSON log, summarise quirks, and (per the actioning protocol below) either fix immediately or queue the fix for §10.a.

**To swap models and re-run:**

1. User loads a different model in KoboldCPP (the server URL doesn't change; just the loaded weights).
2. User says: "I've swapped models — re-run the smokes."
3. I detect the new exact model name from `/api/v1/model`, create a fresh observation file under that exact name, and run the suite. **Old models' observation files are NOT touched** — they live alongside the new one indefinitely.

**To inspect what's known about a model:**

```bash
ls "$HOME/Library/Application Support/RPClient/smoke-observations/"
cat "$HOME/Library/Application Support/RPClient/smoke-observations/<sanitised-model-name>.json" | jq
```

The sanitised name is the model name with `/` and other unsafe chars replaced with `_`, capped at 200 chars. Example: `koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M` → `koboldcpp_Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M.json`.

---

## The per-EXACT-model invariant (read this first)

Every storage layer in this subsystem is keyed by the EXACT `/api/v1/model` string — not the family, not a prefix, not a substring match. This is non-negotiable. The user explicitly called it out:

> *"Even over different variants of say the qwen 3.6 model, as I will be trying a new version of that later. So the full model name needs to be accounted for, not just qwen 3.6."*

What this means in practice:

| Layer | Keying | Aggregation |
|---|---|---|
| `ModelObservationLog` (today, §10.0.b+) | exact name → one JSON file | none — render-time view if needed |
| `ServerCapabilities` (when §10.a lands) | exact name → one capability record | read-only `relatedVariants(of:)` view |
| Chat-path consumption (when §10.c lands) | looks up by exact name; falls back to defaults | n/a |

**Forbidden operations:**

- Deleting another model's observation file when adding fixes for a new one.
- Substring-matching on model name to "share" a fix across variants (e.g. `if name.contains("qwen")`). The aggregation view is computed from per-exact records — never write code that pre-aggregates.
- Keying any persisted state on `ModelFamily` or any derived classification. Family is a read-time projection; storage stays per-exact.
- Editing a per-model log file in place to "carry over" a fix to a new model. Each model gets its own clean baseline; user-curated overrides are encoded as per-exact `ChatPathOverrides` on `ServerCapabilities` (when §10.a lands), never inherited by name-similarity.

Cross-model fix portability happens through one path only: the user (or I, with the user's confirmation) explicitly copies a `ChatPathOverrides` value from model A's record to model B's record. Never automatic.

---

## Running the smokes

### Available smokes (as of §10.0.c)

All smokes live in `Sources/<Name>Smoke/`. Each is an executable target; each writes to the per-EXACT-model observation log.

| Smoke | What it drives | Default fixture set |
|---|---|---|
| `CardGenSmoke` | `CardSuggestionsController` (Phase 9 AI-assist; predates the §10 logging layer) | one Mira-style draft per mode |
| `ChatSmoke` | `KoboldClient.generateStream` via `PromptBuilder.build` | every SyntheticChats fixture (10 of them) |
| `SummariserSmoke` | `Summarizer.run` | `sfw-long` (51 turns; canonical compress target) |
| `DirectorSmoke` | `DirectorPicker.next` | every multi-cast SyntheticChats fixture (`group-chat`, `nsfw-group-scene`); `--repeats N` for stability checks |
| `ExtractorSmoke` | `FactExtractor.run` | `sfw-long` (15-user-turn window); validates GBNF JSON-mode response shape + non-emptiness |
| `BlurberSmoke` | `ContextBlurber.run` | `sfw-long` mid-chat 3-turn synthetic chunk; checks 1–2 short factual sentences (no thinking-trace leak, no refusal) |
| `EmbedSmoke` | `KoboldClient.embed` | `sfw-short` first 8 turns; smallest harness — confirms `/v1/embeddings` reachable + consistent dimensionality |
| `SmokeAll` | sub-process all of the above; snapshot per-model log to `smoke-reports/<sanitised>-<ts>.json` | full suite, in fixed order; `--diff <prior>` for regression detection across runs |

### Default invocation (Claude does this on "run the smokes")

```bash
# 1. Confirm server is reachable + capture model name.
curl -s --max-time 5 http://192.168.1.201:5001/api/v1/model

# 2. (Preferred — single-command path; §10.0.e.) Build once, run all six smokes,
#    write per-model snapshot to smoke-reports/<sanitised>-<ts>.json.
swift build && swift run SmokeAll

# 2-alt. (Per-smoke breakout — useful when iterating on a single surface.)
swift run ChatSmoke
swift run SummariserSmoke
swift run DirectorSmoke --repeats 3
swift run ExtractorSmoke
swift run BlurberSmoke
swift run EmbedSmoke

# 3. Optional: diff against a prior snapshot to highlight regressions /
#    fixes / detail drift. Identical model name (variant unchanged) is
#    typical; cross-model diff is informative but per-model fix decisions
#    still stay isolated per the runbook's per-EXACT-model invariant.
swift run SmokeAll --diff "$HOME/Library/Application Support/RPClient/smoke-reports/<prior-snapshot>.json"
```

Full suite end-to-end is ~25s warm against Qwen3.6 on the user's hardware.

### Targeted invocations

```bash
# Specific fixture only
swift run ChatSmoke --fixture nsfw-group-scene

# Different server (e.g. Gemma served from a second box)
swift run ChatSmoke --server http://192.168.1.205:5001

# Different template (Gemma uses gemma, not qwen)
swift run ChatSmoke --template gemma

# Real chat from production app-support
swift run ChatSmoke --chat <chat-uuid>

# Verbose token-by-token streaming for cadence checks
swift run ChatSmoke --fixture sfw-short --verbose
```

### What the output tells you

After each fixture, the smoke prints either:

- `refusal:   none detected` — model returned reasonable output, no rule fired.
- `quirks:    N observation(s) recorded` — followed by `[kind] details` lines and a `→ remediation hint` per observation.

At end-of-run:

```
==================== summary ====================
   QN  fixture-name              1234ms   456 chars
total: 10 fixtures, 12345ms, 0 refusal-flagged, N observations recorded
observations: written N to /Users/.../smoke-observations/<sanitised-name>.json
```

The `Q1` / `Q2` flags in the summary are observation counts per fixture (zero observations → blank flag).

---

## Actioning the results

When you finish a smoke run, walk every observation in the latest log and bin it into one of three categories. **Per-model isolation matters here too** — a fix that's appropriate for model A may be wrong for model B.

### Category 1 — Fixture or smoke-runner bug (fix immediately)

Symptoms:
- `shortReply` on a fixture whose last user/assistant turn doesn't actually invite a substantive response. (E.g. fixture closes with "see you tomorrow" — model correctly emits a brief acknowledgement, the QuirkDetector is the false positive.)
- `noTokens` traceable to a smoke wiring bug (wrong server URL, malformed prompt assembly).
- Per-fixture data error (cast linkage broken, character UUID typo'd).

Action: edit the fixture or the smoke code, re-run, confirm the observation no longer fires. **No per-model state changes** — this fix benefits every model, and the per-model log dedupes naturally on re-run.

### Category 2 — Real model quirk that needs ModelCapabilities (encode now)

Symptoms:
- `role-confusion-in-group` on a model's group-chat output (group-nudge isn't load-bearing on this model).
- `thinking-trace-leak` on a non-Qwen template (the empty pre-fill assumption breaks).
- `refusal` on a chat the model SHOULD have engaged with (refusal-posture is `aligned` not `permissive`).
- `unparseable-director-pick` on every repeat (model can't follow the one-name directive).
- `summary-too-long` on the summariser smoke.

Action — and this is the load-bearing part for the per-model invariant:

1. **Run the candidate fix through ChatSmoke's `--nudge-variant` (or future similar A/B knob)** to validate which mitigation is most reliable on this exact model. The current variants are `standard`, `strong`, `continuing`, `stop-augment`, `strong-stop`. Three repeats per fixture per variant is enough to call a winner.
2. **Encode the validated fix to ModelCapabilities** via `swift run ModelCapsAdmin set <exact-model-name> <key>=<value> [...] --note "..."`. The set command MERGES into any existing record — adding `group-nudge=continuing` does not erase a previously-set `thinking-prefill=needed`.
3. **Add a section in [V2_PHASE10_CHAT_TUNING_RESEARCH.md](V2_PHASE10_CHAT_TUNING_RESEARCH.md)** for this exact model name documenting the validation table + recommendation. If a section already exists, append rows; never modify or delete other models' sections.

The chat path consumption (§10.c — not yet wired) will read `ModelCapabilitiesStore.lookupOrDefault(modelName:)`'s `overrides` and apply per-call. **Adding a fix for model B never touches model A's record** — the file storage is per-exact-name, the lookup is per-exact-name, the only path that writes records (`ModelCapsAdmin set`) operates on exactly one record at a time.

Recognised override keys (see `ModelCapsAdmin --help` for the full list):
| key | values | applies to |
|---|---|---|
| `thinking-prefill` | `needed` / `harmless` / `unknown` | Whether QwenTemplate emits the empty `<think></think>` pre-fill |
| `sampler` | `balanced` / `creative` / `precise` | Recommended sampler preset id |
| `stop-augment` | comma-separated list (use `\n` for newline) | Extra stops appended to the template default |
| `group-nudge` | `standard` / `strong` / `continuing` / `stop-augment` / `strong-stop` | How the multi-cast nudge is rendered |
| `max-ctx-cap` | int | Hard cap on `effectiveCtx` (e.g. Llama 4 Scout 8192) |
| `refusal-posture` | `permissive` / `aligned` / `unknown` | How the chat path treats detected refusals |

### Category 3 — Correct model behavior (refine detector or accept)

Symptoms:
- Same `shortReply` repeating across multiple fixtures of similar shape — the threshold is wrong, not the model.
- `roleConfusionInGroup` firing because the cohabitant's name happens to appear in the response prose (prefix match false positive).
- `refusal` firing on a benign character self-deprecation ("I cannot believe I just said that").

Action: refine the detector in [`Sources/SmokeFixtures/QuirkDetectors.swift`](Sources/SmokeFixtures/QuirkDetectors.swift). Add a test in `Tests/RPClientCoreTests/QuirkDetectorsTests.swift` capturing the false-positive case and the expected non-firing behavior. Re-run.

If the false positive is rare and detector refinement would add complexity, leave it; the user can ignore single-fire entries in the log. **Don't add a per-model "suppress this detector" — that's the wrong abstraction.** If the detector is wrong, fix the detector for everyone.

---

## When the user swaps models

The exact sequence (you'll see this from the user as: "I've swapped models" or "model swapped to X" or just a raw model name like "loaded the Q5 quant now"):

1. **Probe** to confirm the new model name. The model name string in the next smoke run will key a NEW observation file:
   ```bash
   curl -s http://192.168.1.201:5001/api/v1/model
   ```
2. **Don't delete the old model's file.** It stays. The user may swap back to it, or want to compare its findings to the new model's.
3. **Run the full suite.** Each smoke probes the model independently and writes to the new model's per-exact log.
4. **Action the results** per the protocol above. Add a NEW section to the research doc for this exact model name; never edit or merge another model's section.
5. **If you spot a finding that mirrors another model's (e.g. group-nudge weakness on both Qwen3.6-Q4 and Qwen3.6-Q5):** record both independently in their respective sections. The cross-variant similarity is interesting commentary in the "Cross-model summary" section of the research doc, but the per-exact records stay separate. The user explicitly does NOT want a quant-bump to inherit the prior quant's overrides.

---

## When the user adds a manual override

(Anticipated workflow, lands with §10.a Settings UI — documenting now so the invariant carries through.)

In the Settings → Servers row, the user will be able to view + edit a model's `ChatPathOverrides` directly. Any edit:

- Writes to that exact model's `ServerCapabilities` record only.
- Bumps that model's `userOverrideTimestamp` so a subsequent re-probe doesn't clobber the edit.
- Surfaces a warning if the user attempts to import another model's overrides ("you're about to copy from <model A> to <model B> — these are different exact models, are you sure?").

---

## Common pitfalls + recovery

### "I deleted the smoke-observations directory by accident"

The observations layer is purely additive — no chat-path code reads from it today (§10.a will). Wipe is safe; just re-run the smokes against each loaded model in turn to reconstruct.

When §10.a lands, the layer that DOES need preservation is `~/Library/Application Support/RPClient/server_capabilities/<sanitised>.json`. That gets backup-on-write per `feedback_diagnostic_logging` conventions; until then, don't worry.

### "The model probe failed and the log didn't get written"

Logged as: `warning: model probe failed at startup — observation log NOT written (model-name keying requires a known name).`

Recovery: confirm the server is up (`curl http://<host>:5001/api/v1/model`), then re-run. The smoke can't write a per-model log without a model name to key on; falling back to a generic log file would violate the per-EXACT-model invariant.

### "I want to wipe one model's log to re-baseline"

```bash
rm "$HOME/Library/Application Support/RPClient/smoke-observations/<sanitised-name>.json"
swift run ChatSmoke    # …and the others
```

The other models' files are untouched. The new run creates a fresh log for this exact model with `runCount: 1`.

### "The model name has changed but it's logically the same model" (server upgrade, library rename)

This is the genuinely tricky case. KoboldCPP can change the model name string when it bumps versions, even though the weights are identical. Handling:

1. Don't rename the old log. Let the new one accumulate fresh.
2. In the research doc, add a `(see also <old-name>.json)` note under the new section.
3. If the user wants to migrate user overrides from the old name to the new one, they must explicitly do so (anticipated as a §10.a Settings UI action).

---

## What's NOT in scope here

- **Auto-applying fixes.** The observation log is text + remediation hints only. Fix application waits for §10.a (`ServerCapabilities` data model + per-server cache) and §10.c (chat-path consumption points).
- **Family-level inference.** "All Qwen3 variants do X" is something the user can record in the research doc as commentary, but is NOT something the storage layer encodes. Family inference is a read-time projection.
- **Continuous-integration runs.** These smokes drive a real KoboldCPP server; they're developer-tools, not unit tests. The unit-test target (`RPClientCoreTests`) covers the harness's own logic.

---

## Quick reference

| Path | Purpose |
|---|---|
| `Sources/SmokeFixtures/SyntheticChats.swift` | 10 fixture chats (cold-start + sfw + nsfw + group + edge cases) |
| `Sources/SmokeFixtures/SyntheticCharacters.swift` | 7 character fixtures mirroring CardGenExemplars |
| `Sources/SmokeFixtures/RealChatLoader.swift` | `--chat <id>` loader from production app-support |
| `Sources/SmokeFixtures/ModelObservationLog.swift` | per-EXACT-model observation store |
| `Sources/SmokeFixtures/QuirkDetectors.swift` | rule-based weirdness detectors |
| `Sources/{Chat,Summariser,Director,Extractor,Blurber,Embed}Smoke/main.swift` | per-surface smoke runners |
| `Sources/SmokeAll/main.swift` | aggregate runner; sub-processes each smoke, snapshots per-model log, supports `--diff` |
| `~/Library/Application Support/RPClient/smoke-reports/<sanitised>-<ts>.json` | per-run snapshot (frozen view of post-run observation log; diff-able across runs) |
| `~/Library/Application Support/RPClient/smoke-observations/<sanitised>.json` | per-EXACT-model observation log |
| `V2_PHASE10_CHAT_TUNING_RESEARCH.md` | per-model findings + fix-registry roadmap |
| `~/Library/Application Support/RPClient/model_capabilities/<sanitised>.json` | per-EXACT-model `ModelCapabilities` record (§10.a — `ChatPathOverrides`) |
| `Sources/RPClientCore/ModelCapabilities.swift` | data model + per-EXACT-model store |
| `Sources/ModelCapsAdmin/main.swift` | admin CLI: `list` / `show MODEL` / `set MODEL k=v...` / `delete MODEL` |
