# Voice subsystem

Phase 6 added text-to-speech via Kokoro 82M (ONNX). The implementation is split across two SwiftPM targets so the ONNX Runtime dependency stays out of `RPClientCore` and `RPClientCoreTests`:

- **`RPClientCore/Voice/`** — pure-Foundation pieces: storage, download manager, tokenizer, espeak client, voice catalogue. Testable without ONNX.
- **`RPClientVoice/`** — ONNX-dependent pieces: `KokoroEngine` (session + inference), `KokoroAudioPlayer` (AVAudioEngine), `KokoroSpeechSynthesizer` (the adapter implementing the `SpeechSynthesizing` protocol that `Speaker` consumes).

The split is enforced at the package level. `RPClientCore` cannot import `RPClientVoice`; `RPClientVoice` depends on the `onnxruntime-swift-package-manager` binary. Tests link only `RPClientCore`, which keeps the test runner free of the ~50 MB ONNX native library.

## Pipeline

End-to-end, top to bottom:

```
assistant turn (UTF-8 string)
       │
       ▼  Speaker.plainText        ← markdown + <think> strip
sanitised text
       │
       ▼  EspeakNgClient            ← subprocess: espeak-ng -q --ipa=3 -v <lang>
IPA string
       │
       ▼  KokoroTokenChunker        ← splits long input into model-fitting chunks
[chunks of IPA]
       │
       ▼  KokoroTokenizer           ← IPA → [Int64] token ids (114-entry vocab)
[Int64] (pad-wrapped)
       │
       ▼  KokoroEngine.synthesize   ← ONNX session: tokens + style + speed → audio
[Float] PCM samples (24 kHz)
       │
       ▼  KokoroAudioPlayer.play    ← AVAudioEngine playback
audible output
```

