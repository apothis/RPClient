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
        let speaker = Speaker(voiceEnabled: false, synthesizer: fake)
        speaker.speak("Hello")
        try expectEqual(fake.spoken, [])
        try expectEqual(fake.stopCount, 0)
    }

    s.test("speak() forwards stripped text when voiceEnabled is true") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, synthesizer: fake)
        speaker.speak("<think>x</think>**Hi.**")
        try expectEqual(fake.spoken, ["Hi."])
    }

    s.test("setVoiceEnabled(false) stops in-flight speech") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, synthesizer: fake)
        speaker.speak("Hello")
        try expectEqual(fake.stopCount, 0)
        speaker.setVoiceEnabled(false)
        try expectEqual(fake.stopCount, 1)
    }

    s.test("stop() forwards to the synthesizer regardless of voiceEnabled") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, synthesizer: fake)
        speaker.stop()
        try expectEqual(fake.stopCount, 1)
    }

    s.test("speak() is a no-op on whitespace-only text after stripping") {
        let fake = RecordingSynthesizer()
        let speaker = Speaker(voiceEnabled: true, synthesizer: fake)
        speaker.speak("<think>only thinking</think>")
        try expectEqual(fake.spoken, [])
    }

    return s
}

private final class RecordingSynthesizer: SpeechSynthesizing {
    var spoken: [String] = []
    var stopCount = 0
    func speak(_ text: String) { spoken.append(text) }
    func stopSpeaking() { stopCount += 1 }
}
