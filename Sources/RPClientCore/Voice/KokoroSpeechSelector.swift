import Foundation

/// Builds a Kokoro `SpeechSynthesizing` configured for per-call voice swap.
/// Only the executable layer can satisfy this — `KokoroSpeechSynthesizer`
/// lives in `RPClientVoice`, which Core can't import without dragging the
/// ~50 MB ONNX runtime into the test target.
///
/// The provider closure maps a Kokoro voice id to its on-disk `.pt` file.
/// Returning nil means "this voice id isn't installed" — the synthesizer
/// will fall back to its `defaultVoice` for that utterance.
public typealias KokoroSpeechSynthesizerFactory = (
    _ modelURL: URL,
    _ defaultVoice: KokoroVoice,
    _ voiceFileURLProvider: @escaping (String) -> URL?
) throws -> SpeechSynthesizing

/// Decides whether the Kokoro adapter is installed in `Speaker` based on
/// `Settings.voiceEnabled`, `KokoroModelStore.baseModelState()`, and
/// at-least-one-installed-voice. Re-evaluates on `settingsChanged` and
/// `kokoroDownloadStateChanged`. Phase 6 §7.1l, expanded for §7.4.
///
/// As of §7.4, the selector no longer swaps the Speaker's *only* synthesizer;
/// `Speaker` holds AVKit and Kokoro adapters simultaneously, and routes
/// per-call by `SpeakOptions.voice.engine`. The selector's job is now just
/// "install or remove the Kokoro adapter" — it doesn't pin a specific voice.
/// The Kokoro adapter resolves voice per `speak()` call from its options.
///
/// The factory is supplied by the RPClient executable so Core doesn't
/// need to import `RPClientVoice`. On factory throw, the Kokoro adapter
/// stays uninstalled (NSLog only) — user-visible failure surfacing is
/// deferred to §7.5 polish.
final class KokoroSpeechSelector {
    /// Default voice id when multiple are installed. Picked because the
    /// user has it downloaded and the §7.1 development log uses it as
    /// the primary smoke voice. The synthesizer falls back to this voice
    /// when options carry a nil or unresolvable voice identifier.
    static let defaultVoiceId = "af_alloy"

    private let factory: KokoroSpeechSynthesizerFactory
    private weak var speaker: Speaker?
    private var isKokoroInstalled = false
    private var installedDefaultVoiceId: String?
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
            uninstallKokoro(speaker, reason: "voice subsystem disabled", initial: initial)
            return
        }
        guard let raw = s.voiceModelPath, !raw.isEmpty else {
            uninstallKokoro(speaker, reason: "no storage path configured", initial: initial)
            return
        }
        let store = KokoroModelStore(paths: KokoroStoragePaths(root: URL(fileURLWithPath: raw)))
        guard case let .ready(modelURL, _) = store.baseModelState() else {
            uninstallKokoro(speaker, reason: "base model not ready", initial: initial)
            return
        }
        let installed = store.installedVoiceIds()
        guard !installed.isEmpty else {
            uninstallKokoro(speaker, reason: "no voice files installed", initial: initial)
            return
        }
        let defaultVoiceId = installed.contains(Self.defaultVoiceId) ? Self.defaultVoiceId : installed[0]
        guard let defaultVoice = KokoroVoiceCatalogue.all.first(where: { $0.id == defaultVoiceId }) else {
            uninstallKokoro(speaker, reason: "voice id \(defaultVoiceId) not in catalogue", initial: initial)
            return
        }

        // No-op if Kokoro is already installed with this default voice.
        if isKokoroInstalled, installedDefaultVoiceId == defaultVoiceId { return }

        // Provider reads from disk on every call — voices added/removed
        // between speaks resolve correctly without rebuilding the adapter.
        let provider: (String) -> URL? = { id in
            let url = store.paths.voiceFileURL(id: id)
            return FileManager.default.fileExists(atPath: url.path) ? url : nil
        }
        do {
            let synth = try factory(modelURL, defaultVoice, provider)
            speaker.setKokoroSynthesizer(synth)
            isKokoroInstalled = true
            installedDefaultVoiceId = defaultVoiceId
            log("installed Kokoro adapter (default voice '\(defaultVoiceId)', \(defaultVoice.language.rawValue))")
        } catch {
            log("factory failed (\(error)); Kokoro stays uninstalled")
            uninstallKokoro(speaker, reason: "factory threw", initial: initial)
        }
    }

    private func uninstallKokoro(_ speaker: Speaker, reason: String, initial: Bool) {
        // Only remove if Kokoro was actually installed; the initial decision
        // is logged regardless so launches always show the wiring is alive.
        if isKokoroInstalled {
            speaker.setKokoroSynthesizer(nil)
            isKokoroInstalled = false
            installedDefaultVoiceId = nil
            log("Kokoro adapter removed (\(reason))")
        } else if initial {
            log("Kokoro adapter not installed (\(reason))")
        }
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(
            Data("KokoroSpeechSelector: \(message)\n".utf8)
        )
    }
}
