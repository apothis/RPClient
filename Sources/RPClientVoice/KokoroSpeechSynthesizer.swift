import Foundation
import RPClientCore

public enum KokoroSpeechSynthesizerError: Error {
    case espeakUnavailable
    case voiceLoadFailed(Error)
    case engineInitFailed(Error)
    case playerInitFailed(Error)
    case defaultVoiceFileMissing(String)
}

/// `SpeechSynthesizing` conformance backed by Kokoro: espeak-ng → tokenize →
/// `KokoroEngine.synthesize` → `KokoroAudioPlayer.play`. Phase 6 §7.1k5,
/// expanded for per-call voice swap in §7.4.
///
/// Engine + player + espeak are loaded eagerly at init so the first
/// `speak(_:options:)` doesn't pay the ~hundreds-of-ms ONNX session cost on a
/// user-visible path. **Voice (style buffer + language)** is resolved per
/// `speak()` call from `SpeakOptions.voice`: a missing or non-Kokoro voice
/// falls back to the default voice supplied at init. Style buffers are cached
/// in a small dict keyed by voice id; each ~510 KB load is cheap, so the
/// cache exists mainly to avoid re-reading the same `.pt` on every utterance
/// in long replies. No eviction — even loading every voice in the v1.0
/// catalogue (54 voices × ~510 KB ≈ 27 MB) is well within budget.
///
/// `speak(_:options:)` returns immediately; pipeline runs on a serial
/// background queue. A monotonic generation counter is bumped on every
/// `speak()` and `stopSpeaking()`; the pipeline checks it between phases so
/// superseded or cancelled work aborts before doing more inference. The
/// player is stopped synchronously on cancel so audio cuts off instantly
/// even if inference for a follow-up utterance is still queued behind it.
public final class KokoroSpeechSynthesizer: SpeechSynthesizing {
    /// Per-chunk unpadded token cap. The model rejects unpadded > 510
    /// (style buffer length); 500 leaves ~10 tokens of headroom for the
    /// `KokoroEngine` bound check while still maximising audio per call.
    static let maxUnpaddedPerChunk = 500

    private let engine: KokoroEngine
    private let player: KokoroAudioPlayer
    private let espeak: EspeakNgClient
    private let defaultVoice: KokoroVoice
    private let voiceFileURLProvider: (String) -> URL?

