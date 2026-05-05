import Foundation

/// Builds a Kokoro `SpeechSynthesizing` from a (model, voice, language)
/// triple. Only the executable layer can satisfy this — `KokoroSpeechSynthesizer`
/// lives in `RPClientVoice`, which Core can't import without dragging the
/// ~50 MB ONNX runtime into the test target.
public typealias KokoroSpeechSynthesizerFactory = (
    _ modelURL: URL,
    _ voiceFileURL: URL,
    _ language: KokoroLanguage
) throws -> SpeechSynthesizing

/// Picks between AVKit (default) and Kokoro for the global `Speaker`
/// based on `Settings.voiceEnabled`, `KokoroModelStore.baseModelState()`,
/// and at-least-one-installed-voice. Re-evaluates on `settingsChanged` and
/// `kokoroDownloadStateChanged`. Phase 6 §7.1l.
///
/// The factory is supplied by the RPClient executable so Core doesn't
/// need to import `RPClientVoice`. On factory throw, falls back to AVKit
/// silently (NSLog only) — user-visible failure surfacing is deferred to
/// §7.5 polish.
final class KokoroSpeechSelector {
    /// Default voice id when multiple are installed. Picked because the
    /// user has it downloaded and the §7.1 development log uses it as
    /// the primary smoke voice. §7.4 will replace this with per-character
    /// voice routing.
    static let defaultVoiceId = "af_alloy"

    private let factory: KokoroSpeechSynthesizerFactory
    private weak var speaker: Speaker?
    private var isKokoroInstalled = false
    private var installedVoiceId: String?
    private var observers: [NSObjectProtocol] = []

    init(factory: @escaping KokoroSpeechSynthesizerFactory, speaker: Speaker) {
        self.factory = factory
        self.speaker = speaker
    }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
    }

    func start() {
        log("start — initial evaluation")
        evaluate(initial: true)
        let nc = NotificationCenter.default
        let onSettings = nc.addObserver(
            forName: AppNotification.settingsChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluate() }
        let onDownload = nc.addObserver(
            forName: AppNotification.kokoroDownloadStateChanged, object: nil, queue: .main
        ) { [weak self] _ in self?.evaluate() }
        observers = [onSettings, onDownload]
    }

    private func evaluate(initial: Bool = false) {
        guard let speaker = self.speaker else { return }
        let s = AppState.shared.settings

        guard s.voiceEnabled else {
            revertToAVKit(speaker, reason: "voice subsystem disabled", initial: initial)
            return
        }
        guard let raw = s.voiceModelPath, !raw.isEmpty else {
            revertToAVKit(speaker, reason: "no storage path configured", initial: initial)
            return
        }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: URL(fileURLWithPath: raw)))
        guard case let .ready(modelURL, _) = store.baseModelState() else {
            revertToAVKit(speaker, reason: "base model not ready", initial: initial)
            return
        }
        let installed = store.installedVoiceIds()
        guard !installed.isEmpty else {
            revertToAVKit(speaker, reason: "no voice files installed", initial: initial)
            return
        }
        let voiceId = installed.contains(Self.defaultVoiceId) ? Self.defaultVoiceId : installed[0]
        guard let voice = KokoroVoiceCatalogue.all.first(where: { $0.id == voiceId }) else {
            revertToAVKit(speaker, reason: "voice id \(voiceId) not in catalogue", initial: initial)
            return
        }

        // No-op if Kokoro is already installed for this voice.
        if isKokoroInstalled, installedVoiceId == voiceId { return }

        let voiceURL = store.paths.voiceFileURL(id: voiceId)
        do {
            let synth = try factory(modelURL, voiceURL, voice.language)
            speaker.setSynthesizer(synth)
            isKokoroInstalled = true
            installedVoiceId = voiceId
            log("installed Kokoro voice '\(voiceId)' (\(voice.language.rawValue))")
        } catch {
            log("factory failed (\(error)); reverting to AVKit")
            revertToAVKit(speaker, reason: "factory threw", initial: initial)
        }
    }

    private func revertToAVKit(_ speaker: Speaker, reason: String, initial: Bool) {
        // Only swap if Kokoro was actually installed; the initial decision
        // is logged regardless so launches always show the wiring is alive.
        if isKokoroInstalled {
            speaker.setSynthesizer(AVSpeechSynthesizerAdapter())
            isKokoroInstalled = false
            installedVoiceId = nil
            log("reverted to AVKit (\(reason))")
        } else if initial {
            log("staying on AVKit (\(reason))")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data("KokoroSpeechSelector: \(message)\n".utf8)
        )
    }
}
