import Foundation
@testable import RPClientCore

func koboldClientRegistryTests() -> TestSuite {
    let s = TestSuite("KoboldClientRegistry")

    func makeSettings(servers: [ServerProfile],
                      defaultId: UUID,
                      summarizer: UUID? = nil,
                      extractor: UUID? = nil,
                      embeddings: UUID? = nil) -> Settings {
        var out = Settings.default
        out.servers = servers
        out.defaultServerId = defaultId
        out.summarizerServerId = summarizer
        out.extractorServerId = extractor
        out.embeddingsServerId = embeddings
        return out
    }

    s.test("same profile id returns the same KoboldClient instance across lookups") {
        let p = ServerProfile(name: "P", baseURL: URL(string: "http://localhost:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [p], defaultId: p.id))
        let a = reg.client(for: .general, chatOverride: nil)
        let b = reg.client(for: .general, chatOverride: nil)
        try expect(a === b, "expected cached client identity")
    }

    s.test("different profiles get different KoboldClient instances") {
        let a = ServerProfile(name: "A", baseURL: URL(string: "http://a:5001")!)
        let b = ServerProfile(name: "B", baseURL: URL(string: "http://b:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [a, b], defaultId: a.id, summarizer: b.id))
        let ca = reg.client(for: .general, chatOverride: nil)
        let cb = reg.client(for: .summarizer, chatOverride: nil)
        try expect(ca !== cb, "expected different clients per profile")
        try expectEqual(ca.baseURL.absoluteString, "http://a:5001")
        try expectEqual(cb.baseURL.absoluteString, "http://b:5001")
    }

    s.test(".general with chatOverride uses that profile") {
        let def = ServerProfile(name: "Def", baseURL: URL(string: "http://def:5001")!)
        let pinned = ServerProfile(name: "Pinned", baseURL: URL(string: "http://pinned:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [def, pinned], defaultId: def.id))
        let c = reg.client(for: .general, chatOverride: pinned.id)
        try expectEqual(c.baseURL.absoluteString, "http://pinned:5001")
    }

    s.test(".general with chatOverride pointing to a missing profile falls back to default") {
        let def = ServerProfile(name: "Def", baseURL: URL(string: "http://def:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [def], defaultId: def.id))
        let c = reg.client(for: .general, chatOverride: UUID())
        try expectEqual(c.baseURL.absoluteString, "http://def:5001")
    }

    s.test("side-call roles ignore chatOverride and consult role-specific override") {
        let def = ServerProfile(name: "Def", baseURL: URL(string: "http://def:5001")!)
        let big = ServerProfile(name: "Big", baseURL: URL(string: "http://big:5001")!)
        let pinned = ServerProfile(name: "Pinned", baseURL: URL(string: "http://pinned:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(
            servers: [def, big, pinned],
            defaultId: def.id,
            summarizer: big.id,
            extractor: big.id
        ))
        // chatOverride is the chat's generation pin — must not leak into side-calls.
        let sumC = reg.client(for: .summarizer, chatOverride: pinned.id)
        let extC = reg.client(for: .extractor, chatOverride: pinned.id)
        try expectEqual(sumC.baseURL.absoluteString, "http://big:5001")
        try expectEqual(extC.baseURL.absoluteString, "http://big:5001")
    }

    s.test("role override falls back to default when unset") {
        let def = ServerProfile(name: "Def", baseURL: URL(string: "http://def:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [def], defaultId: def.id))
        let sumC = reg.client(for: .summarizer, chatOverride: nil)
        let extC = reg.client(for: .extractor, chatOverride: nil)
        let embC = reg.client(for: .embeddings, chatOverride: nil)
        try expectEqual(sumC.baseURL.absoluteString, "http://def:5001")
        try expectEqual(extC.baseURL.absoluteString, "http://def:5001")
        try expectEqual(embC.baseURL.absoluteString, "http://def:5001")
        try expect(sumC === extC, "all roles falling back to default share the cached default client")
        try expect(extC === embC, "all roles falling back to default share the cached default client")
    }

    s.test("role override pointing to a deleted profile falls back to default") {
        let def = ServerProfile(name: "Def", baseURL: URL(string: "http://def:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(
            servers: [def], defaultId: def.id, summarizer: UUID()
        ))
        let sumC = reg.client(for: .summarizer, chatOverride: nil)
        try expectEqual(sumC.baseURL.absoluteString, "http://def:5001")
    }

    s.test("updateSettings mutates baseURL of cached client (preserves instance identity)") {
        let p = ServerProfile(name: "P", baseURL: URL(string: "http://old:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [p], defaultId: p.id))
        let before = reg.client(for: .general, chatOverride: nil)
        try expectEqual(before.baseURL.absoluteString, "http://old:5001")

        var p2 = p
        p2.baseURL = URL(string: "http://new:5001")!
        reg.updateSettings(makeSettings(servers: [p2], defaultId: p2.id))

        let after = reg.client(for: .general, chatOverride: nil)
        try expect(before === after, "cache identity must survive URL change")
        try expectEqual(after.baseURL.absoluteString, "http://new:5001")
    }

    s.test("updateSettings drops cache entries for removed profiles") {
        let a = ServerProfile(name: "A", baseURL: URL(string: "http://a:5001")!)
        let b = ServerProfile(name: "B", baseURL: URL(string: "http://b:5001")!)
        let reg = KoboldClientRegistry(settings: makeSettings(servers: [a, b], defaultId: a.id, summarizer: b.id))
        let bClient1 = reg.client(for: .summarizer, chatOverride: nil)
        try expectEqual(bClient1.baseURL.absoluteString, "http://b:5001")

        // Remove B and clear the summarizer override.
        reg.updateSettings(makeSettings(servers: [a], defaultId: a.id))

        // Asking for summarizer now falls back to default (A).
        let sumC = reg.client(for: .summarizer, chatOverride: nil)
        try expectEqual(sumC.baseURL.absoluteString, "http://a:5001")
        // And B's cache slot should be reclaimed — looking it up by chatOverride
        // (now invalid) must fall back to default.
        let stale = reg.client(for: .general, chatOverride: b.id)
        try expectEqual(stale.baseURL.absoluteString, "http://a:5001")
    }

    s.test("registry survives empty/corrupt state by minting a localhost client") {
        // Pathological: settings with a defaultServerId that doesn't match any
        // profile, and an empty profile list. Should not crash; should return
        // *something* usable so generation can fail gracefully at the network
        // layer, not at the routing layer.
        var bad = Settings.default
        bad.servers = []
        bad.defaultServerId = UUID()
        let reg = KoboldClientRegistry(settings: bad)
        let c = reg.client(for: .general, chatOverride: nil)
        try expect(c.baseURL.absoluteString.contains("localhost"), "expected localhost fallback, got \(c.baseURL)")
    }

    return s
}
