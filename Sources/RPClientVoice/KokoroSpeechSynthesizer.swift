import Foundation
import RPClientCore

public enum KokoroSpeechSynthesizerError: Error {
    case espeakUnavailable
    case voiceLoadFailed(Error)
    case engineInitFailed(Error)
    case playerInitFailed(Error)
}

/// `SpeechSynthesizing` conformance backed by Kokoro: espeak-ng → tokenize →
/// `KokoroEngine.synthesize` → `KokoroAudioPlayer.play`. Phase 6 §7.1k5.
///
/// Single-voice — wires one `(model, voice file, language)` tuple at init
/// time. Per-character voice routing in §7.4 picks which adapter to talk to
/// (or the AVKit fallback). Engine + player + style buffer are loaded eagerly
/// at init so the first `speak(_:)` doesn't pay the ~hundreds-of-ms ONNX
/// session cost on a user-visible path.
///
/// `speak(_:)` returns immediately; pipeline runs on a serial background
/// queue. A monotonic generation counter is bumped on every `speak(_:)` and
/// `stopSpeaking()`; the pipeline checks it between phases so superseded
/// or cancelled work aborts before doing more inference. The player is
/// stopped synchronously on cancel so audio cuts off instantly even if
/// inference for a follow-up utterance is still queued behind it.
public final class KokoroSpeechSynthesizer: SpeechSynthesizing {
    private let engine: KokoroEngine
    private let player: KokoroAudioPlayer
    private let style: [Float]
    private let espeak: EspeakNgClient
    private let language: KokoroLanguage

    private let queue = DispatchQueue(label: "rpclient.voice.kokoro", qos: .userInitiated)
    private let lock = NSLock()
    private var generation: UInt64 = 0

    public init(modelURL: URL, voiceFileURL: URL, language: KokoroLanguage) throws {
        guard let espeak = EspeakNgClient.resolved() else {
            throw KokoroSpeechSynthesizerError.espeakUnavailable
        }
        self.espeak = espeak
        self.language = language

        do {
            self.style = try KokoroVoiceFile.loadStyleEmbedding(from: voiceFileURL)
        } catch {
            throw KokoroSpeechSynthesizerError.voiceLoadFailed(error)
        }
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
    }

    public func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let myGen = bumpGeneration()
        // Stop any audio currently coming out of the player. Pipeline work
        // already on the queue ahead of us will be skipped by the
        // generation check below.
        player.stop()

        queue.async { [weak self] in
            guard let self else { return }
            guard self.isCurrent(myGen) else { return }

            let ipa: String
            do {
                ipa = try self.espeak.phonemize(text: trimmed, language: self.language)
            } catch {
                NSLog("KokoroSpeechSynthesizer: espeak failed: \(error)")
                return
            }
            guard self.isCurrent(myGen) else { return }

            let tokens = KokoroTokenizer.tokenize(ipa: ipa)
            guard tokens.count > 2 else { return }   // empty after tokenization
            guard self.isCurrent(myGen) else { return }

            let pcm: [Float]
            do {
                pcm = try self.engine.synthesize(tokens: tokens, style: self.style, speed: 1.0)
            } catch {
                NSLog("KokoroSpeechSynthesizer: synthesize failed: \(error)")
                return
            }
            guard self.isCurrent(myGen) else { return }

            do {
                try self.player.play(samples: pcm)
            } catch {
                NSLog("KokoroSpeechSynthesizer: play failed: \(error)")
            }
        }
    }

    public func stopSpeaking() {
        _ = bumpGeneration()
        player.stop()
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
