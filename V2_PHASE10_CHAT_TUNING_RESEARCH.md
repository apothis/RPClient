# Phase 10 — Chat-tuning empirical findings

**Status: live document.** Grows with each smoke run against a new model. Authoritative source for the per-EXACT-model observation log is `~/Library/Application Support/RPClient/smoke-observations/<sanitised-model-name>.json` — this doc summarises that log + adds prose context the JSON can't carry.

Smokes producing data here: `ChatSmoke`, `SummariserSmoke`, `DirectorSmoke` (Phase 10 §10.0.b–c). The remaining smokes (`ExtractorSmoke`, `BlurberSmoke`, `EmbedSmoke`) land in §10.0.d.

The plan ([V2_PHASE10_SMOKE_HARNESS_PLAN.md](V2_PHASE10_SMOKE_HARNESS_PLAN.md)) calls for this doc to grow as §10.0.f's deliverable. Started early (after §10.0.b–c) because §10.0.b surfaced enough quirks worth pinning down before more smokes pile on.

---

## Observation-log conventions

**Keying is by EXACT model name string** — whatever `/api/v1/model` returns. Different fine-tunes / quants of the "same" model behave differently in practice (Q4 vs Q5 quantisation, base vs uncensored, etc.); family-level grouping is a render-time concern, not a storage concern.

Each smoke binary calls `ModelObservationStore.append(...)` with the observations it emitted via `QuirkDetectors`. Re-runs that hit the same `(smoke, fixture, kind)` triple bump `seenCount` rather than duplicating; the log carries `firstSeen` / `lastSeen` for triage.

**Fix-application status, by layer:**

| Layer | Status | What it does |
|---|---|---|
| Observation | LANDED (§10.0.b–c) | smokes emit `ModelObservation` to per-model JSON; remediation hint is text-only |
| ModelCapabilities | LANDED (§10.a) | per-EXACT-model `ChatPathOverrides` record at `model_capabilities/<sanitised>.json`; written via `swift run ModelCapsAdmin set` |
| Settings UI | LANDED (§10.b) | App menu → Model Capabilities… (⌘⇧,) — separate window, one section per model, per-section Save/Delete |
| Auto-apply | LANDED partial (§10.c) | `groupNudgeStyle`, `stopSequenceAugmentation`, `maxCtxCap` now read from `ModelCapabilitiesStore.lookupOrDefault` in `PromptBuilder.build` (test path) and `TokenBudget.assemble` (production via AppState `effectiveContext(for:)` + `resolveOverrides(for:)`). `thinkingPrefill` and `recommendedSamplerId` consumption are §10.c follow-ups (no encoded records use them yet) |

So at this point in the phase, observed quirks land in the observation log with a remediation hint, validated fixes land in the `ModelCapabilities` record, and the chat path AUTOMATICALLY applies the encoded overrides at every send. The `continuing` group-nudge override for the Qwen3.6 baseline is the first concrete record (encoded 2026-05-09); end-to-end ChatSmoke runs without `--nudge-variant` now print `[nudge-variant] from record: continuing` and the prompt rendering matches the §10.0.f validation pass (group-chat 2/3 clean, nsfw-group-scene 0/3 — fixture-design hard).

---

## Per-model log

### `koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M`

**First observed:** 2026-05-09. **Probe count so far:** ChatSmoke (×2 dev iterations), SummariserSmoke (×1), DirectorSmoke (×1), ExtractorSmoke (×1), BlurberSmoke (×1), EmbedSmoke (×1).

**Observations recorded (after fixture-shape cleanup):**

