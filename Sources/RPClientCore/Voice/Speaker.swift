import AVFoundation
import Foundation

/// Abstraction over the underlying TTS engine so the on/off gating in
/// `Speaker` is testable without touching AVKit, and so engine selection
/// (§7.1l) can swap between AVKit and Kokoro implementations. Production
/// wiring uses `AVSpeechSynthesizerAdapter` (this file) or
/// `KokoroSpeechSynthesizer` (RPClientVoice); tests inject a recording fake.
public protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String)
    func stopSpeaking()
}

final class AVSpeechSynthesizerAdapter: SpeechSynthesizing {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String) {
        let utterance = AVSpeechUtterance(string: text)
        synth.speak(utterance)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
    }
}

/// Single-voice TTS pipeline gated on `Settings.voiceEnabled` (subsystem) AND
/// `Settings.voiceActive` (runtime). V2_PLAN §7.0/§7.1f. Speaks just-completed
/// assistant turns through the system default voice. Per-character attribution
/// and voice picking land in §7.1–§7.4 on top of this surface.
///
/// Owned by `AppState`. Subscribes to `streamFinished`, `streamStarted`,
/// `currentChatChanged`, `settingsChanged`, and `voiceActiveChanged` so
/// callers don't need to drive it explicitly.
final class Speaker {
    private var synthesizer: SpeechSynthesizing
    private var voiceEnabled: Bool
    private var voiceActive: Bool
    private var observers: [NSObjectProtocol] = []

    private var shouldSpeak: Bool { voiceEnabled && voiceActive }

    init(voiceEnabled: Bool,
         voiceActive: Bool = true,
         synthesizer: SpeechSynthesizing = AVSpeechSynthesizerAdapter()) {
        self.synthesizer = synthesizer
        self.voiceEnabled = voiceEnabled
        self.voiceActive = voiceActive
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Speak `raw` through the synthesizer, after stripping `<think>` blocks
    /// and markdown formatting. No-op unless both the subsystem and the
    /// runtime toggle are on, or when the stripped text is empty.
    func speak(_ raw: String) {
        guard shouldSpeak else { return }
        let text = Speaker.plainText(raw)
        guard !text.isEmpty else { return }
        synthesizer.speak(text)
    }

    /// Cancel any in-flight utterance immediately.
    func stop() {
        synthesizer.stopSpeaking()
    }

    /// Replace the underlying synthesizer (e.g. swap from AVKit to Kokoro
    /// when the voice subsystem comes online, or revert when it goes off).
    /// Stops any in-flight utterance on the old synthesizer first so audio
    /// cuts cleanly. §7.1l engine selection.
    func setSynthesizer(_ new: SpeechSynthesizing) {
        synthesizer.stopSpeaking()
        synthesizer = new
    }

    /// Mirror `Settings.voiceEnabled` (the subsystem gate) into the speaker.
    /// Flipping off while speech is live stops it so the toggle feels live.
    func setVoiceEnabled(_ enabled: Bool) {
        if shouldSpeak && !enabled {
            synthesizer.stopSpeaking()
        }
        voiceEnabled = enabled
    }

    /// Mirror `Settings.voiceActive` (the runtime gate) into the speaker.
    /// Flipping off while speech is live stops it.
    func setVoiceActive(_ active: Bool) {
        if shouldSpeak && !active {
            synthesizer.stopSpeaking()
        }
        voiceActive = active
    }

    // MARK: - Notification wiring

    /// Subscribe to the stream / chat / settings notifications. Pulled out of
    /// `init` so unit tests can construct a `Speaker` without touching the
    /// shared NotificationCenter.
    func startObserving() {
        let nc = NotificationCenter.default
        let speakIfFinished = nc.addObserver(
            forName: AppNotification.streamFinished, object: nil, queue: .main
        ) { [weak self] _ in
            self?.handleStreamFinished()
        }
        let stopOnNewStream = nc.addObserver(
            forName: AppNotification.streamStarted, object: nil, queue: .main
        ) { [weak self] _ in
            self?.synthesizer.stopSpeaking()
        }
        let stopOnChatSwitch = nc.addObserver(
            forName: AppNotification.currentChatChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.synthesizer.stopSpeaking()
        }
        let trackSettings = nc.addObserver(
            forName: AppNotification.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in
            let s = AppState.shared.settings
            self?.setVoiceEnabled(s.voiceEnabled)
            self?.setVoiceActive(s.voiceActive)
        }
        let trackActive = nc.addObserver(
            forName: AppNotification.voiceActiveChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.setVoiceActive(AppState.shared.settings.voiceActive)
        }
        observers = [speakIfFinished, stopOnNewStream, stopOnChatSwitch, trackSettings, trackActive]
    }

    private func handleStreamFinished() {
        guard shouldSpeak else { return }
        guard let last = AppState.shared.currentChat?.turns.last,
              last.role == .assistant else { return }
        speak(last.text)
    }

    // MARK: - Plain-text prep

    /// Strip thinking blocks, fenced code blocks, and the small subset of
    /// markdown the renderer applies (emphasis, inline code, links, headings,
    /// list markers) so we don't read syntax characters aloud. Fenced code
    /// blocks are replaced with a "<lang> code block" announcement rather
    /// than read line-by-line.
    static func plainText(_ raw: String) -> String {
        var s = Markdown.stripThinking(raw)

        // 1. Fenced code blocks → "<lang> code block" or "code block".
        if let re = try? NSRegularExpression(
            pattern: "```([\\w+-]*)\\n?([\\s\\S]*?)```", options: []
        ) {
            let ns = s as NSString
            let full = NSRange(location: 0, length: ns.length)
            let matches = re.matches(in: s, options: [], range: full).reversed()
            let mut = NSMutableString(string: s)
            for m in matches {
                let lang = ns.substring(with: m.range(at: 1)).trimmingCharacters(in: .whitespaces)
                let label = lang.isEmpty ? "code block" : "\(lang) code block"
                mut.replaceCharacters(in: m.range, with: label)
            }
            s = mut as String
        }

        // 2. Inline patterns. Process bold before italic so ** isn't eaten by *.
        s = replace(s, pattern: "\\*\\*([^*\\n]+)\\*\\*", template: "$1")
        s = replace(s, pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)", template: "$1")
        s = replace(s, pattern: "`([^`\\n]+)`", template: "$1")
        s = replace(s, pattern: "\\[([^\\]\\n]+)\\]\\([^\\)\\n]*\\)", template: "$1")

        // 3. Line-leading markers: headings, bullets, numbered lists.
        s = replace(s, pattern: "(?m)^\\s*#{1,6}\\s+", template: "")
        s = replace(s, pattern: "(?m)^\\s*[-*+]\\s+", template: "")
        s = replace(s, pattern: "(?m)^\\s*\\d+\\.\\s+", template: "")

        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func replace(_ s: String, pattern: String, template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else { return s }
        let range = NSRange(s.startIndex..., in: s)
        return re.stringByReplacingMatches(in: s, options: [], range: range, withTemplate: template)
    }
}
