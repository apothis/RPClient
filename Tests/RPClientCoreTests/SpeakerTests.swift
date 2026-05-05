import Foundation
@testable import RPClientCore

/// Tests for `Speaker` — single-voice TTS pipeline driven by the
/// `voiceEnabled` setting. Covers:
///   - `Speaker.plainText(_:)` text-prep (pure string in → pure string out).
///   - The on/off gating decision via a recording fake of `SpeechSynthesizing`.
///
/// The `AVSpeechSynthesizer` glue itself is not unit-tested here — that's
/// covered by the manual smoke test (./run.sh, toggle the checkbox, listen).
func speakerTests() -> TestSuite {
    let s = TestSuite("Speaker")

    // MARK: - plainText

    s.test("plainText strips <think> blocks") {
        let input = "<think>secret reasoning</think>Hello there."
        try expectEqual(Speaker.plainText(input), "Hello there.")
    }

    s.test("plainText strips emphasis, inline code, and links") {
        let input = "She said **hello** and *waved* with `code` and a [link](https://example.com)."
        try expectEqual(
            Speaker.plainText(input),
            "She said hello and waved with code and a link."
        )
    }

    s.test("plainText strips list markers and headings") {
        let input = "## Greeting\n- one\n- two\n* three\n1. four"
        try expectEqual(
            Speaker.plainText(input),
            "Greeting\none\ntwo\nthree\nfour"
        )
    }

    s.test("plainText replaces fenced code blocks with a language label") {
        let input = "Look at this:\n```swift\nlet x = 1\n```\nDone."
        try expectEqual(
            Speaker.plainText(input),
            "Look at this:\nswift code block\nDone."
        )
    }

    s.test("plainText replaces unlabeled fenced code blocks with a generic label") {
        let input = "Try:\n```\nplain code\n```"
        try expectEqual(Speaker.plainText(input), "Try:\ncode block")
    }

    // MARK: - gating

    s.test("speak() is a no-op when voiceEnabled is false") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: false, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.spoken, [])
        try expectEqual(fake.stopCount, 0)
    }

    s.test("speak() forwards stripped text when voiceEnabled is true") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: fake)
        speaker.speak("<think>x</think>**Hi.**")
        try expectEqual(fake.spoken.map(\.text), ["Hi."])
    }

    s.test("setVoiceEnabled(false) stops in-flight speech") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.stopCount, 0)
        speaker.setVoiceEnabled(false)
        try expectEqual(fake.stopCount, 1)
    }

    s.test("stop() forwards to the synthesizer regardless of voiceEnabled") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: fake)
        speaker.stop()
        try expectEqual(fake.stopCount, 1)
    }

    s.test("speak() is a no-op on whitespace-only text after stripping") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: fake)
        speaker.speak("<think>only thinking</think>")
        try expectEqual(fake.spoken, [])
    }

    // MARK: - two-tier gating (Phase 6 §7.1f)

    s.test("speak() is a no-op when subsystem on but runtime active false") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, voiceActive: false, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.spoken, [])
    }

    s.test("speak() is a no-op when subsystem off even if runtime active true") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: false, voiceActive: true, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.spoken, [])
    }

    s.test("speak() forwards when both subsystem and active are true") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, voiceActive: true, avkit: fake)
        speaker.speak("Hi.")
        try expectEqual(fake.spoken.map(\.text), ["Hi."])
    }

    s.test("speak() is a no-op when both subsystem and active are false") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: false, voiceActive: false, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.spoken, [])
    }

    s.test("setVoiceActive(false) stops in-flight speech when subsystem is on") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, voiceActive: true, avkit: fake)
        speaker.speak("Hello")
        try expectEqual(fake.stopCount, 0)
        speaker.setVoiceActive(false)
        try expectEqual(fake.stopCount, 1)
    }

    s.test("setVoiceActive(true) does not call stop") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, voiceActive: false, avkit: fake)
        speaker.setVoiceActive(true)
        try expectEqual(fake.stopCount, 0)
    }

    s.test("voiceActiveChanged notification name exists") {
        try expectEqual(
            AppNotification.voiceActiveChanged.rawValue,
            "RPClient.voiceActiveChanged"
        )
    }

    s.test("legacy Speaker init defaults voiceActive to true") {
        // The single-arg init must keep working (tests + AppState wiring)
        // and behave as if voiceActive is true so existing callers don't
        // suddenly go silent.
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: fake)
        speaker.speak("Hi.")
        try expectEqual(fake.spoken.map(\.text), ["Hi."])
    }

    // MARK: - per-call voice dispatch (Phase 6 §7.4a)

    s.test("speak() with nil voice prefers Kokoro when installed") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        speaker.speak("Hi.", options: .default)
        try expectEqual(kokoro.spoken.map(\.text), ["Hi."])
        try expectEqual(avkit.spoken.map(\.text), [])
    }

    s.test("speak() with nil voice falls back to AVKit when Kokoro not installed") {
        let avkit = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: nil)
        speaker.speak("Hi.", options: .default)
        try expectEqual(avkit.spoken.map(\.text), ["Hi."])
    }

    s.test("speak() routes Kokoro voice to the Kokoro synth") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        let opts = SpeakOptions(
            voice: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.2,
            pitch: 1.0
        )
        speaker.speak("Hi.", options: opts)
        try expectEqual(kokoro.spoken.count, 1)
        try expectEqual(kokoro.spoken[0].options, opts)
        try expectEqual(avkit.spoken, [])
    }

    s.test("speak() routes AVKit voice to the AVKit synth even when Kokoro is installed") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        let opts = SpeakOptions(
            voice: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.compact.en-US.Samantha"),
            rate: 1.0,
            pitch: 0.9
        )
        speaker.speak("Hi.", options: opts)
        try expectEqual(avkit.spoken.count, 1)
        try expectEqual(avkit.spoken[0].options, opts)
        try expectEqual(kokoro.spoken, [])
    }

    s.test("speak() with Kokoro voice falls back to AVKit when Kokoro is not installed") {
        // The picker shouldn't have offered an unavailable voice in the
        // first place, but if a stale stored preference points at one,
        // produce *some* audio rather than silence.
        let avkit = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: nil)
        let opts = SpeakOptions(
            voice: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.0, pitch: 1.0
        )
        speaker.speak("Hi.", options: opts)
        try expectEqual(avkit.spoken.count, 1)
    }

    s.test("setKokoroSynthesizer(nil) stops in-flight Kokoro audio") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        speaker.speak("Hi.", options: .default)   // routed to Kokoro
        try expectEqual(kokoro.stopCount, 0)
        speaker.setKokoroSynthesizer(nil)
        try expectEqual(kokoro.stopCount, 1)
    }

    s.test("stop() cancels both engines") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        speaker.stop()
        try expectEqual(avkit.stopCount, 1)
        try expectEqual(kokoro.stopCount, 1)
    }

    s.test("setVoiceActive(false) stops both engines") {
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, voiceActive: true, avkit: avkit, kokoro: kokoro)
        speaker.setVoiceActive(false)
        try expectEqual(avkit.stopCount, 1)
        try expectEqual(kokoro.stopCount, 1)
    }

    // MARK: - SpeakOptions construction

    // MARK: - speakSegments queue (Phase 6 §7.4b)

    s.test("speakSegments crosses engine boundaries via per-run completion") {
        // Cross-engine: kokoro segment then avkit segment. Each engine
        // gets its own batched run, sequenced via the run-completion.
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        let kokoroVoice = SpeakOptions(
            voice: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy"),
            rate: 1.0, pitch: 1.0
        )
        let avkitVoice = SpeakOptions(
            voice: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.compact.en-US.Samantha"),
            rate: 1.0, pitch: 1.0
        )
        speaker.speakSegments([
            (text: "First.", options: kokoroVoice),
            (text: "Second.", options: avkitVoice),
        ])
        // Kokoro got its run; AVKit's run is gated on Kokoro's completion.
        try expectEqual(kokoro.spoken.map(\.text), ["First."])
        try expectEqual(avkit.spoken, [])
        // Fire the kokoro completion → AVKit run dispatches.
        let cont = try expectNotNil(kokoro.lastCompletion)
        cont()
        let deadline = Date().addingTimeInterval(0.5)
        while avkit.spoken.isEmpty && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expectEqual(avkit.spoken.map(\.text), ["Second."])
    }

    s.test("speakSegments dispatches consecutive same-engine segments to the engine in one pass") {
        // Pipelined cadence: an engine that queues utterances natively
        // (or overrides speakBatch to interleave synthesis with playback)
        // sees the whole same-engine run in one go rather than one-at-a-time.
        let avkit = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit)
        let opts = SpeakOptions(
            voice: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.compact.en-US.Samantha"),
            rate: 1.0, pitch: 1.0
        )
        speaker.speakSegments([
            (text: "First.", options: opts),
            (text: "Second.", options: opts),
            (text: "Third.", options: opts),
        ])
        try expectEqual(avkit.spoken.map(\.text), ["First.", "Second.", "Third."])
    }

    s.test("speakSegments is a no-op when both gates are off") {
        let avkit = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: false, avkit: avkit)
        speaker.speakSegments([(text: "Hi.", options: .default)])
        try expectEqual(avkit.spoken, [])
    }

    s.test("speakSegments skips empty-text segments") {
        let avkit = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit)
        speaker.speakSegments([
            (text: "", options: .default),
            (text: "Hi.", options: .default),
        ])
        try expectEqual(avkit.spoken.map(\.text), ["Hi."])
    }

    s.test("stop() between cross-engine runs prevents the next run from playing") {
        // Cross-engine sequencing is still completion-driven (same engine
        // runs are pipelined; runs across engines are gated). If stop()
        // bumps the queue generation between runs, the next run's
        // dispatch is dropped even when the previous run's completion
        // fires after stop().
        let avkit = RecordingSynthesizer()
        let kokoro = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, avkit: avkit, kokoro: kokoro)
        let kokoroVoice = SpeakOptions(
            voice: VoiceIdentifier(engine: .kokoro, voiceId: "af_alloy")
        )
        let avkitVoice = SpeakOptions(
            voice: VoiceIdentifier(engine: .avkit, voiceId: "com.apple.voice.compact.en-US.Samantha")
        )
        speaker.speakSegments([
            (text: "First.", options: kokoroVoice),
            (text: "Second.", options: avkitVoice),
        ])
        try expectEqual(kokoro.spoken.map(\.text), ["First."])
        try expectEqual(avkit.spoken, [])
        speaker.stop()
        let cont = try expectNotNil(kokoro.lastCompletion)
        cont()
        let deadline = Date().addingTimeInterval(0.2)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try expectEqual(avkit.spoken, [], "AVKit run should have been dropped after stop()")
    }

    // MARK: - Speaker.matchCharacterToEntity (Phase 6 §7.3 polish)

    s.test("matchCharacterToEntity: exact case-insensitive match wins") {
        let lina = Entity(name: "Lina", type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "lina",
            entities: [lina]
        )
        try expectEqual(id, lina.id)
    }

    s.test("matchCharacterToEntity: alias also counts") {
        let mage = Entity(name: "Sage", aliases: ["the mage"], type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "the mage",
            entities: [mage]
        )
        try expectEqual(id, mage.id)
    }

    s.test("matchCharacterToEntity: word-bounded fallback catches multi-word card names") {
        // Card 'Anna Smith' should still match an entity row named 'Anna'.
        let anna = Entity(name: "Anna", type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "Anna Smith",
            entities: [anna]
        )
        try expectEqual(id, anna.id)
    }

    s.test("matchCharacterToEntity: word-bounded fallback handles short entity vs. long card") {
        // Card 'Anna of the Wood' → entity 'Anna' should match.
        let anna = Entity(name: "Anna", type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "Anna of the Wood",
            entities: [anna]
        )
        try expectEqual(id, anna.id)
    }

    s.test("matchCharacterToEntity: prefers exact match when both exact and word-fallback apply") {
        let annaShort = Entity(name: "Anna", type: .character)
        let annaFull = Entity(name: "Anna Smith", type: .character)
        // Both could match "Anna Smith" — the exact-match pass should pick
        // the full-name entity even though the short-name entity is listed
        // first.
        let id = Speaker.matchCharacterToEntity(
            characterName: "Anna Smith",
            entities: [annaShort, annaFull]
        )
        try expectEqual(id, annaFull.id)
    }

    s.test("matchCharacterToEntity: returns nil when no entity matches") {
        let sage = Entity(name: "Sage", type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "Lina",
            entities: [sage]
        )
        try expectEqual(id, nil)
    }

    s.test("matchCharacterToEntity: empty character name returns nil") {
        let sage = Entity(name: "Sage", type: .character)
        let id = Speaker.matchCharacterToEntity(
            characterName: "   ",
            entities: [sage]
        )
        try expectEqual(id, nil)
    }

    s.test("SpeakOptions(preference: nil) is the default") {
        try expectEqual(SpeakOptions(preference: nil), SpeakOptions.default)
    }

    s.test("SpeakOptions(preference:) carries voice + rate + pitch through") {
        let pref = VoicePreference(
            voiceIdentifier: VoiceIdentifier(engine: .kokoro, voiceId: "af_bella"),
            rate: 1.3,
            pitch: 0.8
        )
        let opts = SpeakOptions(preference: pref)
        try expectEqual(opts.voice, pref.voiceIdentifier)
        try expectEqual(opts.rate, 1.3)
        try expectEqual(opts.pitch, 0.8)
    }

    return s
}

private final class RecordingSynthesizer: SpeechSynthesizing {
    struct Spoken: Equatable {
        let text: String
        let options: SpeakOptions
    }
    var spoken: [Spoken] = []
    var stopCount = 0
    /// Captured completion from the most recent speak() — tests fire it
    /// manually to simulate "this segment finished playing" so the queue
    /// advancer in Speaker can advance.
    var lastCompletion: (() -> Void)?
    func speak(_ text: String, options: SpeakOptions, completion: (() -> Void)?) {
        spoken.append(Spoken(text: text, options: options))
        lastCompletion = completion
    }
    func stopSpeaking() { stopCount += 1 }
}
