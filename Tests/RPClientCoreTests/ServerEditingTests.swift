import Foundation
@testable import RPClientCore

func serverEditingTests() -> TestSuite {
    let s = TestSuite("ServerEditing")

    func makeProfile(_ name: String, _ host: String) -> ServerProfile {
        ServerProfile(name: name, baseURL: URL(string: "http://\(host):5001")!)
    }

    func makeSettings(_ profiles: [ServerProfile], defaultIdx: Int = 0) -> Settings {
        var out = Settings.default
        out.servers = profiles
        out.defaultServerId = profiles[defaultIdx].id
        out.summarizerServerId = nil
        out.extractorServerId = nil
        out.embeddingsServerId = nil
        return out
    }

    s.test("canDeleteProfile blocks the default and allows others") {
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        let st = makeSettings([a, b], defaultIdx: 0)
        try expectFalse(ServerEditing.canDeleteProfile(a.id, in: st))
        try expectTrue(ServerEditing.canDeleteProfile(b.id, in: st))
    }

    s.test("rolesAssigned reports every role pointing at a profile") {
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        var st = makeSettings([a, b], defaultIdx: 0)
        st.summarizerServerId = b.id
        st.extractorServerId = b.id
        st.embeddingsServerId = a.id

        let aRoles = Set(ServerEditing.rolesAssigned(to: a.id, in: st))
        let bRoles = Set(ServerEditing.rolesAssigned(to: b.id, in: st))
        try expectEqual(aRoles, Set([.general, .embeddings]))
        try expectEqual(bRoles, Set([.summarizer, .extractor]))
    }

    s.test("assignRole writes the right slot") {
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        var st = makeSettings([a, b], defaultIdx: 0)

        ServerEditing.assignRole(.summarizer, to: b.id, in: &st)
        try expectEqual(st.summarizerServerId, b.id)

        ServerEditing.assignRole(.extractor, to: b.id, in: &st)
        try expectEqual(st.extractorServerId, b.id)

        ServerEditing.assignRole(.embeddings, to: a.id, in: &st)
        try expectEqual(st.embeddingsServerId, a.id)

        // .general writes defaultServerId.
        ServerEditing.assignRole(.general, to: b.id, in: &st)
        try expectEqual(st.defaultServerId, b.id)
    }

    s.test("assignRole(.general, to: nil) is a no-op") {
        // Default can be re-pointed but not cleared — there must always be a
        // fallback. Passing nil for .general should leave it alone.
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        var st = makeSettings([a, b], defaultIdx: 0)
        ServerEditing.assignRole(.general, to: nil, in: &st)
        try expectEqual(st.defaultServerId, a.id)
    }

    s.test("assignRole(.summarizer, to: nil) clears the override") {
        let a = makeProfile("A", "a")
        var st = makeSettings([a], defaultIdx: 0)
        st.summarizerServerId = a.id
        ServerEditing.assignRole(.summarizer, to: nil, in: &st)
        try expectNil(st.summarizerServerId)
    }

    s.test("removeProfile drops the row and clears role overrides pointing at it") {
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        var st = makeSettings([a, b], defaultIdx: 0)
        st.summarizerServerId = b.id
        st.extractorServerId = b.id
        st.embeddingsServerId = a.id

        ServerEditing.removeProfile(b.id, from: &st)
        try expectEqual(st.servers.count, 1)
        try expectEqual(st.servers[0].id, a.id)
        // Role overrides pointing at the removed profile are cleared so the
        // registry's "fall back to default" rule kicks in cleanly.
        try expectNil(st.summarizerServerId)
        try expectNil(st.extractorServerId)
        // Pointed at A — must be untouched.
        try expectEqual(st.embeddingsServerId, a.id)
    }

    s.test("removeProfile is a no-op when the profile is the default") {
        // Belt-and-braces: the UI blocks this via canDeleteProfile, but the
        // model layer should refuse too rather than leave settings dangling.
        let a = makeProfile("A", "a")
        let b = makeProfile("B", "b")
        var st = makeSettings([a, b], defaultIdx: 0)
        ServerEditing.removeProfile(a.id, from: &st)
        try expectEqual(st.servers.count, 2)
        try expectEqual(st.defaultServerId, a.id)
    }

    s.test("validateBaseURL accepts http and https with optional port") {
        _ = try expectNotNil(ServerEditing.validateBaseURL("http://localhost:5001"))
        _ = try expectNotNil(ServerEditing.validateBaseURL("http://192.168.1.50:5001"))
        _ = try expectNotNil(ServerEditing.validateBaseURL("https://kobold.example.com"))
        _ = try expectNotNil(ServerEditing.validateBaseURL("http://kobold-host"))
    }

    s.test("validateBaseURL rejects empty, missing-scheme, and other schemes") {
        try expectNil(ServerEditing.validateBaseURL(""))
        try expectNil(ServerEditing.validateBaseURL("   "))
        try expectNil(ServerEditing.validateBaseURL("localhost:5001"))
        try expectNil(ServerEditing.validateBaseURL("ftp://server"))
        try expectNil(ServerEditing.validateBaseURL("file:///etc/passwd"))
    }

    return s
}

func serverProbeParseTests() -> TestSuite {
    let s = TestSuite("ServerProbeParse")

    func data(_ s: String) -> Data { Data(s.utf8) }

    s.test("parseModel pulls the result string from /api/v1/model") {
        let json = data("{\"result\":\"koboldcpp/llama-3.1-8b-instruct.gguf\"}")
        try expectEqual(ServerProbe.parseModelName(from: json),
                        "koboldcpp/llama-3.1-8b-instruct.gguf")
    }

    s.test("parseModel returns nil on garbage / missing key") {
        try expectNil(ServerProbe.parseModelName(from: data("not json")))
        try expectNil(ServerProbe.parseModelName(from: data("{}")))
        try expectNil(ServerProbe.parseModelName(from: data("{\"result\":42}")))
    }

    s.test("parseVersion reads the version string from /api/extra/version") {
        let json = data("{\"result\":\"1.84.1\",\"version\":\"1.84.1\"}")
        try expectEqual(ServerProbe.parseVersion(from: json), "1.84.1")
    }

    s.test("parseVersion falls back to the `version` key when `result` is missing") {
        let json = data("{\"version\":\"1.85\"}")
        try expectEqual(ServerProbe.parseVersion(from: json), "1.85")
    }

    s.test("parseTrueMaxContext reads the value field") {
        let json = data("{\"value\":16384}")
        try expectEqual(ServerProbe.parseTrueMaxContext(from: json), 16384)
    }

    s.test("parseTrueMaxContext returns nil on missing/garbage") {
        try expectNil(ServerProbe.parseTrueMaxContext(from: data("{}")))
        try expectNil(ServerProbe.parseTrueMaxContext(from: data("not json")))
    }

    return s
}
