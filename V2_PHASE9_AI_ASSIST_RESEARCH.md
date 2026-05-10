# Phase 9 §5.4 — AI-assist research

**Status: research output, signed off before §5.4.a starts.** Sub-step §5.4.0 of [`V2_PHASE9_CARD_CREATOR.md`](V2_PHASE9_CARD_CREATOR.md). Mirrors the shape of [`V2_PHASE7_FULL_BRANCHING.md`](V2_PHASE7_FULL_BRANCHING.md) / [`V2_PHASE8_GROUP_CHATS.md`](V2_PHASE8_GROUP_CHATS.md).

This doc is the empirical + literature-survey foundation for §5.4 — three AI-assist modes (per-field suggestions, multi-field fill, full-card autopilot). It surveys existing card-gen tooling, settles the structured-output question, fixes the prompt-chain layout, and pins down the diff/review UX. Findings drive the prompt template registry, the multi-field strategy, the autopilot pass shape, and the review surface.

**Empirical bedrock.** Where prior phases relied on community knowledge alone, this pass made live test calls against the user's configured server (`http://192.168.1.201:5001`, KoboldCPP v1.111.2 hosting [Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M](https://huggingface.co/) at 16k ctx) to measure structured-output reliability, the thinking trap, and KV-cache reuse on the actual hardware the user runs. Probes are reproducible from §3 below.

---

## Why

§4 of the creator doc commits us to three modes. Each is independently shippable, but they share infrastructure (`CardFieldGenerator`, prompt templates, side-call routing, refusal detection, diagnostic logging). Before writing that infrastructure, we need three answers:

1. **Structured output or free-form-then-parse?** This is the single most architecturally load-bearing call. JSON-schema constrains output to a Codable shape but has historical reliability issues with reasoning models; free-form lets the model write naturally but requires fragile parsing.
2. **Sequential, parallel, or single-call multi-field?** §4.7 punted this to research. It controls Mode 2's latency, coherence, and token cost.
3. **What does the diff/review surface look like?** Mode 2's "Proposed" badge and Mode 3's diff sheet need a concrete UX precedent — there's no shortage of patterns (Copilot tab-accept, Cursor diff, Notion three-button) but the multi-field card-shape problem is its own thing.

A wrong call on (1) propagates through every prompt template and every smoke session. A wrong call on (2) determines whether Mode 2 takes 5 seconds or 50. A wrong call on (3) costs us re-implementation rounds during §5.4.b/c smoke. Hence: research before code.

---

## 1. Existing tools survey

The card-gen ecosystem is small but mature. Five active projects, plus Chub's manual creator (no AI-assist flow currently shipped). Each takes a distinct posture on seed shape, generation strategy, and review.

