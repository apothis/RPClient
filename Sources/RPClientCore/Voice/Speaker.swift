import AVFoundation
import Foundation

/// Abstraction over the underlying TTS engine. Each conforming type handles
/// one engine; multi-engine routing (Kokoro vs AVKit) lives in `Speaker`.
/// Phase 6 §7.4 expanded the seam from text-only to options-aware so the
/// per-character fallback chain can flow through to the actual synthesizer
/// without the speaker layer caring which engine is on the other end. §7.4b
/// added the optional `completion` so the queue can serialize segments
/// across utterances.
public protocol SpeechSynthesizing: AnyObject {
    /// Speak `text` with `options`. If `completion` is non-nil, fires
    /// (on the main queue) when the utterance finishes playing — used by
    /// `Speaker.speakSegments(_:)` to advance the queue. nil completion
    /// = fire-and-forget (the legacy single-segment path).
    func speak(_ text: String, options: SpeakOptions, completion: (() -> Void)?)

    /// Speak a list of `(text, options)` segments in order. `completion`
    /// fires once when the LAST segment finishes. Phase 6 §7.4b polish:
    /// the default impl below queues every segment via `speak()` in a
    /// single pass — engines that queue utterances natively (AVKit) get
    /// pipelining for free. Engines whose `speak()` is destructive
    /// across segments (Kokoro: each `speak()` calls `player.stop()`)
    /// must override this to interleave synthesis with playback without
    /// resetting between segments.
    func speakBatch(_ segments: [(text: String, options: SpeakOptions)], completion: (() -> Void)?)

    func stopSpeaking()
}

extension SpeechSynthesizing {
    /// Convenience for tests + back-compat call sites that don't carry
    /// completion handlers.
    public func speak(_ text: String, options: SpeakOptions = .default) {
        speak(text, options: options, completion: nil)
    }

    /// Default `speakBatch` — fire all utterances at the engine in a
    /// single pass, only attaching `completion` to the last. Works for
    /// engines whose `speak()` queues without resetting (AVKit).
    public func speakBatch(_ segments: [(text: String, options: SpeakOptions)], completion: (() -> Void)?) {
        guard !segments.isEmpty else {
            if let completion { DispatchQueue.main.async(execute: completion) }
            return
        }
        let lastIndex = segments.count - 1
        for (i, seg) in segments.enumerated() {
            speak(seg.text, options: seg.options, completion: i == lastIndex ? completion : nil)
        }
    }
}

/// AVKit-backed `SpeechSynthesizing`. Honours `SpeakOptions.voice` (looked up
/// via `AVSpeechSynthesisVoice(identifier:)`), `rate`, and `pitch`. A nil or
/// unrecognised voice falls back to the system default — AVKit's catalogue
/// is closed-set, so a user-stored identifier that's been removed by an OS
/// update should still produce *some* audio rather than silence.
///
/// Implements `AVSpeechSynthesizerDelegate` so per-utterance completion
/// handlers fire on `didFinish` / `didCancel`. Handlers are kept in a dict
/// keyed by `ObjectIdentifier(utterance)` because AVSpeechSynthesizer can
/// queue several utterances ahead.
final class AVSpeechSynthesizerAdapter: NSObject, SpeechSynthesizing, AVSpeechSynthesizerDelegate {
    private let synth = AVSpeechSynthesizer()
    private var completions: [ObjectIdentifier: () -> Void] = [:]
    private let lock = NSLock()

    override init() {
        super.init()
        synth.delegate = self
    }

    func speak(_ text: String, options: SpeakOptions, completion: (() -> Void)? = nil) {
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
        if let completion = completion {
            lock.lock()
            completions[ObjectIdentifier(utterance)] = completion
            lock.unlock()
        }
        synth.speak(utterance)
    }