The chunker is load-bearing for long replies — `KokoroEngine` accepts up to 510 input tokens (one less than the model's 511-token cap, accounting for pad wrapping). Longer replies are split on sentence boundaries; the player concatenates the audio buffers into one continuous stream.

## Two-tier toggle

`Settings.voiceEnabled` and `Settings.voiceActive` both gate synthesis. `Speaker.shouldSpeak` is `voiceEnabled && voiceActive`. Both flips post `AppNotification` events:

- `voiceEnabledChanged` — Subsystem toggle (Settings sheet). Stops any in-flight speech and posts.
- `voiceActiveChanged` — Runtime toggle (chat-header speaker button). Stops any in-flight speech and posts.

`Speaker.startObserving` subscribes to both plus `settingsChanged` so it re-mirrors flags whenever Settings reloads. The two flags are stored as `var` on Speaker so observers don't have to round-trip through `Settings` on every notification.

The runtime toggle is intentionally cheap — it does not unload the engine. The subsystem toggle is the heavyweight switch (no engine instance lives if it's off).

## Voice catalogue

[KokoroVoiceCatalogue.swift](Sources/RPClientCore/Voice/KokoroVoiceCatalogue.swift). Pure-data: 54 voices across 9 languages (en-US, en-GB, es, fr, it, pt-BR, ja, zh, hi), each with id, language, and gender. Catalogue is hard-coded (no live HuggingFace fetch); the canonical list is committed to source so an air-gapped install still has the catalogue.

`modelDownloadURL`, `modelByteSize` (325532387), and `voiceByteSizeApprox` (523425) are static constants. SHA-256 checksums for the base model and each voice live alongside.

## Storage

[KokoroStoragePaths.swift](Sources/RPClientCore/Voice/KokoroStoragePaths.swift) derives all paths from a single root URL (`Settings.voiceModelPath`). The layout:

```
<voiceModelPath>/
├── kokoro-v1.0.onnx           ← base model
├── manifest.json              ← installed-voice tracking
└── voices/
    └── <voice-id>.pt          ← per-voice style tensor (PyTorch)
```

[VoiceStorageScout.swift](Sources/RPClientCore/Voice/VoiceStorageScout.swift) enumerates likely candidate roots (Application Support, external volumes with enough free space, the user's `~/Documents`). [VoiceStoragePrompt.swift](Sources/RPClientCore/Voice/VoiceStoragePrompt.swift) is the pure trigger predicate that decides whether to fire the first-run prompt sheet (`voiceEnabled` flipped false→true AND `voiceModelPath` is nil).

[KokoroModelStore.swift](Sources/RPClientCore/Voice/KokoroModelStore.swift) is the read/write API over the storage layout: `baseModelState()`, `voiceState(id:)`, `recordModelDownloaded`, `recordVoiceDownloaded`, `removeVoice(id:)`. Plus a manifest reader/writer that persists "what's installed" separately from the disk state so a partial download doesn't show as installed.

## Download manager

[KokoroDownloadManager.swift](Sources/RPClientCore/Voice/KokoroDownloadManager.swift). `NSObject` singleton implementing `URLSessionDownloadDelegate`. Concurrency cap of 2 in-flight tasks; the rest queue. State transitions post `AppNotification.kokoroDownloadStateChanged` with the task id in `userInfo`.

On `didFinishDownloadingTo`:

1. Streamed SHA-256 of the temp file via [Sha256.swift](Sources/RPClientCore/Voice/Sha256.swift) (CryptoKit, 256 KB chunks).
2. Compare against the canonical hash from `KokoroVoiceCatalogue`.
3. If matching: atomic move to destination, then `KokoroModelStore.recordModelDownloaded` / `recordVoiceDownloaded`.
4. If mismatching: discard the temp file, mark task `.failed`, post the notification.

Cancellation is `URLSession`-native; the temp file is cleaned up by the framework.

## Engine

[KokoroEngine.swift](Sources/RPClientVoice/KokoroEngine.swift). Wraps `ORTSession` over the legacy Kokoro export (input names `tokens / style / speed`, output `audio`). The "legacy export" choice was forced: `KokoroProbe` ran against the bundled `model.onnx` and reported the legacy schema. The newer `input_ids` export uses different dtypes (notably `int32` for `speed`); the bindings don't expose schema element types, so probing is the only way to tell them apart.

Inference shape:

- `tokens: int64[1, N]` — already pad-wrapped by `KokoroTokenizer.tokenize(ipa:)`.
- `style: float32[1, 256]` — slice from the 510×1×256 voice tensor at `unpaddedTokens.count - 2` (i.e. `paddedTokens.count - 2`). The "minus two" is load-bearing: the tokenizer wraps with leading + trailing pad, so the index pre-pad is the unpadded length. An off-by-one here produces audio that's "garbled but plausible" — hard to debug.
- `speed: float32[1]` — playback speed multiplier (1.0 default).

Output is a 1D `[Float]` PCM buffer at 24 kHz mono.

## Tokenizer

[KokoroTokenizer.swift](Sources/RPClientCore/Voice/KokoroTokenizer.swift). Pins the canonical 114-entry IPA-to-id vocab from the Kokoro HuggingFace config as a `[String: Int64]` literal. `tokenize(ipa:) -> [Int64]` NFD-normalises, **iterates Unicode scalars (not Characters)**, looks each up, drops unknowns, wraps with leading + trailing pad (id 0).

Scalar iteration is load-bearing. Espeak emits diphthongs like `o‍ʊ` joined by U+200D ZWJ. Swift's default `for ch in string` iterates extended grapheme clusters — `o‍ʊ` reads as one `Character`, the vocab has no entry for the combined cluster, so cluster-iteration silently drops both components and breaks inference. The TDD case for this caught a real bug; don't change it back.

## Speaker

[Speaker.swift](Sources/RPClientCore/Voice/Speaker.swift). The `SpeechSynthesizing` protocol has two methods (`speak(_:)`, `stopSpeaking()`); `Speaker` owns the active synthesizer and routes lifecycle events. Two adapters implement it:

- `AVSpeechSynthesizerAdapter` — fallback when Kokoro isn't available (no espeak-ng, no model downloaded, etc.). Uses Apple's built-in TTS.
- `KokoroSpeechSynthesizer` ([RPClientVoice/KokoroSpeechSynthesizer.swift](Sources/RPClientVoice/KokoroSpeechSynthesizer.swift)) — Kokoro path.

[KokoroSpeechSelector.swift](Sources/RPClientCore/Voice/KokoroSpeechSelector.swift) is the pure decision function picking which adapter to use given current state (espeak found, base model ready, at least one voice installed). The `Speaker` itself is unaware of which adapter is in use beyond what the protocol surfaces.

`Speaker.startObserving` subscribes to:

- `streamFinished` → `handleStreamFinished` reads the latest assistant turn, runs `plainText`, calls `speak`.
- `streamStarted` → `stopSpeaking` (interrupt previous reply when a new one starts).
- `currentChatChanged` → `stopSpeaking`.
- `voiceEnabledChanged` / `voiceActiveChanged` → re-mirror flags, stop on speaking→silent.

App-quit cleanup goes through `AppDelegate.applicationWillTerminate` calling `AppState.shared.speaker.stop()`.

## espeak-ng

External system dependency, not bundled. Detected at runtime via [EspeakNg.swift](Sources/RPClientCore/Voice/EspeakNg.swift) which probes `/opt/homebrew/bin/espeak-ng`, `/usr/local/bin/espeak-ng`, then falls back to `/usr/bin/which`. The voice library window shows a status row with the detected path or a copy-paste install hint.

[EspeakNgClient.swift](Sources/RPClientCore/Voice/EspeakNgClient.swift) is the runtime wrapper. Pipes text on stdin to `espeak-ng -q --ipa=3 -v <code>` (stdin route avoids shell-quoting issues for long passages) and captures the IPA string on stdout. Per-language voice-code mapping is unit-tested for all 9 languages.

The licence concern (espeak-ng is GPL-3) is sidestepped: subprocess invocation does not bundle GPL code into our binary.

## Engine isolation rationale

`RPClientVoice` exists as a separate target purely so the test runner stays light. ONNX Runtime ships a ~50 MB native library; linking it into `RPClientCoreTests` (which has nothing to do with voices) would slow every test build and bloat CI artifacts. The split has cost: `Speaker` and `KokoroSpeechSelector` need to take a constructor closure that mints the Kokoro adapter, because they live in `Core` and can't reference `RPClientVoice` types. That's a fair price.

## What this doesn't cover yet

Per V2_PLAN.md §7.2–§7.5:

- **Per-character voice attribution.** The current path speaks the whole turn in one voice. Phase 6 §7.2 onwards will route different speakers (parsed from the turn) through different voices via the entity store.
- **Per-character voice override.** Mapping from `Entity` to `VoiceIdentifier` (already typed) needs UI.
- **Mid-stream speaking.** Today it speaks on `streamFinished`. Streaming-while-speaking is a future polish.