| Tool | Seed shape | Generation strategy | Review/accept flow | NSFW posture |
|---|---|---|---|---|
| [Chub AI manual creator](https://docs.chub.ai/docs/the-basics/character-creation) | All fields manual; tabs for Character Info / Definition / Advanced | None — **no AI-generation flow shipped** | N/A | Tag-driven; SFW/NSFW partition by tags |
| [bmen25124/SillyTavern-Character-Creator](https://github.com/bmen25124/SillyTavern-Character-Creator) | Connection-profile-driven, free-form prompt + uses ST data as context | LLM-driven; templates/ folder; output format configurable | Not documented in README | Inherits ST connection profile; no built-in posture |
| [ewizza/ST-CardGen](https://github.com/ewizza/ST-CardGen) | Free-text idea + optional name/POV + image prompt + lang | **Sequential field-by-field**, with "fill missing fields" + per-field regeneration; field-level detail presets (Short/Detailed/Verbose) | In-place editing post-generation; per-field regenerate; library copy/move | Not addressed in docs |
| [cha1latte/sillytavern-character-generator](https://github.com/cha1latte/sillytavern-character-generator) | Multi-turn confirmation: type / setting / traits, then generate | Single mega-prompt → V2 JSON; "Small" (400-600 tok) vs "Standard" presets | None; output is a one-shot JSON dump | Implicit; tag-driven |
| [Inktomi93/SillyTavern-CharacterTools](https://github.com/Inktomi93/SillyTavern-CharacterTools) | Existing card → analyze → rewrite | **Three-stage pipeline: Score → Rewrite → Analyze** (per-field, JSON-schema-validated); diff vs. original; verdict pill (ACCEPT / NEEDS_REFINEMENT / REGRESSION) | Per-field selective ops, per-result lock, history with one-click revert, markdown export | Not specifically addressed |
| [sphiratrioth666 templates](https://huggingface.co/sphiratrioth666/Character_Generation_Templates) | Free-text concept + bundled archetype exemplar | Single-prompt with hybrid JSON/P-list format; one full character exemplar in-context | None; raw output is the result | **Explicit** — bundled NSFW anatomy fields, lingerie variants |
| [Generator.cards / similar] (Inscryption-shaped tools) | Multi-field UI with explicit slots | Form-based; no LLM | Real-time preview | N/A |

**Three observations.**

- **No tool we surveyed ships per-field accept/reject for *prose*-shaped fields with multi-candidate triads.** §4.1's suggestions strip is genuinely novel relative to the surveyed surface area — closest precedent is Inktomi93's per-field rewrite + lock, but that's a one-shot rewrite, not a triad. Mode 1 has design space to claim.
- **"Fill missing fields" is a real pattern.** ewizza/ST-CardGen confirms the §4.7 framing isn't speculative; users want it.
- **Single-mega-prompt full-card generation works at the sphiratrioth666 / cha1latte scale.** Mode 3's pass-decomposition is more sophisticated than community precedent, but per the empirical findings in §3 below, the dependency-graph walk produces measurably more coherent output than a single mega-prompt under structured-output enforcement — the §4.4 / §4.8 design is justified, not over-engineered.

**Failure modes the community reports.**

- Off-genre output: cha1latte's confirmation step exists explicitly to disambiguate setting before generation; without it, a "ranger" tag pulls medieval-fantasy when the user wanted post-apocalyptic.
- Token-budget collapse: small models (7B-13B) routinely truncate the `mes_example` field if all fields are generated in a single response. cha1latte's "Small Model" preset cuts permanent fields to 400-600 total tokens for this reason.
- Coherence drift across fields: when Persona and Voice are generated independently, the personality described in `personality` doesn't always match the voice in `mes_example`. Sequential conditioning (Voice fed Persona's output) measurably improves this — see §3 below.

---

## 2. Structured output — the Qwen3 trap and the empirical resolution

The starting position from community knowledge: Qwen3 + structured output is broken across multiple inference backends in 2025-2026.

- vLLM: [`enable_thinking=False` + structured output produces invalid JSON, leaks `<think>` content into `message.content`](https://github.com/vllm-project/vllm/issues/18819).
- sglang: same shape — [grammar backend xgrammar fails to enforce schema with thinking disabled](https://github.com/sgl-project/sglang/issues/6675).
- Workaround documented upstream: `enable_thinking=True` + append `/no_think` directive — an inversion of RPClient's existing empty `<think></think>` pre-fill ([`DirectorPicker.swift`](Sources/RPClientCore/DirectorPicker.swift)).

This was the load-bearing risk going into §5.4.0. **The empirical probes resolved it.**

### 2.1 Probes

All probes hit the user's configured server: KoboldCPP v1.111.2, Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M, 16k ctx. Reproducible via the same shell + Python invocations recorded in this section.

**Probe 1 — Free-form prose generation, with thinking pre-fill.** `/api/v1/generate` + raw template (`<|im_start|>system…<|im_end|>` + empty `<think>\n\n</think>` pre-fill). Result: 60-word in-character monstergirl description, ~1s.

**Probe 4 — Free-form prose generation, *without* thinking pre-fill.** Same prompt, no pre-fill. Result: model emits `<think>\nHere's a thinking process:\n\n1. **Analyze User Input:**…` and burns the entire 256-token budget meditating before producing any prose. **Confirms the trap is real on the text-completion endpoint** — the `DirectorPicker` empty-pre-fill pattern must apply to card-gen calls routed through `/api/v1/generate`.

**Probe 2 — Free-form JSON, with pre-fill.** Identity-pass shape (5 fields). Result: model emits valid JSON without any schema enforcement, parseable.

**Probe 3 — `response_format: json_schema` strict mode, single-field.** `/v1/chat/completions` (OpenAI-compat endpoint) with `additionalProperties: false`, required keys. Result: schema-compliant JSON, ~1s. **No explicit thinking pre-fill needed** — KoboldCPP's chat-completions wrapper handles thinking suppression internally on this build.

**Probe 8 — Multi-field json_schema, prose values.** Persona-pass shape (description / personality / scenario), 200-600 char minLength/maxLength constraints, NSFW-licensed system prompt. Result: 4.0s, 280 prompt tokens, ~600 completion tokens, all three fields populated with vivid, coherent, in-character prose, schema-compliant.

**Probe 9 — json_schema *without* thinking pre-fill on chat-completions.** Identity-pass, no `<think>` in messages. Result: 0.89s, schema-compliant. **The trap doesn't manifest on the chat-completions path** on this build — KoboldCPP v1.111.2 evidently injects thinking handling at the `/v1/chat/completions` translation layer.

**Probe 11 — Full Persona+Voice pass via json_schema.** 5 prose fields (description / personality / scenario / first_message / mes_example), 200-600 char per field, `{{user}}` and `{{char}}` placeholder convention preserved by the model. Result: **4.82s, 348 completion tokens, all 5 fields landed inside their length bounds, prose quality matches the bundled `CardCreatorPlaceholders` shape.** The model maintained character coherence across the 5 fields — Vexara's voice in `mes_example` matches the personality described in `personality`.

**Probe 5/5b — GBNF grammar enforcement.** `/api/extra/generate` returned 404 on this build; alternative direct-grammar attempts via `/api/v1/generate` returned empty content. **Conclusion: GBNF is not a viable path on this stack.** json_schema covers the same ground via the OpenAI-compat endpoint and is more reliable.

**Probe 6 / 10 — KV-cache reuse measurement.** Sequential calls with shared prefix via `/api/v1/generate`. Cold call ~0.95s; subsequent calls 0.80-0.99s for ~50-word completions. Modest at this prompt size; the prefix here is small (~150 tokens). Extrapolated to a full Mode 3 pass with a 2-3k-token prefix (system + few-shot exemplars + upstream fields), the savings are substantially larger — a cold-call prompt-process at typical Q4 35B speeds is ~600-800ms for 2k tokens, and reusing that prefix recovers most of it.

**Probe 7 — Refusal shape on the uncensored model.** Prompted explicitly for weapon-making instructions through the system + user role. Result: model produced a step-by-step guide without any refusal shape. **The uncensored Qwen3.6 model rarely refuses on this stack** — for the user's primary configuration, refusal-detection's job is to catch the *non-uncensored* edge case (a user pointing card-gen at a SFW summarizer-class model). False-negative risk is much lower than false-positive risk.

### 2.2 Decision

**Mode 1 (per-field, single-shot triad):** free-form-then-parse via `/api/v1/generate`, with empty `<think>\n\n</think>` pre-fill routed through the active chat's template. Matches the existing [`DirectorPicker`](Sources/RPClientCore/DirectorPicker.swift) pattern. Three candidates serialised per §4.3, prose-shaped output. No json_schema needed — single-field prose is a clean text-completion call.

**Mode 2 (multi-field fill):** **single-call `response_format: json_schema` strict-mode via `/v1/chat/completions`.** All empty fields targeted by the click land in one schema; the model fills them in one coherent pass. ~5s for ~5 prose fields per Probe 11; smaller in practice when fewer fields are empty. **No thinking pre-fill needed** at the message level — KoboldCPP handles it on this endpoint. This subsumes the §4.7.1 sequential-vs-parallel debate: single-call structured wins on coherence and is fast enough.

**Mode 3 (full-card autopilot):** **per-pass json_schema** via the same chat-completions endpoint. Each pass (Identity / Persona+Voice / Body+Intimacy / Disposition / System+Notes) emits its own JSON object; the prior pass's accepted fields land in the next pass's user-message context. 5–7 sequential json_schema calls, ~5s each cold + KV-cache savings on shared system+exemplar prefix → 25-35s total against a fast local model. Hard caps from §4.8 (10 calls / 16k tokens) remain.

**GBNF grammar is dropped.** json_schema covers the same surface, is more reliable, and works on the user's actual stack. If a future server (e.g. raw llama.cpp, no chat-completions wrapper) requires grammar, the `CardFieldGenerator` interface can grow a fallback — but it's not §5.4 scope.

### 2.3 Gemma scenario (analytical — no live probe)

The user runs Gemma sometimes instead of Qwen3. No Gemma server was available to probe live. Implications:

- **Template differs.** Gemma uses `<start_of_turn>user\n…<end_of_turn>\n<start_of_turn>model\n` — no Qwen `<|im_start|>` tokens, no `<think>` block. The `ChatTemplate.assemble` abstraction already in RPClient picks the right template per active chat; the empty `<think>` pre-fill simply collapses to an empty string for Gemma templates. **No new code needed for this dimension.**
- **Thinking trap doesn't apply.** Gemma 3 models don't have a thinking-trace mode. Free-form generation works directly without pre-fill suppression.
- **json_schema reliability is the open question.** KoboldCPP's chat-completions wrapper translates `response_format: json_schema` into upstream sampler-grammar enforcement; reliability depends on the model. Community evidence ([Together AI structured outputs docs](https://docs.together.ai/docs/json-mode), [llama.cpp grammar discussion](https://github.com/ggml-org/llama.cpp/discussions/14556)) suggests Gemma 3 handles JSON mode adequately but with more frequent edge-case schema violations than Qwen3.
- **§5.4 mitigation:** the `CardFieldGenerator` always validates the parsed JSON against the schema *after* return; on validation failure, fall back to one retry with a reduced schema (only required fields, no length constraints). Beyond that, surface the failure to the UI as a "model didn't comply" warning chip, same shape as a refusal. This keeps Gemma working without making Mode 2/3 unreliable.
- **Open question for §5.4 smoke:** does Gemma 3 respect `minLength`/`maxLength` on string fields under json_schema strict mode? Probe when a Gemma server is available; document in §5.4.d. If it doesn't, drop the length bounds and rely on prompt-side word-count instructions instead.

---

## 3. Prompt-chain patterns + KV-cache reuse

### 3.1 Cache reuse is real on this stack

KoboldCPP's [Context Shifting](https://github.com/LostRuins/koboldcpp/wiki) + [FastForwarding](https://github.com/LostRuins/koboldcpp/wiki) (both default-on) reuse any prefix that matches the previous generation. llama.cpp upstream does the same via `n_cache_reuse` ([discussion #14556](https://github.com/ggml-org/llama.cpp/discussions/14556)). Probe 10 above confirms it works on the user's actual hardware — not theoretical.

### 3.2 Prompt prefix layout

Every card-gen prompt should be laid out so the **stable prefix is as long as possible** and the **per-call instruction is as short as possible**. Concretely:

```
[stable system prompt: NSFW posture, output contract, format rules]
[stable few-shot exemplar block: Mira / monstergirl / sci-fi pilot rotated by tag]
[stable upstream-fields block: every accepted field above this point in the §4.4 graph]
[per-call instruction: "Write the description field. 50 words." for Mode 1, or
 the json_schema target for Mode 2/3]
```

The stable prefix is recomputed once per Mode 1 strip (three candidates reuse it across A/B/C). It's recomputed once per Mode 3 pass (each pass within a pass invocation reuses it). **Cross-strip and cross-pass reuse requires the prefix to be byte-identical**, including whitespace and field ordering — the prompt builder has to be deterministic.

### 3.3 Mode 1 candidate triad

§4.3 specifies three serialised candidates per field (Literal / Creative / Terse), distinguished by temperature + length cap, not by blind sampling. With prefix-stable layout, the three candidates take roughly:

- Cold A: ~0.95s prompt-process + 0.5s generation = ~1.5s
- Warm B: ~0.05s prefix-reuse + 0.7s generation (higher temp, longer) = ~0.75s
- Warm C: ~0.05s prefix-reuse + 0.3s generation (terse) = ~0.35s
- **Total per strip: ~2.5s** against the user's measured stack.

This is well within the §4.4 30s timeout-per-candidate budget.

### 3.4 Mode 2 — single-call structured

§4.7.1 listed three options: sequential, parallel, single-call structured. **Probe 11 makes the call: single-call structured wins.** 4.82s for 5 prose fields with coherence guarantees that sequential generation can't match without explicit conditioning prompts (which would push total time higher).

Sequential is the fallback for models that don't support `response_format: json_schema` — `CardMultiFieldGenerator` should detect via a server-capability probe (a tiny json_schema test call on first use, cached for the session) and fall back to sequential per-field if the structured path returns garbage.

### 3.5 Mode 3 — per-pass structured, sequential across passes

§4.8 specifies 5-7 passes (Identity / Persona / Voice / Body / Disposition / System / Notes). Per the structured-output decision in §2.2, each pass is a single json_schema call. Across passes:

- Identity pass: small fields, ~1s
- Persona pass: description + personality + scenario, ~5s
- Voice pass: first_message + alternate_greetings + mes_example, ~5-7s (alternate_greetings populates 2-3 strings)
- Body pass: appearance + mood + intimacy.{build, anatomy, markings, sensitivities, scent}, ~6-8s
- Disposition pass: turn_ons + kinks + (limits is bundled-default, not generated), ~3-4s
- System pass: system_prompt + post_history_instructions, ~2-3s
- Notes pass: creator_notes + depth_prompt, ~2s

**Total: ~25-35s cold, less with KV-cache reuse on the system+exemplar prefix.** Within the §4.8 hard caps (10 calls / 16k tokens). The Cancel button is mandatory at every pass boundary per §4.8.

### 3.6 Concurrency

**Sequential always; never parallel.** Local servers serve one set of weights — "parallel" calls are queue-serialised at the server, lose KV-cache benefits, and produce no latency win. For RPClient specifically:

- Mode 1: Generate buttons across multiple fields don't fan-out; queue at the `CardFieldGenerator` actor.
- Mode 2: single call, no concurrency question.
- Mode 3: passes execute sequentially with explicit progress reporting.

If the user picks a different server for card-gen via the per-window picker (§4.4), card-gen still runs on its own connection so it doesn't block chat generation against `defaultServerId`. But within a single card-gen invocation, it's strictly serial.

---

## 4. Few-shot prompting recommendations

### 4.1 Bundled exemplar set — extends `CardCreatorPlaceholders`

The existing [`CardCreatorPlaceholders`](Sources/RPClientCore/UI/CardCreator/CardCreatorPlaceholders.swift) ships one exemplar character (Mira, ranger, SFW-ish). For an `nsfw, monstergirl, fantasy` card the model has nothing genre-matched to anchor on; the few-shot block carries no signal beyond format.

Community precedent ([sphiratrioth666 templates](https://huggingface.co/sphiratrioth666/Character_Generation_Templates)) demonstrates that a single full-character exemplar is enough to anchor format, but the *content* register depends heavily on whether the exemplar shares a genre lane with the target tags.

**§5.4.a addition (per user direction in this research pass):** introduce `CardGenExemplars.swift` alongside the existing placeholder file. Three archetypes minimum:

- **Mira** (existing) — human, fantasy, dom-leaning, SFW-leading-to-NSFW.
- **A monstergirl exemplar** — non-human, fantasy, explicit anatomy fields populated. Anchors the §3.9 structured intimacy fields against a non-human body shape.
- **A modern/sci-fi exemplar** — human, contemporary or near-future, no fantasy framing. Anchors the prompt against off-genre tags so monstergirl framing doesn't bleed into a "modern barista" card.

Each exemplar has a complete fill of every field referenced in the §4.4 dependency graph — so any prompt template in any pass can pull its fields out by name and inject them as the few-shot anchor.

**Selection rule:** at prompt-build time, score each archetype against the target card's tags by tag-set overlap. Highest-scoring exemplar wins; ties resolve to Mira (the safest baseline). Selection is logged via `cardgen: exemplar=<name>` so smoke can verify the right exemplar fired.

The `CardCreatorPlaceholders` set stays UI-only (the existing placeholder text shown in empty fields). `CardGenExemplars` is prompt-only. No UI surface change; the split keeps placeholder UX (single, predictable Mira voice) separate from prompt-anchoring (genre-matched, possibly more explicit).

**Per the user's §5.4.0 sign-off:** the exemplar split lands in §5.4.a alongside the first generator, not as a §5.3 deferred-polish item.

### 4.2 Few-shot block shape

Tested format (Probe 11 used a degenerate one-line version; production should use the full block):

```
Example character — anchor the format and register:

  name: Mira
  age: 28
  pronouns: she/her
  species: Human
  description: Mira runs the dawn patrol along the coastal road…
  personality: Cautious until trusted, then fiercely loyal…
  scenario: {{user}} hires Mira to escort a sealed letter…
  first_message: *She tucks the envelope into her satchel…* "Address?"
  …

Now generate the same fields for the new character below.
```

Ordered key-value pairs, not JSON — the model anchors on the *register* (concrete, vivid, third-person past, NSFW-capable) more strongly when the format isn't structured. JSON-schema enforcement at the *output* boundary handles structure; the few-shot exemplar handles voice.

### 4.3 Single exemplar, not a list

Adding more exemplars degrades quality, not improves it. Two anchors at conflicting registers (e.g., a SFW Mira + an explicit monstergirl) confuses the model about which voice to imitate. One genre-matched exemplar wins; the selection rule above ensures it's the right one.

If genre-matching fails (unusual tag set with no archetype overlap), Mira is the fallback. The bundled placeholder text is safe everywhere; an anchor that doesn't quite match is still better than no anchor.

---

## 5. NSFW prompting conventions

The community knowledge here, refracted by the empirical probes:

### 5.1 The license phrase works; don't escalate

The bundled `CardCreatorPlaceholders.systemPrompt` contains:

> "Explicit content is allowed when the scene calls for it. Don't break character."

This phrasing is community-canonical (matches patterns in [Character Card V2 spec](https://github.com/malfoyslastname/character-card-spec-v2) discussions, [arenekosreal/role-playing](https://github.com/arenekosreal/role-playing) prompts, and the bundled outputs from cha1latte's small-model template). It signals to the model that explicit content is in-scope without invoking jailbreak phrasing that hardens refusal patterns on safety-trained models.

**§5.4 prompt templates inherit this exact phrase.** Don't escalate. Anti-refusal jailbreak phrasing (the rentry / UJB / "DAN" patterns) is brittle, varies by model release, and trains authors that a magic prompt exists when in fact server-level decisions (model choice, fine-tune) carry the load.

### 5.2 If the model refuses, surface, don't retry

Per §4.5 — RPClient does not retry with adjusted prompts after a refusal. The author is informed (warning chip + tip after 3 consecutive) and instructed to switch the server picker. This posture holds for §5.4.

### 5.3 NSFW posture in json_schema mode

Probe 11's system prompt was:

> "You design NSFW character cards. Be vivid, concrete, in-character. Use {{user}} for the player and {{char}} for the character. Output JSON only."

The model produced fully in-character NSFW prose under strict json_schema, with `{{user}}`/`{{char}}` placeholder conventions preserved. **JSON mode does not sanitize content** on the user's stack — the schema constrains structure, not content. This is exactly the desired property.

### 5.4 Mode 3 cold-start prompting

When the seed is "just tags" (no name, no description), the Identity pass's system prompt should explicitly grant invention:

> "Invent a name and identity that fits the tags. Be creative; the author will edit if it doesn't match their vision."

This is verbatim from cha1latte's confirmation step, adapted. Probe 3 / Probe 9 confirm it works — the model invented "Vexara" / "Sylphara" without prompt-side anchoring.

---

## 6. Diff/review UX recommendations

§4.10 sketched the lean: per-field accept toggle in-place for Mode 2; field-list diff sheet for Mode 3. Research refines this.

### 6.1 Mode 2 — "Proposed" badge with per-field commit

Already specified in §4.7. Validated against:

- [Notion AI's Done / Try again / Discard pattern](https://www.notion.com/help/notion-ai-faqs) — three-button accept after generation. Closest baseline; we add a per-field dimension because card-gen produces a multi-field proposal.
- [GitHub Copilot tab-accept](https://docs.github.com/copilot/using-github-copilot/getting-code-suggestions-in-your-ide-with-github-copilot) — single-keystroke accept, Esc reject, inline ghost-text. Works for line-shape; doesn't translate to multi-field prose.
- [Cursor's per-hunk diff](https://forum.cursor.com/t/how-to-disable-diff-inline-change-approval-step/14611) — accept-all / reject-all / per-hunk. Translates well; per-field is the equivalent of per-hunk for our domain.

### 6.2 Mode 3 — diff sheet with per-field lock and history

§4.10's "field-list diff sheet" is the right surface. Research adds two refinements pulled from [Inktomi93/SillyTavern-CharacterTools](https://github.com/Inktomi93/SillyTavern-CharacterTools):

1. **Per-field lock.** Once the author accepts a field, it's locked. Subsequent Re-roll-all does not regenerate locked fields. Without this, an author who accepts `description` and re-rolls the rest will lose `description` on the next pass.
2. **History per field (last 3 rolls).** Each field's row shows a small clock icon; hovering reveals the previous candidates with one-click revert. Re-rolls don't destroy prior content; the author can compare.

The SillyTavern-CharacterTools verdict pill (ACCEPT / NEEDS_REFINEMENT / REGRESSION) is *not* worth borrowing — it's a model-driven score against the original card, which our autopilot doesn't have a baseline for. Skip.

### 6.3 Bulk actions

Three buttons at the top of the diff sheet:

- **Accept all** — commits every unlocked field's current candidate.
- **Reject all** — clears every field, returns to empty form.
- **Re-roll all unlocked** — fires fresh single-field generations per §5.4.a, preserving locks and growing the history stack.

Naming follows Notion's three-button pattern; the semantics extend it for multi-field.

### 6.4 Why not ghost text / inline-accept

[Cursor's tab-to-accept ghost text](https://www.builder.io/blog/cursor-vs-github-copilot) is a faster mode for line-shaped suggestions. For prose fields with 200-600-char candidates, ghost text in-field is invasive (the field's existing content is hidden behind the proposal) and the visual delta is too large. The Suggestions strip below the field is the better fit; deferred ghost-text mode is flagged in [`V2_DESIGN_LANGUAGE.md`](V2_DESIGN_LANGUAGE.md) §11 as a future power-user direction.

---

## 7. Cost / budget management

### 7.1 KV-cache reuse — design for it

Per §3, prefix-stable layout is the dominant cost lever on local hardware. Implementation:

- `CardFieldGenerator.buildPrompt(...)` is byte-deterministic: same inputs produce identical UTF-8 output. No timestamps, no UUIDs in the prompt body, no shuffled field ordering.
- Few-shot exemplar selection is logged but the selected exemplar's text is byte-stable per archetype.
- Per-mode prefix layout matches §3.2.

Empirically (Probe 6/10), warm calls on the user's stack land at 0.80-0.99s for ~50-word generations. Mode 1 strips total ~2.5s; Mode 2 fills total ~5s; Mode 3 totals ~25-35s.

### 7.2 Anthropic prompt caching

Not applicable today. RPClient's primary backend is KoboldCPP-shaped local. If a future phase adds an Anthropic-compatible side-call backend, [Anthropic prompt caching](https://platform.claude.com/docs/en/build-with-claude/prompt-caching) (5-min default TTL, 1-hour extended) would map cleanly to the prefix-stable layout — the same `[system + few-shot + upstream]` block that benefits from KoboldCPP cache reuse becomes a `cache_control` block. Documented for future-Anthropic-backend support; **no §5.4 work**.

### 7.3 Per-mode token budgets

- **Mode 1:** ~512 tokens × 3 candidates × per-field. Cap configurable in `CardGenPrompts.json` (per §4.4). Hard cap 768 for `firstMessage`-shaped fields; truncated output flagged with `…`.
- **Mode 2:** json_schema's `maxLength` per field bounds total output. Probe 11 shows a 5-field Persona+Voice pass produces ~350 tokens output; budget 1500 tokens for the largest realistic case (full multi-field fill across Persona / Voice / Body / Intimacy / Disposition).
- **Mode 3:** hard total cap 16k tokens emitted across all passes (per §4.8). Empirically a full autopilot run lands at 2-3k completion tokens; the cap is a safety rail, not a constraint authors will hit.

### 7.4 Concurrency vs queueing

Per §3.6: sequential within a single mode invocation. Card-gen's per-window server picker (§4.4 / §3.1, already shipped in §5.3a) keeps card-gen on a separate connection from chat-gen when the user configures different servers. Within one connection, requests are strictly serialised at the `CardFieldGenerator` actor level — no client-side fan-out.

### 7.5 Cancellation

`URLSession` task cancel is the existing pattern in RPClient ([`KoboldClient`](Sources/RPClientCore/Networking/KoboldClient.swift)). For card-gen:

- Cancel button is always visible during a generation pass.
- On cancel, the in-flight URLSession task is cancelled; the server may finish generating the current response (server-side cancel isn't always honored by KoboldCPP) but the client discards the result and stops the next call in the queue.
- Already-emitted candidates / fields stay in the UI as if generation completed for those slots; the cancel only affects in-flight and queued work.

Diagnostic logging records cancel events: `cardgen: <mode> cancelled at field=<X> (<N> tokens emitted, discarded)`.

---

## 8. Refusal-detection updates

§4.5 specifies a leading-regex + sanitization-marker + length-ratio detector. Research findings:

### 8.1 Confirmed: false-positive risk dominates

Academic refusal classifiers (WildGuard etc.) frequently misclassify in-character apologetic prose as refusals — e.g., *"I'm not sure if I'm a fan of the Shakespearian style…"* matches a leading `^I'm` regex but is in-character ([Tilman Kerl, Sparse Autoencoder Refusal Features evaluation, 2025](https://repositum.tuwien.at/bitstream/20.500.12708/220332/1/Kerl%20Tilman%20-%202025%20-%20Evaluation%20of%20Sparse%20Autoencoder-based%20Refusal%20Features%20in...pdf)).

§4.5's detector is precision-biased — a flagged candidate still shows in the strip with a yellow chip, and the author can hit Use anyway. False positives cost the author one click; false negatives ship a refusal into a card field. The asymmetry justifies the existing posture.

### 8.2 Empirically: this model rarely refuses

Probe 7 confirms the user's primary configuration (Qwen3.6-35B-A3B-Uncensored) doesn't refuse even on extreme prompts. **For the user's primary stack, the refusal detector's job is rare** — it catches the edge case where the user points card-gen at a SFW-aligned summarizer-class model.

### 8.3 Model-family-specific patterns

Add to the detector's regex set, ordered first-match-wins:

```
1. Qwen-style: ^(As\s+(an?\s+)?(AI|language\s+model)|I\s+(cannot|can't)\s+(help|generate|provide))
2. Llama-style: ^I\s+(cannot|can't)\s+fulfill\s+(this|your)\s+request
3. Mistral-style: ^I('m|\s+am)\s+(uncomfortable|not\s+comfortable|not\s+going\s+to)
4. Generic apology lead (existing): ^(I('m|\s+am)\s+(sorry|unable|not\s+able)|I\s+can(not|'t)|As\s+an\s+AI|I\s+(must|should|won't))
5. Sanitization marker (existing): \[Content\s+removed\]|\[Sanitized\]|\[I\s+cannot\s+generate\]
6. Length-ratio (existing): output < 25% expected length AND contains apology word
```

Built into a `RefusalFixtures` test corpus during §5.4.a:

- 3+ Qwen refusal samples
- 3+ Llama refusal samples
- 3+ Mistral refusal samples
- 5+ false-positive baits (in-character apologies that should NOT trigger): *"I'm sorry, did you say something?"*, *"I cannot believe how lucky I am."*, *"As an old soldier, I…"*, etc.

The corpus grows during §5.4.d smoke based on what real models actually emit. Each fixture is a single-field expected-pass/expected-fail pair; the detector regression suite runs in `RPClientCoreTests`.

### 8.4 Graceful degradation on uncensored stacks

When the detector fires repeatedly on a known-uncensored model (Qwen3.6-Uncensored-*, Mistral-Uncensored-*, Llama-Uncensored-*), the inline tip after 3 refusals (§4.5) is *"Detector fired but you're on an uncensored model — likely a false positive. Use anyway?"* — text refined during smoke. Detection logic stays the same; only the user-facing copy adjusts based on model name detection.

This is best-effort: parse the model name from `/api/v1/model` (KoboldCPP) and check for substring `uncensored` / `abliterated` / `dolphin` / `noromaid` / `airoboros`. If matched, the refusal-detection tip leans toward false-positive; otherwise, it leans toward server-switch advice.

---

## 9. Open questions

Items that couldn't be settled with empirical or literature evidence in this research pass; settled by §5.4 smoke once §5.4.a is in flight:

1. **Gemma 3 + json_schema strict mode reliability.** Probe-able only when a Gemma server is available. If Gemma silently produces non-compliant output under strict mode, Mode 2 falls back to sequential per-field on Gemma; document and ship.
2. **Mode 3 Body-pass coherence.** Probe 11 covered Persona+Voice. The Body+Intimacy pass involves 7+ fields with strong coupling (build/anatomy/markings/sensitivities/scent all reference each other). json_schema may or may not maintain coherence at that field count; smoke during §5.4.c.
3. **Alternate-greetings tone variation.** §4.8's Voice pass includes alternate greetings with different style hints (default / "tense" / "playful"). Whether passing style hints inside a single json_schema produces three meaningfully different greetings, or three near-duplicates, depends on the model's instruction-following at array level. Smoke during §5.4.c.
4. **Token-cap ceiling under json_schema.** OpenAI-compat endpoints honor `max_tokens` but may interact unpredictably with json_schema `maxLength` constraints — if `max_tokens` cuts off mid-string, does the parser recover or throw? Probe during §5.4.b.
5. **Cross-pass KV-cache reuse measurement.** Probe 10 measured intra-strip reuse at modest prefix size. Cross-pass reuse on a 2-3k-token prefix wasn't measured — the savings are extrapolated. Worth a one-shot measurement during §5.4.c smoke to confirm the latency budget.
6. **Long-form `{{user}}` substitution.** Probe outputs preserved `{{user}}` and `{{char}}` placeholders, but only in short fields. Whether a 600-char description maintains the `{{user}}` convention without leaking the model's invented user-name remains to verify; smoke during §5.4.b.

---

## 10. Recommendations summary

| Topic | Direction | Why | Fallback if wrong |
|---|---|---|---|
| Mode 1 transport | Free-form prose via `/api/v1/generate` + empty `<think></think>` pre-fill | Probe 1 + 4: thinking trap is real on text-completion path; pre-fill suppresses cleanly. Single field, no schema benefit. | Switch to chat-completions if pre-fill ever stops working on a future Kobold release. |
| Mode 2 transport | Single-call `response_format: json_schema` strict mode via `/v1/chat/completions` | Probe 8 + 11: 5 prose fields in 4.8s with coherence and strict shape. No thinking pre-fill needed on this endpoint. | Sequential per-field if a server returns non-compliant JSON; capability-probed at first use, cached. |
| Mode 3 transport | Per-pass json_schema, sequential across passes | §3.5 latency math + §1's coherence findings. 25-35s total against measured stack. | Drop a pass to sequential per-field if json_schema returns garbage; per-pass independence makes this safe. |
| Structured shape | json_schema (OpenAI-style) | Probe 3/9/11 confirm reliability; works without thinking pre-fill on chat endpoint. | GBNF if a server only supports `/api/extra/generate` (Probe 5 didn't validate but fixture is small). |
| Few-shot exemplars | 3 archetypes (Mira / monstergirl / sci-fi) selected by tag-overlap | §1 community precedent + §4 tag-anchoring rationale. Single anchor outperforms list. | Fall back to Mira if no archetype scores positive. |
| NSFW posture | Existing "explicit when scene calls for it" license; no jailbreak escalation | §5 community canonical; Probe 11 confirms model produces NSFW under json_schema with this license. | Server switch via per-window picker if a chosen model still refuses. |
| Diff/review | Per-field accept toggle (Mode 2) + diff sheet with lock + history (Mode 3) | §6.2 Inktomi93 precedent + the multi-field shape problem. | Reduce to global Accept/Reject if per-field state machine proves too complex during §5.4.b/c smoke. |
| Concurrency | Sequential always; no parallel | §3.6: local servers serialise anyway, parallel kills cache reuse. | N/A — there's no parallel win to recover. |
| KV-cache strategy | Byte-deterministic prompt builder, prefix-stable layout | §3.1-§3.2; Probe 6/10 confirm reuse works. | None needed; reuse is a perf win, not correctness. |
| Refusal detection | Existing regex + model-family extensions + uncensored-model softening | §8.1-§8.4. False-positive cost is one click. | Drop length-ratio heuristic if it fires too often on terse fields. |
| Cancellation | URLSession task cancel; client discards in-flight + queued | §7.5 matches existing RPClient pattern. | None — this is the platform default. |
| Anthropic prompt caching | Document for future; not §5.4 work | §7.2 not applicable to local stack. | N/A. |
| GBNF grammar | Dropped | Probe 5 didn't validate; json_schema covers it. | If a future server requires it, grow `CardFieldGenerator` interface. |

---

## 11. Implementation notes for §5.4.a

These are concrete contracts the research output settles, to keep §5.4.a focused on plumbing:

**`Resources/CardGenPrompts.json`** — promoted from §5.4.a deliverable to research output; lands in §5.4.a's first commit. Schema:

```json
{
  "version": 1,
  "fields": {
    "description": {
      "candidates": {
        "literal":  {"temperature": 0.5, "maxTokens": 512, "instruction": "..."},
        "creative": {"temperature": 0.85, "maxTokens": 512, "instruction": "..."},
        "terse":    {"temperature": 0.4, "maxTokens": 200, "instruction": "..."}
      },
      "upstreams": ["name", "tags"]
    },
    "personality": { ... },
    ...
  },
  "passes": {
    "identity":       {"fields": ["name","nickname","age","pronouns","species","orientation"]},
    "persona_voice":  {"fields": ["description","personality","scenario","first_message","mes_example","alternate_greetings"]},
    "body_intimacy":  {"fields": ["details_appearance","details_mood","intimacy_build","intimacy_anatomy","intimacy_markings","intimacy_sensitivities","intimacy_scent"]},
    "disposition":    {"fields": ["intimacy_turn_ons","intimacy_kinks"]},
    "system":         {"fields": ["system_prompt","post_history_instructions"]},
    "notes":          {"fields": ["creator_notes","depth_prompt"]}
  },
  "exemplars": ["mira","monstergirl","modern"],
  "refusal_patterns": [...]
}
```

The schema lives in code (loaded at app start, validated against a Codable type). Bundled JSON is read-only; future user override deferred to V2_UI_OVERHAUL.

**`Sources/RPClientCore/UI/CardCreator/CardGenExemplars.swift`** — new file. Three full-character archetypes, each with every §4.4-graph field populated. Tag-overlap selector function. ~300 lines.

**`Sources/RPClientCore/AI/CardFieldGenerator.swift`** — new file. Owns:
- Prompt builder (byte-deterministic, layout per §3.2).
- Side-call dispatch via `template.assemble` (active chat's template) for Mode 1; via direct `/v1/chat/completions` POST for Mode 2/3.
- Candidate parser + refusal detector (§8.3 regex set).
- Diagnostic logging (`cardgen:` prefix per §4.6).
- Server-capability probe + cache (`response_format: json_schema` support per session).

Mode-specific orchestrators (`CardMultiFieldGenerator` for Mode 2, `CardAutopilotOrchestrator` for Mode 3) compose `CardFieldGenerator` rather than subclassing — the research output is one shared backend, three UX surfaces.

**Tests (`RPClientCoreTests`)** — written first per the TDD posture in `feedback_tdd_workflow`:

- Prompt-builder determinism (same inputs → byte-identical output).
- Exemplar selection correctness (tag overlap → expected archetype).
- Refusal-detector regression suite with the bundled fixtures.
- Stub `KoboldGenerating` returning canned candidates → verify strip state machine end-to-end.
- json_schema response parsing (valid + truncated + non-compliant).

Smoke against a real NSFW server (the user's measured stack) is the §5.4.d signoff.

---

## 12. References

**Internal:**
- [`V2_PHASE9_CARD_CREATOR.md`](V2_PHASE9_CARD_CREATOR.md) §4 (three modes) and §5.4 (sub-step staging).
- [`V2_DESIGN_LANGUAGE.md`](V2_DESIGN_LANGUAGE.md) §11 (Linear / Vercel / Notion borrows).
- [`Sources/RPClientCore/UI/CardCreator/CardCreatorPlaceholders.swift`](Sources/RPClientCore/UI/CardCreator/CardCreatorPlaceholders.swift) — bundled exemplar set.
- [`Sources/RPClientCore/UI/CardCreator/CardStructuredDetails.swift`](Sources/RPClientCore/UI/CardCreator/CardStructuredDetails.swift) — fenced-markdown structured shape.
- [`Sources/RPClientCore/DirectorPicker.swift`](Sources/RPClientCore/DirectorPicker.swift) — existing side-call pattern with thinking pre-fill.
- [`Sources/RPClientCore/Models/Settings.swift`](Sources/RPClientCore/Models/Settings.swift) — `cardCreatorServerId` + role-server options.

**Existing card-gen tooling:**
- [Chub AI manual creator docs](https://docs.chub.ai/docs/the-basics/character-creation).
- [bmen25124/SillyTavern-Character-Creator](https://github.com/bmen25124/SillyTavern-Character-Creator).
- [ewizza/ST-CardGen](https://github.com/ewizza/ST-CardGen).
- [cha1latte/sillytavern-character-generator small-model template](https://github.com/cha1latte/sillytavern-character-generator/blob/main/character_card_creator_small.md).
- [Inktomi93/SillyTavern-CharacterTools](https://github.com/Inktomi93/SillyTavern-CharacterTools).
- [sphiratrioth666 character-generation templates (HuggingFace)](https://huggingface.co/sphiratrioth666/Character_Generation_Templates).
- [Character Card v2 spec — malfoyslastname](https://github.com/malfoyslastname/character-card-spec-v2).

**Structured output / inference:**
- [KoboldCPP wiki — Context Shifting, FastForwarding, grammar sampling](https://github.com/LostRuins/koboldcpp/wiki).
- [KoboldCPP grammar perf hit (issue #810)](https://github.com/LostRuins/koboldcpp/issues/810).
- [llama.cpp KV cache reuse (discussion #14556)](https://github.com/ggml-org/llama.cpp/discussions/14556).
- [llama.cpp host-memory prompt caching tutorial](https://github.com/ggml-org/llama.cpp/discussions/20574).
- [Qwen3 + structured-output bug — vLLM #18819](https://github.com/vllm-project/vllm/issues/18819).
- [Qwen3 + sglang grammar bug — sglang #6675](https://github.com/sgl-project/sglang/issues/6675).
- [Alibaba — enforce structured JSON with Qwen models](https://www.alibabacloud.com/help/en/model-studio/qwen-structured-output).
- [OpenAI Structured Outputs introduction](https://openai.com/index/introducing-structured-outputs-in-the-api/).
- [Outlines (dottxt-ai) structured outputs library](https://github.com/dottxt-ai/outlines).

**UX precedent:**
- [Notion AI — Accept / Try again / Discard](https://www.notion.com/help/notion-ai-faqs).
- [GitHub Copilot code-suggestion docs](https://docs.github.com/copilot/using-github-copilot/getting-code-suggestions-in-your-ide-with-github-copilot).
- [Cursor diff/accept/reject UX (forum)](https://forum.cursor.com/t/how-to-disable-diff-inline-change-approval-step/14611).

**Refusal-detection literature:**
- [Tilman Kerl — Evaluation of Sparse Autoencoder-based Refusal Features in LLMs (2025)](https://repositum.tuwien.at/bitstream/20.500.12708/220332/1/Kerl%20Tilman%20-%202025%20-%20Evaluation%20of%20Sparse%20Autoencoder-based%20Refusal%20Features%20in...pdf).
- [LLMs Encode Harmfulness and Refusal Separately (arXiv 2507.11878)](https://arxiv.org/html/2507.11878v1).
- [Tracing the Dynamics of Refusal — jailbreak-detection trajectories](https://arxiv.org/html/2605.02958).

**Anthropic backend (forward-note only):**
- [Anthropic prompt caching docs](https://platform.claude.com/docs/en/build-with-claude/prompt-caching).

**Empirical probes (this research pass):**
All against `http://192.168.1.201:5001`, KoboldCPP v1.111.2 hosting Qwen3.6-35B-A3B-Uncensored-HauhauCS-Aggressive-Q4_K_M, 16k ctx, 2026-05-07.

- Probe 1 (free-form prose, with pre-fill): ✅ ~1s per 50-word field, in-character NSFW output.
- Probe 2 (free-form JSON, with pre-fill): ✅ valid JSON, parseable.
- Probe 3 (json_schema strict, single-field): ✅ 0.8s, schema-compliant.
- Probe 4 (free-form prose, **without** pre-fill): ❌ thinking trap — 1060 chars of meditation, no output produced.
- Probe 5 (GBNF grammar via /api/extra/generate): ❌ 404; not viable on this build.
- Probe 6/10 (KV-cache reuse, sequential calls): ✅ warm calls 0.80-0.99s vs cold ~0.95s; reuse working.
- Probe 7 (refusal shape on uncensored model): ✅ no refusal even on weapon-making; false-negative risk low.
- Probe 8 (json_schema multi-field prose, 3 fields): ✅ 4.0s, 600-char description + 300 personality + 315 scenario, coherent.
- Probe 9 (json_schema **without** pre-fill on chat-completions): ✅ 0.89s; chat-completions handles thinking internally.
- Probe 11 (json_schema 5-field Persona+Voice pass): ✅ 4.82s, 348 completion tokens, all 5 fields schema-compliant and in-character with `{{user}}`/`{{char}}` preserved.
