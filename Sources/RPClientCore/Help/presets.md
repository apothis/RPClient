# Sampler presets

A sampler preset is a bundle of generation parameters — temperature, top-p, top-k, etc. — applied to every reply on a chat. RPClient ships three starter presets and lets you build your own.

The active preset for a chat is shown in the chat header; switch from there or set a global default in `Settings… → Default sampler preset`.

## What each knob does

| Knob | Range | What it controls |
|---|---|---|
| **Temperature** | 0.1–2.0 | How "random" sampling is. Higher = more diverse, less coherent. Lower = more deterministic, more repetitive. |
| **Top-p** (nucleus) | 0.0–1.0 | Keep the smallest set of tokens whose cumulative probability ≥ p. Higher = consider more tokens. |
| **Top-k** | 1–200 | Cap the candidate set to the top-k tokens by probability. Lower = stricter. |
| **Min-p** | 0.0–1.0 | Drop any token below `min-p × top-token-probability`. Acts like a "floor." |
| **Rep-pen** | 1.0–1.3 | Penalty applied to recently-used tokens to discourage loops. 1.0 = off; 1.1 = mild; >1.15 starts feeling unnatural. |
| **Rep-pen range** | 0–4096 | How many recent tokens count toward the rep-pen window. |
| **Max length** | tokens | Per-reply token cap. The Settings → Reply token cap override (when non-zero) supersedes this for replies. |
| **Sampler order** | array | The order KoboldCpp applies the samplers. `[6, 0, 1, 3, 4, 2, 5]` is the standard "min-p first" order; rarely worth changing. |

## Shipped presets

These three live in [SamplerPreset.swift](Sources/RPClientCore/Models/SamplerPreset.swift):

| Preset | Temp | top-p | top-k | min-p | rep-pen |
|---|---|---|---|---|---|
| **Balanced** | 0.9 | 0.95 | 40 | 0.05 | 1.07 |
| **Creative** | 1.1 | 0.98 | 80 | 0.02 | 1.05 |
| **Precise** | 0.6 | 0.9 | 30 | 0.1 | 1.1 |

**Balanced** is a sensible default for most roleplay. **Creative** loosens the constraints so the model surprises you more often (good for free-flowing scenes; sometimes drifts off-character). **Precise** tightens everything for tasks where you want the model to stay close to its strongest tokens (factual recall, structured replies).

## Tuning advice

The two knobs that actually matter for chat-quality day-to-day are **temperature** and **rep-pen**.

- If replies feel **flat or repetitive**, raise temperature (0.05 at a time) or lower rep-pen toward 1.05.
- If replies feel **incoherent or wandering**, lower temperature or tighten min-p.
- If the model **loops** ("they walked in. they walked in. they walked in."), raise rep-pen by 0.02–0.03 and check rep-pen range is at least 512.
- If the model stops replying mid-sentence, raise **max length**.

Resist the urge to micro-tune top-k and top-p simultaneously. One of them at a time is enough.

## Per-chat vs. global

A chat keeps a snapshot of the preset *id*, not the preset values. Editing the preset in Settings changes it for every chat using that id. If you want a one-off tweak that doesn't ripple, save the preset under a new name and assign it to the one chat.

## Worked example: "make replies less wordy"

The model is monologuing — replies are running 300+ words and you want shorter exchanges.

1. **Settings… → Reply token cap.** Set to `120`. This caps every reply at 120 tokens regardless of preset.
2. If replies still feel verbose within that budget, switch to **Precise** (lower temperature) so the model commits to its strongest direction faster.
3. If neither helps, the issue is probably the [author's note](memory-authors-note) — the model is matching whatever the recent assistant turns look like. Add `Keep replies under 80 words. Short sentences.` at depth 0.

The cap is a hard ceiling; the author's note is a soft preference; the preset is the underlying generation profile. Use them in that order.