    private let queue = DispatchQueue(label: "rpclient.voice.kokoro", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var styleCache: [String: [Float]] = [:]   // protected by `lock`

    /// Multi-voice init — voice is resolved per `speak()` call from the
    /// options. The default voice is the fallback when options carry a nil
    /// or non-Kokoro identifier; its style buffer is loaded eagerly so
    /// nil-options speaks don't stutter.
    public init(
        modelURL: URL,
        defaultVoice: KokoroVoice,
        voiceFileURLProvider: @escaping (String) -> URL?
    ) throws {
        guard let espeak = EspeakNgClient.resolved() else {
            throw KokoroSpeechSynthesizerError.espeakUnavailable
        }
        self.espeak = espeak
        self.defaultVoice = defaultVoice
        self.voiceFileURLProvider = voiceFileURLProvider

        do {
            self.engine = try KokoroEngine(modelURL: modelURL)
        } catch {
            throw KokoroSpeechSynthesizerError.engineInitFailed(error)
        }
        do {
            self.player = try KokoroAudioPlayer()
        } catch {
            throw KokoroSpeechSynthesizerError.playerInitFailed(error)
        }
        // Pre-load the default voice's style buffer.
        guard let defaultURL = voiceFileURLProvider(defaultVoice.id) else {
            throw KokoroSpeechSynthesizerError.defaultVoiceFileMissing(defaultVoice.id)
        }
        do {
            let style = try KokoroVoiceFile.loadStyleEmbedding(from: defaultURL)
            styleCache[defaultVoice.id] = style
        } catch {
            throw KokoroSpeechSynthesizerError.voiceLoadFailed(error)
        }
    }

    /// Single-voice convenience — preserves the §7.1k5 init shape so
    /// `KokoroSmoke` and any non-app callers don't break. Voice id (the
    /// filename stem) must exist in `KokoroVoiceCatalogue.all`. The
    /// `language` parameter is unused now — the catalogue is the source of
    /// truth — but the argument stays so the existing call sites compile.
    public convenience init(modelURL: URL, voiceFileURL: URL, language: KokoroLanguage) throws {
        let id = voiceFileURL.deletingPathExtension().lastPathComponent
        guard let voice = KokoroVoiceCatalogue.all.first(where: { $0.id == id }) else {
            throw KokoroSpeechSynthesizerError.defaultVoiceFileMissing(
                "voice id '\(id)' not in KokoroVoiceCatalogue"
            )
        }
        _ = language   // kept for source compatibility; catalogue carries truth
        try self.init(
            modelURL: modelURL,
            defaultVoice: voice,
            voiceFileURLProvider: { _ in voiceFileURL }
        )
    }

    public func speak(_ text: String, options: SpeakOptions, completion: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Empty text shouldn't strand the queue — fire completion so the
            // caller can advance.
            if let completion = completion {
                DispatchQueue.main.async(execute: completion)
            }
            return
        }

        let myGen = bumpGeneration()
        // Stop any audio currently coming out of the player. Pipeline work
        // already on the queue ahead of us will be skipped by the
        // generation check below.
        player.stop()

        let resolvedVoice = resolveVoice(from: options.voice)
        let speed = options.rate

        // Fire-once wrapper: completion runs at exactly one of these moments
        // — (a) the last chunk's audio finishes, (b) a failure aborts the
        // pipeline (espeak / synth / play). Supersession (a newer speak()
        // call bumped the generation) deliberately does NOT fire — that
        // utterance will fire its own completion, and advancing the queue
        // past a cancelled segment would skip-ahead.
        let fireOnce = FireOnce(handler: completion)

        queue.async { [weak self] in
            guard let self else { fireOnce.fire(); return }
            guard self.isCurrent(myGen) else { return }   // superseded — silent

            // Style buffer for this voice, loaded on demand. A missing /
            // unloadable file falls back to the default voice's cached
            // style — picker shouldn't have offered an uninstalled voice,
            // but a stale stored preference shouldn't produce silence.
            let style: [Float]
            if let cached = self.cachedStyle(for: resolvedVoice.id) {
                style = cached
            } else if let url = self.voiceFileURLProvider(resolvedVoice.id),
                      let loaded = try? KokoroVoiceFile.loadStyleEmbedding(from: url) {
                self.cacheStyle(loaded, for: resolvedVoice.id)
                style = loaded
            } else if let fallback = self.cachedStyle(for: self.defaultVoice.id) {
                NSLog("KokoroSpeechSynthesizer: voice '\(resolvedVoice.id)' file missing; falling back to default '\(self.defaultVoice.id)'")
                style = fallback
            } else {
                NSLog("KokoroSpeechSynthesizer: no style available for '\(resolvedVoice.id)' or default '\(self.defaultVoice.id)'")
                fireOnce.fire()
                return
            }

            let ipa: String
            do {
                // §7.1k7: punctuation-preserving variant. Plain `phonemize`
                // strips all punctuation from the IPA, which leaves Kokoro
                // with no pause/intonation cues — speech runs together as
                // a robotic monotone.
                ipa = try self.espeak.phonemizePreservingPunctuation(
                    text: trimmed, language: resolvedVoice.language
                )
            } catch {
                NSLog("KokoroSpeechSynthesizer: espeak failed: \(error)")
                fireOnce.fire()
                return
            }
            guard self.isCurrent(myGen) else { return }

            let tokens = KokoroTokenizer.tokenize(ipa: ipa)
            guard tokens.count > 2 else { fireOnce.fire(); return }   // empty after tokenization
            guard self.isCurrent(myGen) else { return }

            let chunks = KokoroTokenChunker.chunk(tokens: tokens, maxUnpadded: Self.maxUnpaddedPerChunk)
            guard !chunks.isEmpty else { fireOnce.fire(); return }
            for (i, chunk) in chunks.enumerated() {
                guard self.isCurrent(myGen) else { return }
                let pcm: [Float]
                do {
                    pcm = try self.engine.synthesize(tokens: chunk, style: style, speed: speed)
                } catch {
                    NSLog("KokoroSpeechSynthesizer: synthesize failed: \(error)")
                    fireOnce.fire()
                    return
                }
                guard self.isCurrent(myGen) else { return }
                let isLast = (i == chunks.count - 1)
                do {
                    try self.player.play(samples: pcm) {
                        if isLast { fireOnce.fire() }
                    }
                } catch {
                    NSLog("KokoroSpeechSynthesizer: play failed: \(error)")
                    fireOnce.fire()
                    return
                }
            }
        }
    }

    public func stopSpeaking() {
        _ = bumpGeneration()
        player.stop()
    }

    // MARK: - Voice resolution

    /// Map a `VoiceIdentifier?` from options to the `KokoroVoice` we should
    /// synthesise with. AVKit identifiers and unknown Kokoro ids fall back
    /// to `defaultVoice`. The Speaker-level dispatcher should have already
    /// short-circuited AVKit voices to the AVKit adapter, so an AVKit
    /// identifier reaching here is a routing bug — we tolerate it rather
    /// than crash.
    private func resolveVoice(from voice: VoiceIdentifier?) -> KokoroVoice {
        guard let voice = voice, voice.engine == .kokoro,
              let kv = KokoroVoiceCatalogue.all.first(where: { $0.id == voice.voiceId })
        else {
            return defaultVoice
        }
        return kv
    }

    private func cachedStyle(for id: String) -> [Float]? {
        lock.lock()
        defer { lock.unlock() }
        return styleCache[id]
    }

    private func cacheStyle(_ style: [Float], for id: String) {
        lock.lock()
        defer { lock.unlock() }
        styleCache[id] = style
    }

    private func bumpGeneration() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        generation &+= 1
        return generation
    }

    private func isCurrent(_ gen: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == gen
    }
}

/// Fires a completion handler at most once. Used by `KokoroSpeechSynthesizer`
/// because the pipeline has multiple terminal paths (last chunk's playback
/// completion, several mid-pipeline failure bails) and double-firing would
/// double-advance Speaker's segment queue.
private final class FireOnce {
    private let handler: (() -> Void)?
    private var fired = false
    private let lock = NSLock()
    init(handler: (() -> Void)?) { self.handler = handler }
    func fire() {
        lock.lock()
        let shouldFire = !fired
        fired = true
        lock.unlock()
        guard shouldFire, let handler else { return }
        DispatchQueue.main.async(execute: handler)
    }
}
