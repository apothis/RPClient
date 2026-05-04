# Templates: Gemma vs. Qwen3

A prompt template is the wrapper RPClient builds around your chat history before sending it to the model. Different model families expect different role markers and stop sequences — the wrong template means empty replies, echoed prompts, or garbled output.

RPClient ships two templates, **Gemma** and **Qwen3**, both implementing [PromptTemplate](Sources/RPClientCore/Templates.swift).

## When to pick which

Match the template to whatever model KoboldCpp has loaded.

| Model | Template |
|---|---|
| Gemma 2 / Gemma 3 of any size | **Gemma** |
| Qwen 2.5 / Qwen 3 of any size | **Qwen3** |
| Anything else | Try **Gemma** first; if replies are empty, try **Qwen3**. |

The sidebar shows a small template badge under each chat title. **Red badge** means the chat's template doesn't match the model RPClient detected from the server. Hover for the detected mismatch. Switch templates from the chat header (per-chat) or in `Settings… → Default template` (global default for new chats).

When you create a new chat, RPClient guesses the template from the model name reported by the server, via [Templates.detect](Sources/RPClientCore/Templates.swift) — substring match on `"qwen"` / `"gemma"`. Falls back to the global default if neither matches.

## What the templates differ on

### Gemma

- **No system role.** Gemma's chat template doesn't have `<|im_start|>system`-style scaffolding. RPClient folds memory and rolling summary into the **first user turn** instead.
- **Place markers.** `<start_of_turn>user`, `<start_of_turn>model`, `<end_of_turn>`.
- **Stop sequences.** `<end_of_turn>` and the model's name token.

Implementation: [GemmaTemplate.swift](Sources/RPClientCore/GemmaTemplate.swift).

### Qwen3

- **System role.** ChatML format with `<|im_start|>system`, `<|im_start|>user`, `<|im_start|>assistant`. Memory and summary go in the system role.
- **Optional thinking-block passthrough.** Qwen3 can produce `<think>…</think>` reasoning before its actual reply. Toggle via `Settings… → Qwen 3: enable thinking mode`.
  - **On** — the bare `<|im_start|>assistant\n` marker is sent and the model produces its own thinking trace. RPClient strips `<think>…</think>` from the reply text *before* it lands in `turn.text`, so retrieval, summary, and the chunker never see the trace. Tokens stream live, and the reply view collapses the thinking block in the UI.
  - **Off** — RPClient pre-fills `<think></think>` to suppress thinking entirely. Faster, simpler.

Implementation: [QwenTemplate.swift](Sources/RPClientCore/QwenTemplate.swift).

## Symptoms of the wrong template

- **Empty replies.** Most common — the model never produces anything because the markers it expects aren't present, or the stop sequence fires immediately. Switch templates and regenerate.
- **The model echoes your prompt.** It doesn't recognise the user/assistant turn boundaries, so it just continues the text. Switch templates.
- **Replies cut off mid-sentence.** The wrong stop sequence is firing. Switch templates; check the **Max length** in your sampler preset.
- **`<think>` tags appearing in replies.** Qwen3 thinking mode is on but you're using a non-Qwen3 model, or the trace stripper missed an unusual variant. Toggle thinking off in Settings.

## Mismatched template + memory contract

Because Gemma folds memory into the first user turn, switching a long chat from Qwen3 to Gemma mid-conversation moves where the memory block lives in the prompt. Cache reuse drops to zero on that transition (you'll feel one slow turn) and then settles back into the new layout. Same the other way. This is expected — there's nothing to fix; the next turn after the switch is the cost of the migration.

## Worked example: importing a chat from a different model family

You have an old chat that used Gemma, you've now loaded a Qwen3 model on the server, and replies are coming back empty.

1. Sidebar — note the chat's template badge is red.
2. Chat header → template picker → **Qwen3**.
3. Click **Regenerate** on the latest assistant turn (or just send a new user message).
4. The next reply uses the new template. The chat history is unchanged; only the wrapper around it shifted.

If your full library is now on a different model family, also change `Settings… → Default template` so future new chats start out matched.
