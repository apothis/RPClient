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