| Smoke | Fixture | Kind | Status | Note |
|---|---|---|---|---|
| ChatSmoke | `nsfw-group-scene` | role-confusion-in-group | UNFIXED — needs §10.a wiring | Model wrote as Rae despite group-nudge specifying Cass. The active speaker just spoke (last turn was Cass's), so the model treats "next reply" as "next *speaker's* reply" and picks Rae. |
| ChatSmoke | `group-chat` | role-confusion-in-group | UNFIXED — needs §10.a wiring | Same shape: nudge says Mira, model writes as Anya. |
| ChatSmoke | `group-chat` | short-reply | UNFIXED — needs §10.a wiring or fixture redesign | 97 chars / 400 expected (ratio 0.24). Doubled-prefill artifact. The fixture ends on Mira's last assistant turn → template emits a fresh assistant prefill → model writes a brief "next" reply. |
| SummariserSmoke | `sfw-long` | (none) | CLEAN | Summariser produced an 904-char factual recap; no thinking-trace leak; no refusal. |
| DirectorSmoke | `nsfw-group-scene` | (none) | CLEAN | All 3 repeats picked Rae deterministically (~120ms warm). |
| DirectorSmoke | `group-chat` | (none) | CLEAN | All 3 repeats picked Kit Voss deterministically. |
| ExtractorSmoke | `sfw-long` | (none) | CLEAN | 8 well-formed facts, valid JSON, GBNF grammar honoured. ~4.2s warm on 15-user-turn window. |
| BlurberSmoke | `sfw-long` | (none) | CLEAN | 184-char two-sentence factual blurb on a mid-chat 3-turn chunk. ~800ms warm. |
| EmbedSmoke | `sfw-short` | (none) | CLEAN | 5 inputs → 5 vectors at 768-dim, ~320ms. Embedding model is loaded on this server. |

**Findings worth carrying forward:**

1. **The empty `<think></think>` pre-fill is harmless on this model** — the chat path emits it on every assistant block (per `QwenTemplate`), and Qwen3.6-Uncensored consumes it cleanly. No `thinking-trace-leak` observations across the runs to date. Zero remediation needed; this matches the §5.4.0 finding and is the baseline expectation when ServerCapabilities lands `thinkingPrefill = .needed` for Qwen3 family.

2. **Group-nudge `[Write the next reply only as X.]` is NOT load-bearing on this model** when X has just spoken. The model interprets "next" as the next speaker in the rotation rather than as the addressee of the directive. Two independent reproductions (`nsfw-group-scene` → Cass→Rae, `group-chat` → Mira→Anya). Validation pass (3 runs × 4 variants × 2 fixtures via `swift run ChatSmoke --nudge-variant <…>`):

   | variant | `group-chat` clean rate | `nsfw-group-scene` clean rate | notes |
   |---|---|---|---|
   | `standard` (baseline) | 1/3 | 0/3 | reproduces the problem reliably |
   | `strong` (`[X speaks now. Others silent.]`) | mixed | mixed | the directive helps sometimes but isn't decisive |
   | `continuing` (`[Continuing as X.]` on X→X case) | **2/3** | 0/3 | best clean alternative on group-chat; doesn't crack the harder NSFW fixture |
   | `stop-augment` (append `\n<Other>:` to stops) | mixed | 1/3 of clean runs were 0-tokens | stops fire too aggressively when prose contains cohabitant names |
   | `strong-stop` (combined) | **3/3** | 1/3 (other 2 = 0 tokens) | bullet-proof on standard group chats but brittle on NSFW where the model leads with `Name:` |

   **Recommended per-EXACT-model `ChatPathOverrides.groupNudgeStyle` for `koboldcpp/Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M`: `continuing`** as the primary fix for the X→X case. `strong-stop` is tempting (3/3 on group-chat) but the augmented stop sequences fire on legitimate prose for the NSFW fixture — too risky for a default-on override.

   The `nsfw-group-scene` fixture remains hard for every variant. Looking at why: Cass's last assistant turn explicitly directs Alex and Rae (`"Alex, kiss her — slow, the way she likes."`), priming the model to write *as* one of them. This is a fixture design issue more than a model issue — production multi-cast chats won't usually script other speakers' actions in the active speaker's turn that aggressively. Flag for fixture revision in §10.0.f follow-up; not a blocker for §10.a wiring of the `continuing` override.

   The right per-model fix for THIS exact model name gets encoded in ServerCapabilities (§10.a) — `groupNudgeStyle = .continuing`.

3. **Doubled-prefill quirk on assistant-trailing fixtures.** Initially I tried setting `continuation: true` for these; **that empirically made things worse** — the model interpreted the open assistant turn as already complete and emitted end-of-turn immediately on closed-feeling prose. Two reverts and a fixture rewrite later: `sfw-short` and `sfw-long` now end on conversational user hooks; the remaining assistant-trailing fixtures (`nsfw-explicit`, `nsfw-kink`, `post-conflict`, etc.) are kept as-is because they intentionally probe the doubled-prefill semantics. The QuirkDetector flags `short-reply` on these but the remediation hint is now correct ("end on a user turn" rather than the misleading "set continuation:true").

4. **Director picks are deterministic at temperature 0.3** on this model. 3 repeats × 2 multi-cast fixtures returned the same pick every time, sub-150ms warm. No need to bump the picker's 5s timeout for this server.

**Findings worth carrying forward (continued — §10.0.d data):**

5. **GBNF grammar IS honoured on this server build.** ExtractorSmoke produced 8 well-formed facts with valid JSON, all entity_type values in the allowed alternation. No `schema-deviation`. The `--embeddingsmodel` is loaded too (768-dim vectors from `/v1/embeddings`). Confirms this server is fully equipped for the Phase 7 retrieval pipeline; ServerCapabilities for this model can encode `supportsJsonSchema = true` and `supportsEmbeddings = true` once §10.a lands.

6. **Blurber works at default temp/max-length** with no thinking-trace leak. ~800ms per chunk warm. No need to bind the blurber-role to a smaller model on this server.

**Pending probes against this model (next session):**
- A retry of the role-confusion fixtures with the proposed mitigations (stop-sequence augmentation; stronger nudge wording) — to validate the candidate fixes before encoding them in ServerCapabilities.
- A repeat ChatSmoke pass with `--verbose` so per-token cadence is captured (probe candidate P4 from `V2_PHASE10_CHAT_TUNING_SCOPING.md` §2.3).

**§10.0.e SmokeAll baseline:** full suite (6 sub-processed smokes) lands at ~25s warm against this server; snapshots write to `smoke-reports/<sanitised>-<ts>.json`. `--diff <prior-snapshot>` confirmed working — caught a real-model nondeterminism shift on the `ChatSmoke|group-chat|short-reply` quirk between consecutive runs (ratio drifted 0.18 → 0.20). The diff layer flags `NEW`, `GONE`, `CHANGED` per dedupe key — exactly the input shape §10.a's `ServerCapabilities` regression-detection consumer needs.

---

### `koboldcpp/Qwen3.6-27B-Uncensored-HauhauCS-Aggressive-Q4_K_P`

**First observed:** 2026-05-09. **Probe count so far:** SmokeAll (×1 = ChatSmoke + SummariserSmoke + DirectorSmoke + ExtractorSmoke + BlurberSmoke + EmbedSmoke), nudge-variant validation sweep (3 reps × 2 variants × 2 fixtures).

Different exact model name from the `35B-A3B-Q4_K_M` above (different param count, dropped A3B suffix, different quant — `Q4_K_P` vs `Q4_K_M`). Same family fine-tune lineage (`Qwen3.6-Uncensored-HauhauCS-Aggressive`). Per the per-EXACT-model invariant, this gets its own record + log; the Q4_K_M's `continuing` override does NOT inherit and was re-validated on this exact name before encoding.

**Observations recorded (post-validation sweep):**

| Smoke | Fixture | Kind | Status | Note |
|---|---|---|---|---|
| ChatSmoke | `group-chat` | role-confusion-in-group | UNFIXED at the smoke layer (encoded fix in ModelCapabilities — see below) | Mira→Kit Voss reproduction. Same X→X family weakness as Q4_K_M. |
| SummariserSmoke | `sfw-long` | (none) | CLEAN | 811-char factual recap, ~6.5s warm (slower than Q4_K_M's 2.2s — 27B-Q4_K_P appears slower per-token despite the smaller param count, possibly the K_P quant variant). |
| DirectorSmoke | both multi-cast fixtures | (none) | CLEAN | Deterministic picks across 3 reps each, ~210ms warm. Same as Q4_K_M. |
| ExtractorSmoke | `sfw-long` | (none) | CLEAN | 7 well-formed facts, valid JSON, ~10.8s warm. |
| BlurberSmoke | `sfw-long` | (none) | CLEAN | 206-char two-sentence factual blurb, ~1.4s warm. |
| EmbedSmoke | `sfw-short` | (none) | CLEAN | 5×768-dim vectors, ~325ms. Same dimensionality as Q4_K_M. |

**Nudge-variant validation pass** (3 reps each):

| variant | `group-chat` | `nsfw-group-scene` |
|---|---|---|
| `standard` (baseline) | 2/3 clean | 0/3 clean |
| `continuing` | 2/3 clean | 1/3 clean |

Weaker signal than the Q4_K_M validation — `continuing` is no-worse-than-standard on `group-chat` and marginally better on `nsfw-group-scene`. Encoded anyway because:
1. Directionally correct (no regression on either fixture)
2. The X→X family-level weakness rationale applies (last assistant turn was the active speaker; standard nudge interpreted as "next speaker in rotation" not "addressee of directive")
3. No conflict with the standard behaviour the chat path falls back to when no record exists

**Encoded ModelCapabilities** (per the per-EXACT-model invariant — applies ONLY to this exact name):
```
group-nudge:        continuing
thinking-prefill:   needed
```

End-to-end auto-apply confirmed: `swift run ChatSmoke --fixture group-chat` (no flag) prints `[nudge-variant] from record: continuing` and the prompt renders `[Continuing as Mira.]`.

**Cross-variant deltas vs Q4_K_M:**
- All side-call smokes ~1.5-2.5× slower despite the smaller param count. Worth a `serverprobe: P3 throughput` observation when §10.a's probe runner lands.
- Nudge-variant validation signal weaker (smaller margin between `standard` and `continuing` on group-chat) — possibly noise at 3 reps, possibly real. Worth re-validating with 5+ reps if the user reports model-specific multi-cast issues.

---

## Cross-model summary (planned — populated as more models are tested)

Format will be a table with one column per exact model name and one row per known quirk kind. Aggregation across "same family" variants (e.g. all `Qwen3.6` variants) is a render-time view computed from the per-exact logs — not a separate storage layer. The user explicitly called out the need to track variants separately ("a new version of that later"), so the aggregation layer must always be derivable from the underlying exact-keyed logs, never replace them.

**Family-level commentary (Qwen3.6-Uncensored-HauhauCS-Aggressive lineage)** — derived from the two exact records above, not a storage substitute:
- Both quants exhibit the X→X group-nudge weakness; both validate `continuing` as no-worse-than-standard.
- Both handle the empty `<think></think>` prefill cleanly (zero thinking-trace leak across all smoke runs).
- Both honour the GBNF grammar in ExtractorSmoke (valid JSON every run).
- Both have an embeddings model loaded (768-dim, same dimensionality).
- The 27B-Q4_K_P is meaningfully slower per-token than the 35B-A3B-Q4_K_M despite fewer parameters — quant variant matters.

When the user swaps to a new model:

1. Run `swift run ChatSmoke` and the other smokes against it.
2. The per-exact log file gets created automatically at `~/Library/Application Support/RPClient/smoke-observations/<sanitised-model-name>.json`.
3. Add a section above for the new model name, mirroring the Qwen3.6 section's structure.
4. Compare against prior model's observations; flag deltas as candidates for ServerCapabilities differentiation.

---

## Fix-registry roadmap (when §10.a lands)

The user's guidance: *"Fixes for each model should be applied, and used whenever that model is used. Even over different variants of say the qwen 3.6 model … the full model name needs to be accounted for, not just qwen 3.6."*

This carves the ServerCapabilities work into two layers:

### Layer 1 — `ServerCapabilities` keyed by exact model name (§10.a)

```swift
// Per V2_PHASE10_CHAT_TUNING_SCOPING.md §3, sketched. Adds:
struct ServerCapabilities: Codable {
    let exactModelName: String   // /api/v1/model verbatim — primary key
    // …existing fields per §3 sketch…

    /// Per-exact-model overrides for chat-path consumption points.
    /// Resolved from observation log + manual user edits in §10.b
    /// Settings UI. Nil = use the global default.
    var overrides: ChatPathOverrides
}

struct ChatPathOverrides: Codable {
    var thinkingPrefill: ThinkingPrefill?
    var samplerPreset: SamplerPreset?
    var stopSequenceAugmentation: [String]?
    var groupNudgeStyle: GroupNudgeStyle?  // .standard, .strong, .skipWhenSelfFollowsSelf
    var maxCtxCap: Int?
    var refusalPostureOverride: RefusalPosture?
    // ...
}
```

### Layer 2 — chat-path consumption (§10.c)

Each touch-point reads via `ServerCapabilities.shared.lookup(modelName:)?.overrides` with a `nil`-coalesce to the existing global default. The chat path stays operational on unknown / unprobed models (just uses the defaults that work today).

### Aggregation view (post-§10.a, no separate storage)

When the user inspects "what do we know about this model family?", a view computes:

```swift
extension ServerCapabilitiesStore {
    /// Returns capabilities for every exact model name whose name
    /// shares a prefix / family marker with `referenceModelName`.
    /// Read-only — never folds variants into a single record.
    func relatedVariants(of: String) -> [ServerCapabilities]
}
```

This is the "all my Qwen3.6 quants" view, derived from the exact-keyed underlying records. Variant-level differences stay distinguishable.

---

## References

- [V2_PHASE10_SMOKE_HARNESS_PLAN.md](V2_PHASE10_SMOKE_HARNESS_PLAN.md) — the parent plan; §10.0.f is the doc-this-research target.
- [V2_PHASE10_CHAT_TUNING_SCOPING.md](V2_PHASE10_CHAT_TUNING_SCOPING.md) — phase-level scoping; §3 sketches `ServerCapabilities`.
- [V2_PHASE9_AI_ASSIST_RESEARCH.md](V2_PHASE9_AI_ASSIST_RESEARCH.md) §8.3 — the refusal-posture probe taxonomy that informed `CardGenRefusalDetector` and indirectly `QuirkDetectors.detectChat`.
- `Sources/SmokeFixtures/ModelObservationLog.swift` — schema + storage layer.
- `Sources/SmokeFixtures/QuirkDetectors.swift` — rule set that converts smoke output to observations.
