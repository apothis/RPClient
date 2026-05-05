import Foundation
@testable import RPClientCore

/// Tests for `VoiceStorageScout` — pure storage-option enumerator used by
/// the first-run prompt to surface candidate locations for the configurable
/// voice-model path. Phase 6 §7.1d.
func voiceStorageScoutTests() -> TestSuite {
    let s = TestSuite("VoiceStorageScout")

    let appSupport = URL(fileURLWithPath: "/Users/test/Library/Application Support/RPClient/voice-models")
    let TB: Int64 = 1_000_000_000_000
    let GB: Int64 = 1_000_000_000

    s.test("returns Application Support alone when no external volumes") {
        let opts = VoiceStorageScout.options(from: [], applicationSupport: appSupport)
        try expectEqual(opts.count, 1)
        try expect(!opts[0].isExternal, "Application Support should not be flagged as external")
        try expectEqual(opts[0].path, appSupport)
    }

    s.test("orders external volumes by free space desc, Application Support last") {
        let small = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/USB"),
            name: "USB",
            freeBytes: 4 * GB,
            isInternal: false
        )
        let big = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/SSD1"),
            name: "SSD1",
            freeBytes: 1 * TB,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [small, big], applicationSupport: appSupport)
        try expectEqual(opts.count, 3)
        try expectEqual(opts[0].path.path, "/Volumes/SSD1")
        try expectEqual(opts[1].path.path, "/Volumes/USB")
        try expect(!opts[2].isExternal)
        try expectEqual(opts[2].path, appSupport)
    }

    s.test("filters out internal volumes — boot volume never appears as 'external'") {
        let boot = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/"),
            name: "Macintosh HD",
            freeBytes: 200 * GB,
            isInternal: true
        )
        let ssd = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/SSD1"),
            name: "SSD1",
            freeBytes: 1 * TB,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [boot, ssd], applicationSupport: appSupport)
        try expectEqual(opts.count, 2)
        try expectEqual(opts[0].path.path, "/Volumes/SSD1")
        // Index 1 is Application Support — internal boot volume is dropped, not
        // surfaced even though it has free space.
        try expectEqual(opts[1].path, appSupport)
    }

    s.test("skips external volumes below the model size — can't host 325 MB") {
        let cramped = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/Tiny"),
            name: "Tiny",
            freeBytes: 100_000_000, // 100 MB — too small for the 325 MB model
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [cramped], applicationSupport: appSupport)
        try expectEqual(opts.count, 1)
        try expectEqual(opts[0].path, appSupport)
    }

    s.test("includes external volumes even when freeBytes is unknown (nil)") {
        let unknown = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/Net"),
            name: "Net",
            freeBytes: nil,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [unknown], applicationSupport: appSupport)
        try expectEqual(opts.count, 2)
        try expectEqual(opts[0].path.path, "/Volumes/Net")
    }

    s.test("label format includes free-space when known") {
        let probe = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/SSD1"),
            name: "SSD1",
            freeBytes: 500 * GB,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [probe], applicationSupport: appSupport)
        try expect(opts[0].label.contains("SSD1"), "label should include volume name, got: \(opts[0].label)")
        try expect(
            opts[0].label.contains("free"),
            "label should mention free space, got: \(opts[0].label)"
        )
    }

    s.test("label for unknown free space says so") {
        let probe = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/Net"),
            name: "Net",
            freeBytes: nil,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [probe], applicationSupport: appSupport)
        try expect(opts[0].label.contains("Net"))
    }

    s.test("Application Support option label is recognisable") {
        let opts = VoiceStorageScout.options(from: [], applicationSupport: appSupport)
        try expect(
            opts[0].label.contains("Application Support") || opts[0].label.lowercased().contains("application support"),
            "Application Support option should be self-identifying, got: \(opts[0].label)"
        )
    }

    s.test("each option has a stable id derived from its path") {
        let probe = VoiceStorageScout.VolumeProbe(
            url: URL(fileURLWithPath: "/Volumes/SSD1"),
            name: "SSD1",
            freeBytes: 1 * TB,
            isInternal: false
        )
        let opts = VoiceStorageScout.options(from: [probe], applicationSupport: appSupport)
        try expectEqual(opts.count, 2)
        try expect(opts[0].id != opts[1].id, "external + appSupport should have distinct ids")
        // Id stability: re-running the function gives the same ids.
        let opts2 = VoiceStorageScout.options(from: [probe], applicationSupport: appSupport)
        try expectEqual(opts[0].id, opts2[0].id)
    }

    return s
}
