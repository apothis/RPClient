# Phase 10 — Chat tuning (scoping note)

**Status: scoping note only.** Defines the shape of Phase 10 work; no live probes, no implementation. **When Phase 10 picks up, it produces its own research + plan docs** (`V2_PHASE10_CHAT_TUNING_RESEARCH.md` + `V2_PHASE10_CHAT_TUNING_PLAN.md`) following the project convention used by Phase 7 / 8 / 9. This doc is a handoff: it captures the scoping conversation that produced the phase, the probe taxonomy candidates surfaced during the §5.4.0 digression, and the data-model + subsystem sketches so Phase 10's actual research pass starts from a known baseline rather than cold.

The §1 sub-step staging below is *expected shape, not commitment* — Phase 10's own research doc will refine it.

Origin: spun off the §5.4.0 research pass after live probing of the user's configured Qwen3.6 server incidentally surfaced things about the chat path the existing code probably isn't exploiting (KV-cache-prefix stability, sampler defaults, thinking-trap behavior under realistic chat assembly). The user's framing: *"have the whole probe process automated and built into the app which can reconfigure itself dependant on which model is loaded."*

**Phase 9 §5.4 takes priority.** This phase is queued after §5.4 ships.

---

## Why

The chat path today encodes several decisions as if all servers behave identically:

