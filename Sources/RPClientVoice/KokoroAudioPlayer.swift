import AVFoundation
import Foundation

public enum KokoroAudioPlayerError: Error {
    case formatInvalid
    case bufferAllocationFailed
    case engineStartFailed(String)
}

/// Thin `AVAudioEngine` + `AVAudioPlayerNode` wrapper that plays float32 PCM
/// produced by `KokoroEngine` through the system default output device.
/// Phase 6 §7.1k4. Multiple `play(samples:)` calls queue up on the same
/// player node so callers can stream contiguous segments without gaps.
///
/// The engine is started lazily on first `play(_:)` so the audio device
/// isn't grabbed at init time. `stop()` halts playback and resets the
/// engine, matching the §7.1k4 plan note.
public final class KokoroAudioPlayer {
    private let engine: AVAudioEngine
    private let player: AVAudioPlayerNode
    private let format: AVAudioFormat

    public init(sampleRate: Double = Double(KokoroEngine.sampleRate)) throws {
        guard let fmt = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: sampleRate,
            channels: 1,
            interleaved: false
        ) else {
            throw KokoroAudioPlayerError.formatInvalid
        }
        self.engine = AVAudioEngine()
        self.player = AVAudioPlayerNode()
        self.format = fmt
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: fmt)
    }

    /// Schedule `samples` on the player. Starts the engine on first call.
    /// `completion`, if non-nil, fires on a background AV thread when the
    /// buffer finishes playing — use a serial queue or sync primitive on
    /// the receiving end.
    public func play(samples: [Float], completion: (() -> Void)? = nil) throws {
        if !engine.isRunning {
            do {
                try engine.start()
            } catch {
                throw KokoroAudioPlayerError.engineStartFailed(String(describing: error))
            }
        }
        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: AVAudioFrameCount(samples.count)
        ) else {
            throw KokoroAudioPlayerError.bufferAllocationFailed
        }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        if let dst = buffer.floatChannelData?[0] {
            samples.withUnsafeBufferPointer { src in
                dst.update(from: src.baseAddress!, count: samples.count)
            }
        }
        player.scheduleBuffer(buffer, completionHandler: completion)
        if !player.isPlaying {
            player.play()
        }
    }

    /// Cancel any in-flight playback immediately and reset engine state.
    public func stop() {
        player.stop()
        engine.reset()
    }
}
