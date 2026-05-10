import Foundation
@testable import RPClientCore

/// Tests for `KokoroManifest` — the Codable state file recording which
/// model + voices are installed at a given storage root. Phase 6 §7.1e.
func kokoroManifestTests() -> TestSuite {
    let s = TestSuite("KokoroManifest")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    s.test("empty manifest round-trips") {
        let m = KokoroManifest.empty
        let data = try encoder.encode(m)
        let decoded = try decoder.decode(KokoroManifest.self, from: data)
        try expectEqual(decoded, m)
        try expectNil(decoded.model)
        try expectEqual(decoded.voices.count, 0)
    }

    s.test("manifest with model + voices round-trips") {
        let when = Date(timeIntervalSince1970: 1_750_000_000)
        var m = KokoroManifest.empty
        m.model = .init(sha256: "abc123", bytes: 325_532_387, downloadedAt: when)
        m.voices["af_bella"] = .init(sha256: "deadbeef", bytes: 523_425, downloadedAt: when)
        m.voices["am_michael"] = .init(sha256: "cafef00d", bytes: 523_435, downloadedAt: when)

        let data = try encoder.encode(m)
        let decoded = try decoder.decode(KokoroManifest.self, from: data)

        try expectEqual(decoded.model?.sha256, "abc123")
        try expectEqual(decoded.model?.bytes, 325_532_387)
        try expectEqual(decoded.voices.count, 2)
        try expectEqual(decoded.voices["af_bella"]?.sha256, "deadbeef")
    }

    s.test("decoding a missing-fields manifest defaults voices to empty") {
        // A manifest written by an earlier version that didn't ship voices
        // should still decode rather than throwing.
        let bareJSON = """
        { "version": 1 }
        """.data(using: .utf8)!
        let decoded = try decoder.decode(KokoroManifest.self, from: bareJSON)
        try expectEqual(decoded.voices.count, 0)
        try expectNil(decoded.model)
    }

    s.test("manifest version field is encoded so future migrations have a hook") {
        let m = KokoroManifest.empty
        let data = try encoder.encode(m)
        let json = String(data: data, encoding: .utf8) ?? ""
        try expect(json.contains("\"version\""), "manifest must encode a version field, got: \(json)")
    }

    return s
}