- The empty `<think></think>` pre-fill ([`DirectorPicker.swift`](Sources/RPClientCore/DirectorPicker.swift), and similar in the chat assembly) is hardcoded for *any* server, but Gemma / Llama / Mistral don't use Qwen-style thinking blocks — the pre-fill is harmless on those but indicates the abstraction isn't actually probing the model.
- Sampler defaults (`SamplerPreset.balanced` etc.) are inherited values; [Gemma's authors recommend specific defaults](https://gemma-llm.readthedocs.io/en/latest/colab_sampling.html) (temp=1.0, top_k=64, top_p=0.95, min_p=0, rep_penalty=1.0) which are different from common Qwen tuning. A user swapping models silently degrades quality.
- Stop sequences come from the chat template, not the model — but a fine-tune may emit a different end-of-turn token than its base.
- [`Llama 4 Scout's chunked attention`](https://github.com/huggingface/transformers/issues/37351) is 8192 tokens even though the marketed context is 10M — chunks beyond 8k may behave differently than the model card implies. The chat path's max-ctx logic doesn't know.
- The Phase 7 memory subsystem retrieves chunks but [Google DeepMind's "context neglect" finding](https://www.getmaxim.ai/articles/rag-evaluation-a-complete-guide-for-2025/) is real: retrieved context isn't always used. RPClient has no measurement of whether retrieved chunks actually land in the response.

Each of those is a place where *probing the model* and *caching the answer* would let the chat path tune itself rather than rely on hardcoded defaults that drift as the user swaps models.

The deliverable is two things: empirical baselines (per model family) and a `ServerProbe` subsystem that runs the probes automatically and exposes the results to the rest of the app.

---

## 1. Sub-step staging

### §10.0 — Empirical probe pass + `ServerProbe` subsystem design

Mandatory before any consumption-point code. Output: this doc grows from scoping → empirical findings + subsystem design (mirroring §5.4.0's evolution). **The empirical pass is structured as a CLI smoke-harness suite per [`V2_PHASE10_SMOKE_HARNESS_PLAN.md`](V2_PHASE10_SMOKE_HARNESS_PLAN.md)** — six per-surface smokes (Chat / Summariser / Extractor / Blurber / Director / Embed) + a `SmokeAll` aggregate runner with JSON-report output. Building on the `CardGenSmoke` pattern; each smoke is independently useful and the runner's findings feed `ServerCapabilities`. Concretely:

1. Pre-probe research — scan for additional probe candidates beyond the §2 list. The brief search done during scoping surfaced [Llama 4 chunked attention](https://github.com/huggingface/transformers/issues/37351), [Gemma 3 sampler defaults](https://gemma-llm.readthedocs.io/en/latest/colab_sampling.html), and [RAG context-neglect](https://www.getmaxim.ai/articles/rag-evaluation-a-complete-guide-for-2025/) — all worth probing.
2. Run all §2 probes against the currently-loaded model (Qwen3.6-Uncensored at scoping time).
3. Request user model-swap; run all probes against Gemma.
4. Document model-family-specific findings; identify which probes would add value against future models.
5. Design the `ServerProbe` subsystem (data model, probe runner, capability cache, settings UI, expiration policy).

~2 days. **No code yet** — design output only.

### §10.a — `ServerProbe` data model + probe runner

- `ServerCapabilities.swift` — Codable struct cached per `ServerProfile.id`. Fields per probe; nullable so missing-data is distinguishable from negative-result.
- `ServerProbe.swift` — runs probes on demand; surfaces results. Background-async, never blocks the chat path.
- Probe-result caching: per-server, invalidated on model-name change (parsed from `/api/v1/model`) or KoboldCPP version change.
- Diagnostic logging: `serverprobe:` prefix per `feedback_diagnostic_logging` rule.
- Tests: stub server returning canned responses; verify each probe's parsing, capability inference, cache invalidation on model-change.
- ~2-3 days. Tests-first.

### §10.b — Settings UI

- `Settings → Servers` row gains a **"Probe"** button next to each profile.
- Result surface: capability summary (model family, supports json_schema, recommended sampler defaults, thinking-pre-fill applicability, max ctx) — read-only inline panel that expands.
- "Re-probe" action; "Clear capability cache" debug action.
- Auto-probe on first connection to a new server (with a one-time "probing your server, ~10s" toast); manual re-probe otherwise.
- ~1 day.

### §10.c — Chat-path consumption points

Wire the existing chat assembly to read `ServerCapabilities` instead of hardcoded behavior. Concrete touch-points (subject to refinement during §10.0):

- `template.assemble` reads `capabilities.thinkingPrefill` rather than hardcoding the empty `<think></think>` for all templates.
- `SamplerPreset` becomes a *base* preset; `capabilities.recommendedSampler` overrides per-server when probed.
- `KoboldClient.generate` selects between `/api/v1/generate` (text-completion) and `/v1/chat/completions` (when `capabilities.chatCompletions` && `capabilities.jsonSchema`) based on call-site needs.
- Stop sequences augmented from `capabilities.observedStopTokens` (from §2 probe 4).
- `effectiveCtx` enforces `min(configured, capabilities.maxCtx)`; if the model is Llama 4 Scout, additionally caps at 8192 per the chunked-attention finding unless the user explicitly opts in.
- Phase 8 `DirectorPicker` thinking pre-fill: same as `template.assemble` — capability-driven, not hardcoded.
- ~2-3 days.

### §10.d — Memory/retrieval observability

The "context neglect" measurement is its own sub-pass because it requires UI work, not just probing. Concretely:

- A `RetrievalUtilization` debug toggle in Settings → Debug. When on:
- Each chat turn logs the retrieved chunks (already in [`MEMORY_AUDIT.md`](MEMORY_AUDIT.md) territory) plus a post-generation pass that searches the response for token-overlap with each retrieved chunk.
- Diagnostic line per turn: `retrieval: 4 chunks retrieved, 2 used (chunk-ids: a3,b1), 0 ignored entities`.
- Aggregate: a Settings → Debug → "Memory hit-rate (last 100 turns)" readout: hit-rate, ignored-but-relevant, etc.
- ~1-2 days.

### §10.e — Polish + smoke

- Per-probe diagnostic-log review.
- Re-probe guard: refuse to auto-probe if a probe has fired in the last 5 minutes (avoid flapping).
- Smoke against Qwen + Gemma + (whichever third model the user happens to have at the time).
- ~1 day.

**Total Phase 10 effort:** ~9-13 days end-to-end. Lands strictly after Phase 9 §5.4.

---

## 2. Probe taxonomy

The probe set, with rationale + chat-path decision each one informs. Empirical results land in §10.0.

### 2.1 Auto-detection probes (server-shape)

Cheap, run on first connection. Cached aggressively.

| # | Probe | Endpoint / method | Informs |
|---|---|---|---|
| A1 | Model identity | `GET /api/v1/model` (KoboldCPP) | Model-family detection (`qwen` / `gemma` / `llama` / `mistral` / `deepseek` / `phi` / `yi` substring match), tuning markers (`uncensored` / `abliterated` / `dolphin` / `instruct` / `chat` / `base`) |
| A2 | Server identity | `GET /api/extra/version` | KoboldCPP build feature gates (json_schema availability, embeddings, vision); fallback paths for non-Kobold backends (Ollama, llama.cpp server, Tabby, etc.) |
| A3 | Max ctx | `GET /api/extra/true_max_context_length` | `effectiveCtx` cap; warns if configured > supported |
| A4 | json_schema support | tiny `/v1/chat/completions` call with `response_format` | Mode 2/3 of card-gen (already settled in §5.4.0); future structured-output features in chat |
| A5 | Embeddings support | server-info field | Phase 7 vector-store routing (skip a server that doesn't expose embeddings) |

### 2.2 Behavior probes (chat-shape)

More expensive; run once per model-change, cached for the session.

| # | Probe | Method | Informs |
|---|---|---|---|
| B1 | Thinking-trap behavior | Two `/api/v1/generate` calls — one with empty `<think></think>` pre-fill, one without — at realistic chat-prompt length (~1k tokens). Measure response length + leading content. | `capabilities.thinkingPrefill` — applied only on Qwen3 / Qwen3.6 / future thinking-mode models. Avoids the harmless-but-wasteful pre-fill on Gemma / Llama / Mistral |
| B2 | Sampler defaults sanity | Three short generations at the model's recommended defaults (parsed from a model-family lookup table) vs. `SamplerPreset.balanced`. Compare output length, repetition rate, and a quick-and-dirty distinctiveness score. | `capabilities.recommendedSampler` — surfaces the model's own preferred defaults to the chat path |
| B3 | Stop-sequence honoring | `/api/v1/generate` with chat template's stop sequences; verify the model emits at least one of them within `max_length`. | `capabilities.observedStopTokens` — augments the chat template's stop set. Catches fine-tunes that drifted from base. |
| B4 | Chat-completions endpoint correctness | A `/v1/chat/completions` call with the same prompt content as B1; check whether the endpoint handles thinking suppression internally (per §5.4.0 finding on Qwen3.6 + KoboldCPP v1.111.2) | `capabilities.chatCompletionsHandlesThinking` — when true, certain side-calls (card-gen Mode 2/3) can skip the manual pre-fill |

### 2.3 Performance probes (latency-shape)

Most expensive; run on first probe + on user-requested re-probe. Results inform UI copy ("this model takes ~Xs for typical replies") rather than load-bearing decisions.

| # | Probe | Method | Informs |
|---|---|---|---|
| P1 | Cold prompt-process speed | Single ~4k-token prompt with no warm cache (after a deliberate cache-buster). Measure time-to-first-token. | Sets latency budget for `DirectorPicker` timeout, AI-assist progress copy |
| P2 | Warm prompt-process savings | Same 4k prefix + 50-token user-msg append. Measure time-to-first-token vs P1. | Confirms KV-cache reuse works on this server (per §5.4.0 baseline); identifies servers where it doesn't |
| P3 | Generation throughput at three lengths | 50 / 200 / 500 token replies. Measure tokens/sec for each. | UI "this'll take ~Xs" hints; default `max_length` recommendations |
| P4 | Streaming chunk cadence | Stream a 200-token reply; record time-to-first-token + inter-chunk gap distribution | UI smoothness expectations; timing of typing-indicator updates |
| P5 | Near-max-ctx coherence | Push history to ctx_max - 100 tokens, generate. Verify output is non-trivial + parseable. | Catches context-shift misbehavior; catches Llama 4 Scout chunked-attention edge cases at 8k+ |

### 2.4 Posture probes (content-shape)

Quick, run once per probe pass.

| # | Probe | Method | Informs |
|---|---|---|---|
| C1 | Refusal posture | Single sentinel NSFW prompt against the model with the chat template applied. Check for refusal regex match per §5.4.0 §8.3 | `capabilities.refusalPosture` — `permissive` / `aligned` / `unknown`. Soften refusal-detection copy on `permissive` (per §5.4.0 §8.4); strict on `aligned` |
| C2 | NSFW license phrase efficacy | Same prompt with vs. without the bundled "explicit content allowed" license. Compare output length. | Tells us whether the license phrase actually changes behavior on this model — informs whether to bundle it on this server's default chat-template system prompt |

### 2.5 Memory-subsystem probes

Rationale per the user's request to include the retrieval-relevance pass. These are *passive* probes — they don't issue extra side-calls; they observe existing chat traffic.

| # | Probe | Method | Informs |
|---|---|---|---|
| M1 | Retrieval hit-rate | After each chat turn, search the model's response for n-gram overlap (n=4, normalised) with each retrieved chunk; mark a chunk as "hit" if overlap > threshold. Record hit / no-hit / response-irrelevant-to-any-chunk. | Surfaces "context neglect" (per [Google DeepMind / RAG eval literature](https://www.getmaxim.ai/articles/rag-evaluation-a-complete-guide-for-2025/)). If hit-rate is < 30%, retrieval is wasted budget; the §10.d UI surfaces this |
| M2 | Retrieval Recall@k vs. Precision@k | Requires a benchmark set (synthetic Q→relevant-chunk pairs). Probably out-of-scope for §10.0; flag as future work in §10.d follow-up | Optimal `k` for the chat's retrieval pass — possibly different per model family (Llama models with chunked attention may benefit from fewer-but-tighter retrievals; Gemma may tolerate more) |
| M3 | Tail-reinforcement effectiveness | Compare turns where Phase 8's tail-reinforce extracted memory entities vs. didn't, look for follow-up coherence in subsequent turns. Probably needs §10.d UI tooling first | Tells us whether tail-reinforce is paying for itself on this model |

M1 is the cheap, high-value probe. M2/M3 likely defer to a §10.d follow-up.

---

## 3. `ServerCapabilities` data model (sketched)

Sketch only; concrete shape settled in §10.0. A `Codable` struct cached at `~/Library/Application Support/RPClient/server_capabilities/<server-uuid>.json`:

```swift
struct ServerCapabilities: Codable {
    var probedAt: Date
    var probeProtocolVersion: Int        // bumped when probe set changes; invalidates older caches
    var serverFingerprint: ServerFingerprint  // model-name + kobold-version; invalidates on swap

    // §2.1 Auto-detection
    var modelName: String                // raw from /api/v1/model
    var modelFamily: ModelFamily         // .qwen3 / .gemma3 / .llama4 / .mistral / .deepseek / .other(String)
    var tuningMarkers: Set<String>       // "uncensored" / "instruct" / "abliterated" / ...
    var koboldVersion: String?
    var maxCtx: Int
    var supportsJsonSchema: Bool
    var supportsEmbeddings: Bool

    // §2.2 Behavior
    var thinkingPrefill: ThinkingPrefill // .needed (Qwen3+) / .harmless (Gemma) / .unknown
    var recommendedSampler: SamplerPreset?  // nil = use SamplerPreset.balanced
    var observedStopTokens: [String]
    var chatCompletionsHandlesThinking: Bool

    // §2.3 Performance
    var coldPromptProcessMsPerKToken: Double?
    var warmPromptProcessSavingsPercent: Double?
    var throughputTokensPerSec: ThroughputProfile?  // 50/200/500-token measurements
    var streamFirstTokenMs: Double?
    var nearMaxCtxCoherent: Bool

    // §2.4 Posture
    var refusalPosture: RefusalPosture   // .permissive / .aligned / .unknown
    var nsfwLicenseEffective: Bool

    // §2.5 Memory (M1 passive; populated by a different code path, but cached here)
    var retrievalHitRateLast100: Double?
}

enum ThinkingPrefill: String, Codable {
    case needed       // Qwen3+ — emit empty <think></think> pre-fill
    case harmless     // Gemma / Llama — pre-fill is harmless but wasted bytes
    case unknown      // pre §10.0 probing
}

enum RefusalPosture: String, Codable {
    case permissive   // model produces NSFW content with bundled license
    case aligned      // model refuses; soften nothing, surface server-switch
    case unknown
}
```

Cache invalidation:

- On `probedAt` older than 30 days (model files don't change but server-side fine-tunes might be replaced).
- On `serverFingerprint` mismatch (model-name or kobold-version change).
- On `probeProtocolVersion` mismatch (we shipped new probes).
- Manual via Settings → Servers → "Re-probe".

---

## 4. `ServerProbe` subsystem (sketched)

```swift
actor ServerProbe {
    static let shared = ServerProbe()

    /// Run all probes against the given server profile. Idempotent — caches
    /// results in `ServerCapabilities`. Returns the resolved capabilities;
    /// stale cache short-circuits the network calls.
    func capabilities(for: ServerProfile, force: Bool = false) async throws -> ServerCapabilities

    /// Listen for capability updates (Settings UI subscribes here).
    var updates: AsyncStream<ServerProfile.ID> { get }
}
```

Probes are independently runnable + skippable (a server that doesn't expose `/api/extra/version` still gets useful capabilities from the rest). Each probe returns a `Result<PartialCapability, ProbeError>`; the runner aggregates and writes the union.

Telemetry (per `feedback_diagnostic_logging`):

```
serverprobe: starting <server-name> (model=<name>, force=<bool>)
serverprobe: A1 model-identity → <family>/<markers>
serverprobe: B1 thinking-trap → <needed|harmless|unknown> (cold=<chars>, prefilled=<chars>)
serverprobe: P3 throughput → 50t=<X>tok/s 200t=<Y> 500t=<Z>
serverprobe: complete <server-name> in <ms>ms
serverprobe: skipped <PXX> — <reason>
```

---

## 5. Open questions for §10.0

Settled by empirical work + design pass when Phase 10 starts.

1. **Probe budget.** Running every probe end-to-end against a slow server might take 30-60s. What's the user-acceptable first-probe wait? Toast vs. modal vs. background-with-notification?
2. **Re-probe trigger granularity.** Auto-re-probe on model-name change is obvious. What about on KoboldCPP version-bump (might enable new features)? On configured-ctx change?
3. **`ModelFamily` enum extension policy.** Future models drop in monthly. Should the enum be open (string-backed with known-cases) or closed (enum-with-exhaustive-switch)? Probably open — we don't want to ship a release every time a new model family appears.
4. **Sampler-recommendation source.** Per-family defaults (Gemma's authors recommend specific values) live where? Bundled lookup table in code, or per-server probe-derived? Likely both — bundled defaults with probe-derived overrides.
5. **Memory probe (M1) implementation.** Token-overlap heuristic is rough. Should §10.d invest in a smarter "did the model use this chunk" detector (e.g., cosine similarity against the response embedding)? Probably defer to a §10.d follow-up.
6. **Multi-server probe ordering.** If the user has 5 server profiles, do we probe all on app-startup or lazily on first-use? Lazy.
7. **Probe failure handling.** If a probe times out or returns garbage, do we mark the capability as `.unknown` and proceed, or block the chat path? Always proceed — `ServerCapabilities` defaults to the existing hardcoded behavior on unknown.

---

## 6. References

**Internal:**
- [`V2_PHASE9_AI_ASSIST_RESEARCH.md`](V2_PHASE9_AI_ASSIST_RESEARCH.md) §3 (KV-cache reuse measurement methodology) and §8 (refusal-posture probe).
- [`Sources/RPClientCore/DirectorPicker.swift`](Sources/RPClientCore/DirectorPicker.swift) — existing thinking-pre-fill pattern (current consumption point).
- [`Sources/RPClientCore/Models/Settings.swift`](Sources/RPClientCore/Models/Settings.swift) — `ServerProfile` storage.
- [`MEMORY_HANDOFF.md`](MEMORY_HANDOFF.md) — memory-subsystem state for M1 probe wiring.

**External:**
- [Llama 4 chunked attention behavior — HuggingFace transformers #37351](https://github.com/huggingface/transformers/issues/37351).
- [Llama 4 Scout 8192 chunked attention — Daniel Han analysis](https://x.com/danielhanchen/status/1909726119500431685).
- [Gemma 3 sampler defaults (temp=1.0, top_k=64, top_p=0.95)](https://gemma-llm.readthedocs.io/en/latest/colab_sampling.html).
- [Gemma 3 chat template + BOS handling — Unsloth](https://unsloth.ai/blog/gemma3).
- [RAG evaluation 2025 — context-utilization + faithfulness metrics](https://www.getmaxim.ai/articles/rag-evaluation-a-complete-guide-for-2025/).
- [RAG context-neglect literature](https://arxiv.org/html/2504.14891v1).
- [KoboldCPP wiki — context shifting + fast-forwarding](https://github.com/LostRuins/koboldcpp/wiki).

**Probe transcripts (deferred to §10.0).** When §10.0 runs, this section grows with the same shape as §5.4.0's empirical-probe section — reproducible curl/python invocations + measured results per model.
