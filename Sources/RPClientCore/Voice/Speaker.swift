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

    /// Phase 6 §7.5c — synth a short sample line through `voice` so the user
    /// can audition an entity-card pick before saving. Stops in-flight audio
    /// first so the preview is immediately audible (layering the preview on
    /// top of streamed turn audio would be worse than interrupting it).
    ///
    /// Honours the subsystem gate (`voiceEnabled`) but bypasses the runtime
    /// mute (`voiceActive`) — the user explicitly pushed the Preview button,
    /// the runtime mute is for streamed turns.
    func preview(voice: VoicePreference) {
        guard voiceEnabled else { return }
        let text = Speaker.previewText(for: voice.voiceIdentifier)
        let options = SpeakOptions(preference: voice)
        stop()
        synthesizer(for: options).speak(text, options: options, completion: nil)
    }

    /// Sample text for `voiceId`. Kokoro voices use the catalogue's
    /// per-language pangram; AVKit and uncatalogued voices fall back to an
    /// English pangram (we don't parse AVKit voice ids for language here so
    /// Speaker stays free of `AVFoundation` lookups, and a non-English AVKit
    /// voice still demonstrates its character via accent on English text).
    static func previewText(for voiceId: VoiceIdentifier) -> String {
        let englishFallback = "The quick brown fox jumps over the lazy dog."
        switch voiceId.engine {
        case .kokoro:
            if let voice = KokoroVoiceCatalogue.voice(id: voiceId.voiceId),
               !voice.sampleText.isEmpty {
                return voice.sampleText
            }
            return englishFallback
        case .avkit:
            return englishFallback
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
        if voiceEnabled != enabled {
            DebugLog.shared.write("speaker: voiceEnabled \(voiceEnabled) → \(enabled)")
        }
        if shouldSpeak && !enabled {
            stop()
        }
        voiceEnabled = enabled
    }

    /// Mirror `Settings.voiceActive` (the runtime gate) into the speaker.
    func setVoiceActive(_ active: Bool) {
        if voiceActive != active {
            DebugLog.shared.write("speaker: voiceActive \(voiceActive) → \(active)")
        }
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
    /// name`, then matched against `chat.entities`. Returns nil if the
    /// chat has no character set, or if no entity matches.
    private func resolveFirstPersonEntityId(in chat: Chat) -> UUID? {
        guard let characterId = chat.characterId,
              let character = AppState.shared.characters.first(where: { $0.id == characterId })
        else { return nil }
        return Speaker.matchCharacterToEntity(
            characterName: character.name,
            entities: chat.entities
        )
    }

    /// Phase 8 §4.5 — per-turn first-person entity resolution. For
    /// multi-cast assistant turns (`turn.speakerId != nil`), uses the
    /// speaker's character name to match an entity (so each cast member
    /// gets attributed as the "I" of their own turn). Falls back to
    /// `chat.characterId` for solo / free-form chats. Returns nil when
    /// no entity matches the speaker (caller treats as "no first-person
    /// hint" and entity attribution operates without it).
    ///
    /// Pulled out of `resolveFirstPersonEntityId` so the test path can
    /// exercise it without an AppState — `characters` is passed in
    /// rather than read from `AppState.shared`.
    static func resolveSpeakerEntityId(turn: Turn, chat: Chat, characters: [Character]) -> UUID? {
        guard turn.role == .assistant else { return nil }
        let speakerCharacterId: UUID? = turn.speakerId ?? chat.characterId
        guard let cid = speakerCharacterId,
              let character = characters.first(where: { $0.id == cid }) else {
            return nil
        }
        return matchCharacterToEntity(
            characterName: character.name,
            entities: chat.entities
        )
    }

    /// Phase 8 §4.5 — per-turn voice baseline. Resolves the speaker's
    /// matched entity (via `resolveSpeakerEntityId`) and returns its
    /// `voice` if set. Used as the segment-default voice in
    /// `handleStreamFinished` so each cast member's narration uses
    /// their own voice (instead of every speaker falling through to
    /// `chat.voice`). Returns nil when no entity matches or the
    /// matched entity has no voice — caller falls back to chat default.
    static func resolveSpeakerVoice(turn: Turn, chat: Chat, characters: [Character]) -> VoicePreference? {
        guard let entId = resolveSpeakerEntityId(turn: turn, chat: chat, characters: characters),
              let entity = chat.entities.first(where: { $0.id == entId }) else {
            return nil
        }
        return entity.voice
    }

    /// Two-pass match between a character card name and the chat's entity
    /// rows.
    /// 1. Exact case-insensitive match against entity name or alias.
    /// 2. Word-bounded fallback: if any whitespace-separated word in the
    ///    character name matches any word of an entity name/alias.
    /// The fallback handles common setups where the card name carries an
    /// extra qualifier the user didn't put in their entity row — e.g. card
    /// `"Anna of the Wood"` matching entity `"Anna"`.
    static func matchCharacterToEntity(characterName: String, entities: [Entity]) -> UUID? {
        let charName = characterName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !charName.isEmpty else { return nil }

        func lowerCandidates(_ ent: Entity) -> [String] {
            ([ent.name] + ent.aliases)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        }
        // Pass 1 — exact match.
        for ent in entities {
            if lowerCandidates(ent).contains(charName) { return ent.id }
        }
        // Pass 2 — word-bounded fallback.
        let charWords = Set(
            charName.split(whereSeparator: { !$0.isLetter }).map(String.init)
        )
        guard !charWords.isEmpty else { return nil }
        for ent in entities {
            for cand in lowerCandidates(ent) {
                let candWords = Set(
                    cand.split(whereSeparator: { !$0.isLetter }).map(String.init)
                )
                if !charWords.isDisjoint(with: candWords) { return ent.id }
            }
        }
        return nil
    }

    private func handleStreamFinished() {
        guard shouldSpeak else {
            DebugLog.shared.write(
                "speaker: skip stream-finished — voiceEnabled=\(voiceEnabled) voiceActive=\(voiceActive)"
            )
            return
        }
        guard let chat = AppState.shared.currentChat else {
            DebugLog.shared.write("speaker: skip stream-finished — no current chat")
            return
        }
        speakAssistantLeaf(in: chat, source: "stream-finished")
    }

    /// Phase 8 deferred polish — replay a specific assistant turn's
    /// audio without regenerating the reply text. Re-runs the
    /// attribution + dispatch pipeline fresh each call (no cached
    /// audio), so debug iterations like assigning a voice or tweaking
    /// `chat.attributionMode` take effect on the next press. Bypasses
    /// `voiceActive` (per-chat mute) because the user explicitly asked
    /// for audio — but still honors `voiceEnabled` (no synth at all
    /// when the subsystem is off).
    func replay(turnId: UUID) {
        guard voiceEnabled else {
            DebugLog.shared.write("speaker: replay skipped — voiceEnabled=false")
            return
        }
        guard let chat = AppState.shared.currentChat else {
            DebugLog.shared.write("speaker: replay skipped — no current chat")
            return
        }
        guard let turn = chat.turn(id: turnId), turn.role == .assistant else {
            DebugLog.shared.write("speaker: replay skipped — turn \(turnId) not an assistant turn")
            return
        }
        // Stop any in-flight playback so replay doesn't queue behind
        // the previous batch. Mirrors what stream-started observers do.
        stop()
        speakTurn(turn, in: chat, source: "replay")
    }

    /// Shared body of `handleStreamFinished` and `replay(turnId:)`.
    /// `source` is logged so the debug stream tells `replay` calls
    /// apart from natural stream-finish events.
    private func speakAssistantLeaf(in chat: Chat, source: String) {
        // §3.3b: speak the active leaf, not storage's `turns.last` — once
        // forks exist, the last-stored turn might be off-path while the
        // freshly streamed reply lives at the active leaf.
        guard let leafId = chat.activePath.last,
              let last = chat.turn(id: leafId),
              last.role == .assistant else {
            DebugLog.shared.write("speaker: skip \(source) — no asst leaf")
            return
        }
        speakTurn(last, in: chat, source: source)
    }

    /// Speak a specific turn. Both the natural stream-finished path
    /// (via leaf resolution) and the explicit replay path land here.
    /// Pure dispatch — no shouldSpeak gate; callers gate as appropriate.
    private func speakTurn(_ last: Turn, in chat: Chat, source: String) {
        DebugLog.shared.write("speaker: speak (\(source)) leaf=\(last.id) chars=\(last.text.count)")
        let plain = Speaker.plainText(last.text)
        guard !plain.isEmpty else { return }

        // Phase 8 §4.5 — per-turn voice baseline. Multi-cast chats
        // resolve the active speaker's matched entity and use its
        // `voice` as the segment-default for narration, so each
        // speaker's prose reads in their own voice instead of every
        // speaker falling through to chat.voice. Gated on
        // `cast.count > 1` because solo chats have no concept of "the
        // speaker who isn't the narrator" — pre-§4.5 they used
        // chat-default for narration and entity voices only fired on
        // attributed quoted spans. Restoring that for solo: only
        // multi-cast routes through speakerVoice.
        let characters = AppState.shared.characters
        let speakerVoice: VoicePreference? = (chat.cast.count > 1)
            ? Speaker.resolveSpeakerVoice(turn: last, chat: chat, characters: characters)
            : nil
        let chatDefault = chat.voice ?? AppState.shared.settings.defaultVoice
        let segmentDefault = speakerVoice ?? chatDefault
        let segmentDefaultOptions = SpeakOptions(preference: segmentDefault)

        // First-person hint: in RP, the model usually speaks AS the
        // active speaker — the "I" in narration is that character.
        // Phase 8 §4.5 — resolved per-turn so multi-cast attributes
        // first-person to whoever spoke this turn, not always the chat's
        // primary character. Falls back to chat.characterId for solo.
        let firstPersonEntityId = Speaker.resolveSpeakerEntityId(
            turn: last, chat: chat, characters: characters
        )
        // Phase 8 §4.5 diagnostic — surface the per-turn voice
        // resolution path so when a user reports "wrong voice fired,"
        // the log tells us which character/entity were matched + which
        // voice was picked. Cheap; one line per stream-finish.
        let speakerCharName: String = {
            guard let sid = last.speakerId,
                  let c = characters.first(where: { $0.id == sid }) else {
                return "nil"
            }
            return c.name
        }()
        let firstPersonName: String = {
            guard let fpid = firstPersonEntityId,
                  let e = chat.entities.first(where: { $0.id == fpid }) else {
                return "nil"
            }
            return e.name
        }()
        DebugLog.shared.write("""
            speaker: voice-resolve \
            speakerId=\(last.speakerId?.uuidString.prefix(8) ?? "nil") (\(speakerCharName)) \
            firstPersonEnt=\(firstPersonEntityId?.uuidString.prefix(8) ?? "nil") (\(firstPersonName)) \
            speakerVoice=\(speakerVoice?.voiceIdentifier.voiceId ?? "nil") \
            chatDefault=\(chatDefault?.voiceIdentifier.voiceId ?? "nil") \
            usingDefault=\(segmentDefault?.voiceIdentifier.voiceId ?? "nil")
            """)

        let attributedSegments = SpeakerAttribution.split(
            text: plain,
            entities: chat.entities,
            mode: chat.attributionMode,
            firstPersonEntityId: firstPersonEntityId
        )

        let segments: [(text: String, options: SpeakOptions)] = attributedSegments.enumerated().map { (idx, seg) in
            let options: SpeakOptions
            let pickedSource: String
            if let id = seg.entityId,
               let entity = chat.entities.first(where: { $0.id == id }),
               let voice = entity.voice {
                options = SpeakOptions(preference: voice)
                pickedSource = "ent[\(entity.name)]"
            } else if let id = seg.entityId,
                      let entity = chat.entities.first(where: { $0.id == id }) {
                options = segmentDefaultOptions
                pickedSource = "ent[\(entity.name)] (no voice → default)"
            } else {
                options = segmentDefaultOptions
                pickedSource = "narrator (default)"
            }
            DebugLog.shared.write(
                "speaker: seg[\(idx)] chars=\(seg.text.count) → voice=\(options.voice?.voiceId ?? "nil") via \(pickedSource)"
            )
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

