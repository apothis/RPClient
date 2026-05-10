import Foundation

/// Two top-level books in the help system. The window's TOC shows pages
/// grouped by book; both render through the same pipeline.
enum HelpBook: String, CaseIterable {
    case userGuide
    case technical

    var title: String {
        switch self {
        case .userGuide: return "User Guide"
        case .technical: return "Technical Reference"
        }
    }
}

/// One help page. The id matches a `.md` filename in `Sources/RPClientCore/Help/`
/// (without extension). Anchors inside a page are derived from heading text at
/// render time — they are not enumerated here.
struct HelpPage: Equatable {
    let id: String
    let title: String
    let book: HelpBook
}

/// Single source of truth for the help system. Adding a page = appending an
/// entry here and creating the matching `.md` file. The TestKit suite
/// `helpIndexTests` asserts every entry resolves to a real, non-empty file.
enum HelpIndex {
    /// Slice 1 ships the skeleton plus the five pages a brand-new user needs
    /// to get from "I just installed this" to "I'm in a chat". Memory pages,
    /// library/settings/troubleshooting, and the technical book follow in
    /// later slices — see [V2_PLAN-style] notes in conversation history.
    static let pages: [HelpPage] = [
        // Slice 1 — onboarding.
        HelpPage(id: "quick-start",   title: "Quick Start",            book: .userGuide),
        HelpPage(id: "chats-sidebar", title: "Chats & sidebar",        book: .userGuide),
        HelpPage(id: "chat-view",     title: "The chat view",          book: .userGuide),
        HelpPage(id: "input-bar",     title: "Input bar & token cap",  book: .userGuide),
        HelpPage(id: "status-bar",    title: "Status bar",             book: .userGuide),
        // Slice 2 — memory subsystem (one page per inspector pane).
        HelpPage(id: "memory-pinned-facts", title: "Memory: pinned facts",     book: .userGuide),
        HelpPage(id: "memory-summary",      title: "Memory: rolling summary",  book: .userGuide),
        HelpPage(id: "memory-authors-note", title: "Memory: author's note",    book: .userGuide),
        HelpPage(id: "memory-world-info",   title: "Memory: world info",       book: .userGuide),
        HelpPage(id: "memory-suggestions",  title: "Memory: suggestions",      book: .userGuide),
        HelpPage(id: "memory-entities",     title: "Memory: entities",         book: .userGuide),
        HelpPage(id: "memory-retrieval",    title: "Memory: retrieval",        book: .userGuide),
        // Slice 4 — long-tail user guide.
        HelpPage(id: "presets",              title: "Sampler presets",         book: .userGuide),
        HelpPage(id: "templates",            title: "Templates: Gemma vs Qwen3", book: .userGuide),
        HelpPage(id: "characters-personas",  title: "Characters & personas",   book: .userGuide),
        HelpPage(id: "library",              title: "Library window",          book: .userGuide),
        HelpPage(id: "multi-server",         title: "Multi-server",            book: .userGuide),
        HelpPage(id: "voices",               title: "Voices",                  book: .userGuide),
        HelpPage(id: "settings",             title: "Settings",                book: .userGuide),
        HelpPage(id: "troubleshooting",      title: "Troubleshooting",         book: .userGuide),
        // Slice 3a — Technical Reference (priority tier).
        HelpPage(id: "tech-architecture",     title: "Architecture overview", book: .technical),
        HelpPage(id: "tech-prompt-assembly",  title: "Prompt assembly",       book: .technical),
        HelpPage(id: "tech-memory-pipeline",  title: "Memory pipeline",       book: .technical),
        // Slice 3b — Technical Reference (tier 2).
        HelpPage(id: "tech-app-state",          title: "AppState & UI wiring",   book: .technical),
        HelpPage(id: "tech-storage",            title: "Storage layer",          book: .technical),
        HelpPage(id: "tech-kobold-client",      title: "KoboldClient & SSE",     book: .technical),
        HelpPage(id: "tech-summarizer",         title: "Summarizer",             book: .technical),
        HelpPage(id: "tech-fact-extractor",     title: "Fact extractor",         book: .technical),
        HelpPage(id: "tech-retrieval",          title: "Retrieval pipeline",     book: .technical),
        HelpPage(id: "tech-world-info-injector", title: "World-info injector",   book: .technical),
        HelpPage(id: "tech-entities",           title: "Entity store",           book: .technical),
        HelpPage(id: "tech-testing",            title: "Testing (TestKit)",      book: .technical),
        // Slice 6 — voices.
        HelpPage(id: "tech-voices",             title: "Voice subsystem",        book: .technical),
    ]

    static func page(id: String) -> HelpPage? {
        pages.first { $0.id == id }
    }

    static func pages(in book: HelpBook) -> [HelpPage] {
        pages.filter { $0.book == book }
    }

    /// Returns the markdown source for a page, or nil if the resource is
    /// missing. Callers are expected to surface a "page not found" UI rather
    /// than crashing — keeps a missing-resource bug discoverable.
    static func markdown(for page: HelpPage) -> String? {
        guard let url = Bundle.module.url(
            forResource: page.id, withExtension: "md", subdirectory: "Help"
        ) else {
            // Fallback: SwiftPM flattens some processed resources depending on
            // platform. Try without the subdirectory before giving up.
            if let url = Bundle.module.url(forResource: page.id, withExtension: "md") {
                return try? String(contentsOf: url, encoding: .utf8)
            }
            return nil
        }
        return try? String(contentsOf: url, encoding: .utf8)
    }
}
