import AppKit
import AVFoundation

/// Shared NSPopUpButton population for the three voice-picker surfaces in
/// Phase 6 §7.5: entity card (§7.5a), chat header, and Settings (§7.5b).
///
/// The pure ordering / filtering lives in `VoicePickerSource`; this is the
/// AppKit glue that turns those `Option`s into a sectioned popup, prepends a
/// nil-sentinel item ("(use chat default)" / "(use settings default)" /
/// "(none — system fallback)"), and selects the right item for a stored
/// `VoicePreference?`. Stored voices that are no longer in the option list
/// (uninstalled, engine swap) survive as a "Stored (unavailable)" entry so
/// the user's selection isn't silently lost.
enum VoicePopupBuilder {
    /// Populates `popup` and selects the item that matches `current`.
    /// Items map to the raw string of `VoiceIdentifier` via `representedObject`;
    /// the sentinel item has `representedObject == nil`.
    static func populate(
        _ popup: NSPopUpButton,
        options: [VoicePickerSource.Option],
        current: VoicePreference?,
        sentinelTitle: String
    ) {
        popup.removeAllItems()

        popup.addItem(withTitle: sentinelTitle)
        popup.lastItem?.representedObject = nil as String?

        var lastGroup: String? = nil
        for opt in options {
            if opt.groupLabel != lastGroup {
                popup.menu?.addItem(.separator())
                let header = NSMenuItem(title: opt.groupLabel, action: nil, keyEquivalent: "")
                header.isEnabled = false
                popup.menu?.addItem(header)
                lastGroup = opt.groupLabel
            }
            popup.addItem(withTitle: opt.displayName)
            popup.lastItem?.representedObject = opt.identifier.rawValue
        }

        let storedRaw = current?.voiceIdentifier.rawValue
        let availableRaws = Set(options.map(\.identifier.rawValue))
        if let stored = storedRaw, !availableRaws.contains(stored) {
            popup.menu?.addItem(.separator())
            let header = NSMenuItem(title: "Stored (unavailable)", action: nil, keyEquivalent: "")
            header.isEnabled = false
            popup.menu?.addItem(header)
            popup.addItem(withTitle: "\(stored) (not installed)")
            popup.lastItem?.representedObject = stored
        }

        if let stored = storedRaw {
            popup.selectItem(at: 0)
            for (i, item) in (popup.menu?.items ?? []).enumerated() {
                if let raw = item.representedObject as? String, raw == stored {
                    popup.selectItem(at: i)
                    break
                }
            }
        } else {
            popup.selectItem(at: 0)
        }
    }

    /// Live picker option list — `KokoroVoiceCatalogue.all ∩ installedVoiceIds()`
    /// plus `AVSpeechSynthesisVoice.speechVoices()`. Cheap; no ONNX involvement.
    static func currentOptions() -> [VoicePickerSource.Option] {
        let installedKokoro: [String]
        if let raw = AppState.shared.settings.voiceModelPath, !raw.isEmpty {
            let store = KokoroModelStore(paths: KokoroStoragePaths(root: URL(fileURLWithPath: raw)))
            installedKokoro = store.installedVoiceIds()
        } else {
            installedKokoro = []
        }
        let avkit = AVSpeechSynthesisVoice.speechVoices().map { v in
            VoicePickerSource.AVKitVoice(
                identifier: v.identifier,
                displayName: v.name,
                language: v.language
            )
        }
        return VoicePickerSource.options(installedKokoroIds: installedKokoro, avkitVoices: avkit)
    }

    /// Reads a popup selection back into a `VoicePreference?`. Preserves
    /// `rate`/`pitch` from the previous value when switching voices so the
    /// user's manual tuning isn't reset on every pick.
    static func preference(
        fromSelectionOf popup: NSPopUpButton,
        previous: VoicePreference?
    ) -> VoicePreference? {
        guard let raw = popup.selectedItem?.representedObject as? String,
              let parsed = VoiceIdentifier(rawValue: raw) else {
            return nil
        }
        return VoicePreference(
            voiceIdentifier: parsed,
            rate: previous?.rate ?? 1.0,
            pitch: previous?.pitch ?? 1.0
        )
    }
}
