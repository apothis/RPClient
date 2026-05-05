import Foundation
import RPClientCore
import RPClientVoice

// First-light smoke for Phase 6 §7.1k3. End-to-end pipeline:
// text → espeak-ng IPA → KokoroTokenizer → KokoroEngine → float32 PCM →
// /tmp/kokoro-smoke.wav → afplay. No automated "is this speech" check;
// the only acceptance criterion is that the output sounds like the text.
//
// usage: swift run KokoroSmoke ["text" [model.onnx [voice.pt]]]

let args = CommandLine.arguments
let text = args.count >= 2 ? args[1] : "Hello, world."
let modelPath = args.count >= 3 ? args[2] : "/Volumes/SSD1/VoiceStorage/kokoro/model.onnx"
let voicePath = args.count >= 4 ? args[3] : "/Volumes/SSD1/VoiceStorage/kokoro/voices/af_alloy.pt"
let outputPath = "/tmp/kokoro-smoke.wav"

func die(_ msg: String) -> Never {
    FileHandle.standardError.write(Data("error: \(msg)\n".utf8))
    exit(1)
}

guard let espeak = EspeakNgClient.resolved() else {
    die("espeak-ng not found on PATH")
}
print("Text:    \(text)")
print("Model:   \(modelPath)")
print("Voice:   \(voicePath)")

let style: [Float]
do {
    style = try KokoroVoiceFile.loadStyleEmbedding(from: URL(fileURLWithPath: voicePath))
} catch {
    die("voice load failed: \(error)")
}
print("Style:   \(style.count) floats")

let ipa: String
do {
    ipa = try espeak.phonemize(text: text, language: .americanEnglish)
} catch {
    die("espeak failed: \(error)")
}
print("IPA:     \(ipa.trimmingCharacters(in: .whitespacesAndNewlines))")

let tokens = KokoroTokenizer.tokenize(ipa: ipa)
print("Tokens:  \(tokens.count) (incl. pad), unpadded = \(tokens.count - 2)")

let engine: KokoroEngine
do {
    engine = try KokoroEngine(modelURL: URL(fileURLWithPath: modelPath))
} catch {
    die("engine init failed: \(error)")
}

let start = Date()
let pcm: [Float]
do {
    pcm = try engine.synthesize(tokens: tokens, style: style, speed: 1.0)
} catch {
    die("synthesize failed: \(error)")
}
let elapsed = Date().timeIntervalSince(start)

let durationSec = Double(pcm.count) / Double(KokoroEngine.sampleRate)
let rms = sqrt(pcm.reduce(0.0) { $0 + Double($1 * $1) } / Double(max(pcm.count, 1)))
let peak = pcm.map { abs($0) }.max() ?? 0
print(String(format: "Audio:   %d samples = %.2fs (synth %.2fs), RMS %.4f, peak %.4f",
             pcm.count, durationSec, elapsed, rms, Double(peak)))

// Write a 32-bit float WAV (RIFF / WAVE / fmt subformat 0x0003).
func writeFloatWav(samples: [Float], sampleRate: Int, to path: String) throws {
    let dataBytes = samples.count * MemoryLayout<Float>.size
    var out = Data()
    func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { out.append(contentsOf: $0) } }
    func ascii(_ s: String) { out.append(contentsOf: s.utf8) }

    ascii("RIFF")
    u32(UInt32(36 + dataBytes))
    ascii("WAVE")
    ascii("fmt ")
    u32(16)                                 // PCM-extended chunk size
    u16(3)                                  // 0x0003 = IEEE float
    u16(1)                                  // mono
    u32(UInt32(sampleRate))
    u32(UInt32(sampleRate * 4))             // byte rate (mono float32)
    u16(4)                                  // block align
    u16(32)                                 // bits per sample
    ascii("data")
    u32(UInt32(dataBytes))
    samples.withUnsafeBufferPointer { buf in
        out.append(UnsafeBufferPointer(start: buf.baseAddress, count: buf.count).withMemoryRebound(to: UInt8.self) {
            Data(buffer: $0)
        })
    }
    try out.write(to: URL(fileURLWithPath: path))
}

do {
    try writeFloatWav(samples: pcm, sampleRate: KokoroEngine.sampleRate, to: outputPath)
} catch {
    die("write WAV failed: \(error)")
}
print("Wrote:   \(outputPath)")

// Play through KokoroAudioPlayer (k4) — the real path the chat speaker
// will use. Block until the buffer's completion handler fires so the CLI
// process doesn't exit mid-playback.
let player: KokoroAudioPlayer
do {
    player = try KokoroAudioPlayer()
} catch {
    die("audio player init failed: \(error)")
}
let done = DispatchSemaphore(value: 0)
do {
    try player.play(samples: pcm) { done.signal() }
} catch {
    die("play failed: \(error)")
}
print("Playing… (blocks until buffer completion fires)")
done.wait()
print("Done.")
