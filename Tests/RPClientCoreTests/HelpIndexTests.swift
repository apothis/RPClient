import Foundation
@testable import RPClientCore

func helpIndexTests() -> TestSuite {
    let s = TestSuite("HelpIndex")

    s.test("every registered page resolves to a non-empty markdown resource") {
        try expectGreaterThan(HelpIndex.pages.count, 0)
        for page in HelpIndex.pages {
            let md = HelpIndex.markdown(for: page)
            let unwrapped = try expectNotNil(md, file: #file, line: #line)
            try expectGreaterThan(unwrapped.count, 0)
        }
    }

    s.test("page ids are unique") {
        let ids = HelpIndex.pages.map { $0.id }
        try expectEqual(ids.count, Set(ids).count)
    }

    s.test("renderer emits an anchor for every heading") {
        for page in HelpIndex.pages {
            let md = try expectNotNil(HelpIndex.markdown(for: page))
            let result = HelpRenderer.render(md)
            // Every page should at least define a top-level H1; if not, the
            // page-loaded anchor map will be empty and deep-linking from
            // panes (Slice 2) won't work.
            try expectGreaterThan(result.anchors.count, 0)
            // Rendered output is non-empty.
            try expectGreaterThan(result.attributed.length, 0)
        }
    }

    s.test("slugify produces stable lowercase-hyphen slugs") {
        try expectEqual(HelpRenderer.slugify("Quick start"), "quick-start")
        try expectEqual(HelpRenderer.slugify("The chat view"), "the-chat-view")
        try expectEqual(HelpRenderer.slugify("Per-reply token cap"), "per-reply-token-cap")
        try expectEqual(HelpRenderer.slugify("  weird  spacing!! "), "weird-spacing")
    }

    // V8 (multi-server) shipped after the help system did, so several pages
    // need updates. These cases assert the load-bearing concepts appear
    // somewhere in the relevant pages — they catch staleness when a new
    // subsystem lands and the docs haven't been pulled along.
    //
    // The substrings are deliberately load-bearing: a page that mentions
    // "KoboldClientRegistry" by name is talking about the V8 architecture;
    // a page that doesn't is documenting the pre-V8 world.
    s.test("multi-server user guide page exists") {
        let page = HelpIndex.page(id: "multi-server")
        try expectTrue(page != nil, "multi-server page not registered in HelpIndex")
    }

    s.test("multi-server page covers the load-bearing concepts") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "multi-server") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.contains("registry") || md.contains("Registry"),
            "multi-server page should explain the registry concept")
        try expectTrue(md.lowercased().contains("per-chat"),
            "multi-server page should mention per-chat server pinning")
        try expectTrue(md.lowercased().contains("role"),
            "multi-server page should mention side-call role routing")
    }

    s.test("settings page documents the Servers section") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "settings") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.contains("Servers"),
            "settings.md should document the Settings → Servers section after V8")
    }

    s.test("troubleshooting page covers multi-server scenarios") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "troubleshooting") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.lowercased().contains("server")
            && (md.contains("default") || md.contains("which server") || md.contains("per-chat")),
            "troubleshooting.md should acknowledge multi-server when diagnosing reachability")
    }

    s.test("tech-architecture mentions the client registry") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "tech-architecture") ?? HelpPage(id: "_", title: "_", book: .technical)))
        try expectTrue(md.contains("KoboldClientRegistry") || md.contains("client registry"),
            "tech-architecture should mention the client registry post-V8")
    }

    s.test("tech-kobold-client describes the registry and role routing") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "tech-kobold-client") ?? HelpPage(id: "_", title: "_", book: .technical)))
        try expectTrue(md.contains("KoboldClientRegistry"),
            "tech-kobold-client should name the KoboldClientRegistry")
        try expectTrue(md.contains("ServerRole") || md.lowercased().contains("role routing"),
            "tech-kobold-client should describe role routing")
    }

    s.test("tech-app-state mentions the registry ownership") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "tech-app-state") ?? HelpPage(id: "_", title: "_", book: .technical)))
        try expectTrue(md.contains("KoboldClientRegistry") || md.contains("client registry"),
            "tech-app-state should describe AppState's registry ownership")
    }

    // Phase 5 (V10 avatars) + Phase 6 (V6 voices) shipped after Slice 5.
    // Avatars are small and fold into existing pages; voices are large
    // enough to warrant their own user-guide + tech pages.
    s.test("voices user guide page exists") {
        try expectTrue(HelpIndex.page(id: "voices") != nil,
            "voices page not registered in HelpIndex")
    }

    s.test("voices page covers the load-bearing concepts") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "voices") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.contains("Kokoro"),
            "voices page should name the Kokoro engine")
        try expectTrue(md.contains("espeak-ng"),
            "voices page should mention the espeak-ng prerequisite")
        try expectTrue(md.contains("voice library") || md.contains("Voice library"),
            "voices page should describe the voice library window")
        try expectTrue(md.lowercased().contains("subsystem")
            && (md.contains("two-tier") || md.lowercased().contains("active")),
            "voices page should explain the two-tier toggle (subsystem vs runtime)")
    }

    s.test("tech-voices page exists") {
        try expectTrue(HelpIndex.page(id: "tech-voices") != nil,
            "tech-voices page not registered in HelpIndex")
    }

    s.test("tech-voices describes the Kokoro pipeline") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "tech-voices") ?? HelpPage(id: "_", title: "_", book: .technical)))
        try expectTrue(md.contains("RPClientVoice"),
            "tech-voices should name the RPClientVoice target")
        try expectTrue(md.contains("KokoroEngine"),
            "tech-voices should describe KokoroEngine")
        try expectTrue(md.contains("ONNX") || md.contains("onnxruntime"),
            "tech-voices should mention the ONNX Runtime dependency")
        try expectTrue(md.contains("KokoroTokenizer") || md.contains("EspeakNgClient"),
            "tech-voices should describe the espeak → tokenizer pipeline")
    }

    s.test("settings page documents the voice subsystem") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "settings") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.contains("voice subsystem") || md.contains("Voice storage"),
            "settings.md should document the voice subsystem fields")
    }

    s.test("troubleshooting page mentions espeak-ng failures") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "troubleshooting") ?? HelpPage(id: "_", title: "_", book: .userGuide)))
        try expectTrue(md.contains("espeak-ng"),
            "troubleshooting.md should cover the espeak-ng dependency for voices")
    }

    s.test("tech-architecture lists the RPClientVoice target") {
        let md = try expectNotNil(HelpIndex.markdown(for:
            HelpIndex.page(id: "tech-architecture") ?? HelpPage(id: "_", title: "_", book: .technical)))
        try expectTrue(md.contains("RPClientVoice"),
            "tech-architecture should list the RPClientVoice target")
    }

    // Inspector pane "?" buttons reference page ids by string. A typo here
    // wouldn't fail to compile; this assertion catches it at test time
    // before the user sees a "Page not found" page.
    s.test("inspector pane help refs all resolve") {
        let paneRefs: [String] = [
            "memory-pinned-facts",  // MemoryPane
            "memory-summary",       // SummaryPane
            "memory-authors-note",  // AuthorsNotePane
            "memory-world-info",    // WorldInfoPane
            "memory-suggestions",   // SuggestionsPane + ExtractionPane
            "memory-entities",      // EntitiesPane
            "memory-retrieval",     // RetrievalPane
        ]
        for ref in paneRefs {
            try expectTrue(HelpIndex.page(id: ref) != nil,
                "pane help id '\(ref)' not registered in HelpIndex")
        }
    }

    return s
}