    func stopSpeaking() {
        synth.stopSpeaking(at: .immediate)
        // didCancelSpeechUtterance fires for cancelled utterances; the
        // completion dict drains there. Defensive: also clear any entries
        // not associated with a delegate callback so a stuck handler can't
        // leak across stop boundaries.
        lock.lock()
        completions.removeAll()
        lock.unlock()
    }

    private func fireCompletion(for utterance: AVSpeechUtterance) {
        lock.lock()
        let completion = completions.removeValue(forKey: ObjectIdentifier(utterance))
        lock.unlock()
        guard let completion = completion else { return }
        DispatchQueue.main.async(execute: completion)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        fireCompletion(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        fireCompletion(for: utterance)
    }
}

/// Multi-engine TTS pipeline gated on `Settings.voiceEnabled` (subsystem) AND
/// `Settings.voiceActive` (runtime). V2_PLAN §7.0/§7.1f/§7.4. Speaks
/// just-completed assistant turns; per-call voice routing flows from the
/// fallback chain `Entity.voice ?? Chat.voice ?? Settings.defaultVoice`,
/// projected through `SpeakOptions(preference:)` at the call site.
///
/// As of §7.3 + §7.4b, `handleStreamFinished` runs the chat's
/// `attributionMode` to split the turn into `[AttributedSegment]`, resolves
/// each segment's voice through the entity → chat → settings fallback, and
/// hands the list to `speakSegments(_:)` — which plays them in order using
/// each adapter's completion callback to advance the queue.
///
/// Holds adapters for both engines simultaneously: AVKit is always available
/// (system default fallback), Kokoro is installed by `KokoroSpeechSelector`
/// when the model is downloaded and at least one voice is on disk. Routing
/// is by `options.voice?.engine`; nil voice (no preference set anywhere in
/// the chain) prefers Kokoro when available, AVKit otherwise.
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

    /// Monotonic id incremented on every `stop()` and at the start of every
    /// `speakSegments(_:)`. The queue advancer checks this is unchanged
    /// before scheduling the next segment so a cancellation between two
    /// segments doesn't leak audio from the cancelled batch.
    private var queueGeneration: UInt64 = 0
    private let queueLock = NSLock()

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
    /// `options.voice?.engine`. Single-segment path; multi-segment goes
    /// through `speakSegments(_:)`.
    func speak(_ raw: String, options: SpeakOptions = .default) {
        guard shouldSpeak else { return }
        let text = Speaker.plainText(raw)
        guard !text.isEmpty else { return }
        synthesizer(for: options).speak(text, options: options, completion: nil)
    }

    /// Speak a list of `(text, options)` segments in order. Consecutive
    /// segments routed to the same engine are grouped into a single
    /// `speakBatch(_:completion:)` call so that engine can pipeline its
    /// internal work — synthesis can run while the previous segment is
    /// still playing. Cross-engine boundaries fall back to the
    /// completion-driven sequential model. Phase 6 §7.4b (initial impl)
    /// + cadence polish (this version).
    ///
    /// No-op unless both gates are on. Empty list also no-ops.
    func speakSegments(_ segments: [(text: String, options: SpeakOptions)]) {
        guard shouldSpeak else { return }
        let nonEmpty = segments.filter { !$0.text.isEmpty }
        guard !nonEmpty.isEmpty else { return }

        queueLock.lock()
        queueGeneration &+= 1
        let myGen = queueGeneration
        queueLock.unlock()

        let runs = groupRuns(nonEmpty)
        playNextRun(runs: runs, myGen: myGen)
    }

