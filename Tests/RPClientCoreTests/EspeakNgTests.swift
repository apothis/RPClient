import Foundation
@testable import RPClientCore

/// Tests for `EspeakNg.resolve(...)` — the pure path-resolution logic that
/// drives the voice library status row (Phase 6 §7.1k-prep). The live
/// `find()` shells out to `/usr/bin/which` and is smoke-tested at runtime.
func espeakNgTests() -> TestSuite {
    let s = TestSuite("EspeakNg")

    let appleSilicon = "/opt/homebrew/bin/espeak-ng"
    let intel = "/usr/local/bin/espeak-ng"

    s.test("standardPaths starts with Apple Silicon homebrew path") {
        try expectEqual(EspeakNg.standardPaths.first, appleSilicon)
    }

    s.test("standardPaths includes Intel homebrew path second") {
        try expectEqual(EspeakNg.standardPaths.count, 2)
        try expectEqual(EspeakNg.standardPaths[1], intel)
    }

    s.test("resolve picks Apple Silicon path when both standards exist") {
        let url = EspeakNg.resolve(
            candidates: EspeakNg.standardPaths,
            fileExists: { _ in true },
            whichLookup: { "/should/not/be/used" }
        )
        try expectEqual(url?.path, appleSilicon)
    }

    s.test("resolve falls through to Intel path when Apple Silicon missing") {
        let url = EspeakNg.resolve(
            candidates: EspeakNg.standardPaths,
            fileExists: { $0 == intel },
            whichLookup: { "/should/not/be/used" }
        )
        try expectEqual(url?.path, intel)
    }

    s.test("resolve falls back to which output when no standard path exists") {
        let url = EspeakNg.resolve(
            candidates: EspeakNg.standardPaths,
            fileExists: { _ in false },
            whichLookup: { "/Users/dev/.local/bin/espeak-ng" }
        )
        try expectEqual(url?.path, "/Users/dev/.local/bin/espeak-ng")
    }

    s.test("resolve returns nil when nothing found") {
        let url = EspeakNg.resolve(
            candidates: EspeakNg.standardPaths,
            fileExists: { _ in false },
            whichLookup: { nil }
        )
        try expectNil(url)
    }

    s.test("resolve treats empty which output as not-found") {
        let url = EspeakNg.resolve(
            candidates: EspeakNg.standardPaths,
            fileExists: { _ in false },
            whichLookup: { "" }
        )
        try expectNil(url)
    }

    return s
}
