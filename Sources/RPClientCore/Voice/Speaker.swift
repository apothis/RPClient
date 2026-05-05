import AVFoundation
import Foundation

/// Abstraction over the underlying TTS engine. Each conforming type handles
/// one engine; multi-engine routing (Kokoro vs AVKit) lives in `Speaker`.
/// Phase 6 §7.4 expanded the seam from text-only to options-aware so the
/// per-character fallback chain can flow through to the actual synthesizer
/// without the speaker layer caring which engine is on the other end.
public protocol SpeechSynthesizing: AnyObject {
    func speak(_ text: String, options: SpeakOptions)
    func stopSpeaking()
}

extension SpeechSynthesizing {
    /// Convenience for tests + the `handleStreamFinished` path that doesn't
    /// have a `SpeakOptions` to hand. Routes through `.default`.
    public func speak(_ text: String) {
        speak(text, options: .default)
    }
}

/// AVKit-backed `SpeechSynthesizing`. Honours `SpeakOptions.voice` (looked up
/// via `AVSpeechSynthesisVoice(identifier:)`), `rate`, and `pitch`. A nil or
/// unrecognised voice falls back to the system default — AVKit's catalogue
/// is closed-set, so a user-stored identifier that's been removed by an OS
/// update should still produce *some* audio rather than silence.
final class AVSpeechSynthesizerAdapter: SpeechSynthesizing {
    private let synth = AVSpeechSynthesizer()

    func speak(_ text: String, options: SpeakOptions) {
        let utterance = AVSpeechUtterance(string: text)
        if let id = options.voice?.voiceId,
           options.voice?.engine == .avkit,
           let voice = AVSpeechSynthesisVoice(identifier: id) {
            utterance.voice = voice
        }
        // AVKit native rate range is [Min, Max] with 0.5 ≈ "normal". Our
        // 1.0-centred multiplier maps to AVKit by halving (rate 1.0 → 0.5).
        let nativeRate = max(
            AVSpeechUtteranceMinimumSpeechRate,
            min(AVSpeechUtteranceMaximumSpeechRate, options.rate * 0.5)
        )
        utterance.rate = nativeRate
        // pitchMultiplier shares our 0.5..2.0 scale.
        utterance.pitchMultiplier = max(0.5, min(2.0, options.pitch))
        synth.speak(utterance)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
    }
}

/// Multi-engine TTS pipeline gated on `Settings.voiceEnabled` (subsystem) AND
/// `Settings.voiceActive` (runtime). V2_PLAN §7.0/§7.1f/§7.4. Speaks
/// just-completed assistant turns; per-call voice routing flows from the
/// fallback chain `Entity.voice ?? Chat.voice ?? Settings.defaultVoice`,
/// projected through `SpeakOptions(preference:)` at the call site. Per-character
/// attribution is still pending §7.3 — until then every turn is one segment
/// using the chat-resolved voice.
///
/// Holds adapters for both engines simultaneously: AVKit is always available
/// (system default fallback), Kokoro is installed by `KokoroSpeechSelector`
/// when the model is downloaded and at least one voice is on disk. Routing
/// is by `options.voice?.engine`; nil voice (no preference set anywhere in
/// the chain) prefers Kokoro when available, AVKit otherwise — matching the
/// pre-§7.4 default-engine behaviour.
///
/// Owned by `AppState`. Subscribes to `streamFinished`, `streamStarted`,
/// `currentChatChanged`, `settingsChanged`, and `voiceActiveChanged` so
/// callers don't need to drive it explicitly.
final class Speaker {
    private let avkit: SpeechSynthesizing
    private var kokoro: SpeechSynthesizing?
    private var voiceEnabled: Bool
    private var voiceActive: Bool
    private var observers: [NSObjectProtocol] = []

    private var shouldSpeak: Bool { voiceEnabled && voiceActive }