    /// Walk `segments` and group consecutive entries that route to the
    /// same engine adapter. Each run is passed to that adapter's
    /// `speakBatch` as a single batch.
    private func groupRuns(_ segments: [(text: String, options: SpeakOptions)])
        -> [(synth: SpeechSynthesizing, segments: [(text: String, options: SpeakOptions)])]
    {
        var runs: [(synth: SpeechSynthesizing, segments: [(text: String, options: SpeakOptions)])] = []
        var currentSynth: SpeechSynthesizing? = nil
        var currentSegs: [(text: String, options: SpeakOptions)] = []
        for seg in segments {
            let s = synthesizer(for: seg.options)
            if let cur = currentSynth, cur === s {
                currentSegs.append(seg)
            } else {
                if let cur = currentSynth, !currentSegs.isEmpty {
                    runs.append((cur, currentSegs))
                }
                currentSynth = s
                currentSegs = [seg]
            }
        }
        if let cur = currentSynth, !currentSegs.isEmpty {
            runs.append((cur, currentSegs))
        }
        return runs
    }

    private func playNextRun(
        runs: [(synth: SpeechSynthesizing, segments: [(text: String, options: SpeakOptions)])],
        myGen: UInt64
    ) {
        guard !runs.isEmpty else { return }
        var remaining = runs
        let next = remaining.removeFirst()
        next.synth.speakBatch(next.segments) { [weak self] in
            guard let self = self else { return }
            self.queueLock.lock()
            let stillCurrent = (self.queueGeneration == myGen)
            self.queueLock.unlock()
            guard stillCurrent else { return }
            self.playNextRun(runs: remaining, myGen: myGen)
        }
    }

    /// Cancel any in-flight utterance on either engine immediately and bump
    /// the queue generation so any pending segment-completion callbacks
    /// from a superseded batch are discarded.
    func stop() {
        queueLock.lock()
        queueGeneration &+= 1
        queueLock.unlock()
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

    /// Find the entity that represents the chat's character card (the AI's
    /// persona). Walked through `chat.characterId → AppState.characters →
    /// name` and matched against `chat.entities` by case-insensitive name
    /// or alias. Returns nil if the chat has no character set, or if no
    /// entity matches by name. The match is on entity name/alias so
    /// users who keep an entity row for their chat character get
    /// first-person attribution; users who don't lose nothing.
    private func resolveFirstPersonEntityId(in chat: Chat) -> UUID? {
        guard let characterId = chat.characterId,
              let character = AppState.shared.characters.first(where: { $0.id == characterId })
        else { return nil }
        let lookupName = character.name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !lookupName.isEmpty else { return nil }
        for ent in chat.entities {
            let candidates = ([ent.name] + ent.aliases)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            if candidates.contains(lookupName) {
                return ent.id
            }
        }
        return nil
    }

    private func handleStreamFinished() {
        guard shouldSpeak else { return }
        guard let chat = AppState.shared.currentChat,
              let last = chat.turns.last,
              last.role == .assistant else { return }
        let plain = Speaker.plainText(last.text)
        guard !plain.isEmpty else { return }

        // Resolve the chat-default voice once — used for narrator segments
        // (entityId == nil) and for any matched entity that didn't pick
        // a voice of its own.
        let chatDefault = chat.voice ?? AppState.shared.settings.defaultVoice
        let chatDefaultOptions = SpeakOptions(preference: chatDefault)

        // First-person hint: in RP, the model usually speaks AS the chat's
        // character — the "I" in narration is that character. Resolve the
        // character card → its name → the entity matching that name, and
        // pass that entity id as the first-person speaker. Falls back to
        // nil (older heuristic behaviour) if any link in the chain is
        // missing.
        let firstPersonEntityId = resolveFirstPersonEntityId(in: chat)

        let attributedSegments = SpeakerAttribution.split(
            text: plain,
            entities: chat.entities,
            mode: chat.attributionMode,
            firstPersonEntityId: firstPersonEntityId
        )

        let segments: [(text: String, options: SpeakOptions)] = attributedSegments.map { seg in
            let options: SpeakOptions
            if let id = seg.entityId,
               let entity = chat.entities.first(where: { $0.id == id }),
               let voice = entity.voice {
                options = SpeakOptions(preference: voice)
            } else {
                options = chatDefaultOptions
            }
            return (seg.text, options)
        }

        speakSegments(segments)
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