    init(voiceEnabled: Bool,
         voiceActive: Bool = true,
         avkit: SpeechSynthesizing = AVSpeechSynthesizerAdapter(),
         kokoro: SpeechSynthesizing? = nil) {
        self.avkit = avkit
        self.kokoro = kokoro
        self.voiceEnabled = voiceEnabled
        self.voiceActive = voiceActive
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    /// Speak `raw` with the given `options`, after stripping `<think>` blocks
    /// and markdown formatting. No-op unless both gates are on, or when the
    /// stripped text is empty. Dispatches to the right engine based on
    /// `options.voice?.engine`.
    func speak(_ raw: String, options: SpeakOptions = .default) {
        guard shouldSpeak else { return }
        let text = Speaker.plainText(raw)
        guard !text.isEmpty else { return }
        synthesizer(for: options).speak(text, options: options)
    }

    /// Cancel any in-flight utterance on either engine immediately.
    func stop() {
        avkit.stopSpeaking()
        kokoro?.stopSpeaking()
    }

    /// Install or remove the Kokoro adapter. Called by `KokoroSpeechSelector`
    /// when the engine becomes ready / unready. Stops in-flight Kokoro audio
    /// on removal so the change is audible.
    func setKokoroSynthesizer(_ new: SpeechSynthesizing?) {
        kokoro?.stopSpeaking()
        kokoro = new
    }

    /// Mirror `Settings.voiceEnabled` (the subsystem gate) into the speaker.
    /// Flipping off while speech is live stops both engines so the toggle
    /// feels immediate.
    func setVoiceEnabled(_ enabled: Bool) {
        if shouldSpeak && !enabled {
            stop()
        }
        voiceEnabled = enabled
    }

    /// Mirror `Settings.voiceActive` (the runtime gate) into the speaker.
    func setVoiceActive(_ active: Bool) {
        if shouldSpeak && !active {
            stop()
        }
        voiceActive = active
    }

    /// Pick the engine adapter for these options. Kokoro voices route to the
    /// Kokoro adapter when installed; if not, fall back to AVKit (the picker
    /// shouldn't have offered the voice in the first place, but a stale
    /// stored preference shouldn't produce silence). AVKit voices always
    /// route to AVKit. Nil voice prefers Kokoro when available — the
    /// pre-§7.4 default-engine behaviour.
    private func synthesizer(for options: SpeakOptions) -> SpeechSynthesizing {
        switch options.voice?.engine {
        case .avkit:
            return avkit
        case .kokoro:
            return kokoro ?? avkit
        case nil:
            return kokoro ?? avkit
        }
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
            self?.stop()
        }
        let stopOnChatSwitch = nc.addObserver(
            forName: AppNotification.currentChatChanged, object: nil, queue: .main
        ) { [weak self] _ in
            self?.stop()
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
        guard let chat = AppState.shared.currentChat,
              let last = chat.turns.last,
              last.role == .assistant else { return }
        // Chat-level voice; falls through to the global default; falls
        // through to nil → engine-default routing. Per-character attribution
        // (§7.3) will replace this single options value with a queue of
        // segment-tagged options.
        let resolved = chat.voice ?? AppState.shared.settings.defaultVoice
        speak(last.text, options: SpeakOptions(preference: resolved))
    }

    // MARK: - Plain-text prep

    /// Strip thinking blocks, fenced code blocks, and the small subset of
    /// markdown the renderer applies (emphasis, inline code, links, headings,
    /// list markers) so we don't read syntax characters aloud. Fenced code
    /// blocks are replaced with a "<lang> code block" announcement rather
    /// than read line-by-line.
    static func plainText(_ raw: String) -> String {
        var s = Markdown.stripThinking(raw)

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

        s = replace(s, pattern: "\\*\\*([^*\\n]+)\\*\\*", template: "$1")
        s = replace(s, pattern: "(?<!\\*)\\*([^*\\n]+)\\*(?!\\*)", template: "$1")
        s = replace(s, pattern: "`([^`\\n]+)`", template: "$1")
        s = replace(s, pattern: "\\[([^\\]\\n]+)\\]\\([^\\)\\n]*\\)", template: "$1")

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
