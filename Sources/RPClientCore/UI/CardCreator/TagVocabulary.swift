import Foundation

/// Phase 9 §5.3a — bundled tag autocomplete vocabulary for the Card Creator's
/// Identity tab token field. Hand-curated common-set per
/// V2_PHASE9_CARD_CREATOR §3.3 — structural / genre / tone / dynamics / roles
/// / settings / appearance / NSFW / misc. Freeform input falls through, so
/// authors typing niche tags don't fight the autocomplete; this list is a
/// **convenience**, not a gate.
///
/// Long-tail / chub-style discovery autocomplete (1000+ niche kink tags) is
/// deferred per V2_PHASE9_CARD_CREATOR §6 — likely network-fetched when it
/// pairs with a future Library facet-browse feature.
final class TagVocabulary {

    static let shared = TagVocabulary()

    private let entries: [String]

    private init() {
        self.entries = TagVocabulary.bundled
    }

    /// Case-insensitive prefix match across the union of bundled common-set
    /// + the caller-supplied custom tags (Phase 9 §3.8). Sorted
    /// alphabetically, deduplicated case-insensitively (custom tags
    /// matching a bundled entry don't appear twice), capped at 12 so the
    /// dropdown stays scannable.
    ///
    /// Production callers pass `AppState.shared.settings.customTags`. Tests
    /// pass an explicit list.
    func matches(prefix: String, customTags: [String] = []) -> [String] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        var seen = Set<String>()
        var results: [String] = []
        for entry in entries where entry.hasPrefix(needle) {
            if seen.insert(entry).inserted { results.append(entry) }
        }
        for raw in customTags {
            let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty, normalized.hasPrefix(needle) else { continue }
            if seen.insert(normalized).inserted { results.append(normalized) }
        }
        return Array(results.sorted().prefix(12))
    }

    /// Autocomplete candidate list for an NSTokenField. Wraps `matches`
    /// with one critical UX correction: when the user's literal input
    /// is a strict prefix of an existing tag (e.g. typing "fem" while
    /// "female" is in the vocab), `matches` returns ["female"] only —
    /// and NSTokenField then commits "female" on `,` / `Tab`, with no
    /// way to add "fem" as a novel tag.
    ///
    /// Fix: prepend the user's literal substring (lowercased) when it
    /// isn't already in the matched list. The literal becomes the
    /// first/highlighted item in the dropdown so a plain comma commits
    /// it as a novel tag; the user reaches the longer matches via
    /// arrow-down. When `matches` is empty we return an empty list so
    /// no dropdown appears (NSTokenField commits the literal directly).
    public func autocompleteCandidates(for substring: String, customTags: [String] = []) -> [String] {
        let needle = substring.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return [] }
        let matched = matches(prefix: substring, customTags: customTags)
        if matched.isEmpty { return [] }
        if matched.contains(where: { $0.lowercased() == needle }) {
            return matched
        }
        return [needle] + matched
    }

    /// Decide whether a freshly-committed tag should be appended to
    /// `Settings.customTags`. Returns the new full custom-tags list (with
    /// the lowercased + trimmed tag appended) when the input is novel
    /// against bundled + existing custom; returns nil when the tag is
    /// already known, blank, or whitespace-only.
    ///
    /// Caller (IdentityTabViewController) writes the returned list back
    /// into `Settings.customTags` and calls `AppState.saveSettings(_:)`.
    func addIfNovel(_ tag: String, customTags: [String]) -> [String]? {
        let normalized = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return nil }
        // Case-insensitive membership check across both lists.
        if entries.contains(where: { $0.lowercased() == normalized }) { return nil }
        if customTags.contains(where: { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalized }) { return nil }
        return customTags + [normalized]
    }

    /// Public for tests + future surfacing as a "browse all tags" sheet.
    var all: [String] { entries }

    /// Hand-curated common-set. Lowercase, hyphen-separated, stable across
    /// updates. Adding entries: keep them broad; long-tail goes to the
    /// future discovery list, not here.
    private static let bundled: [String] = [
        // Structural / character type
        "male", "female", "nonbinary", "futa", "transmasc", "transfemme",
        "monstergirl", "monsterboy", "anthro", "robot", "ai", "alien",
        "vampire", "werewolf", "demon", "angel", "ghost", "dragon", "elf",
        "dwarf", "orc", "human",

        // Genre
        "fantasy", "scifi", "modern", "historical", "cyberpunk", "steampunk",
        "postapoc", "horror", "slice-of-life", "isekai", "mythology",
        "urban-fantasy", "dystopian", "noir", "western",

        // Tone
        "wholesome", "dark", "comedy", "drama", "slow-burn", "melancholic",
        "hopeful", "gritty", "fluffy", "angst", "romance", "friendship",
        "tragedy", "lighthearted",

        // Dynamics
        "dom", "sub", "switch", "mommy", "daddy", "master", "slave",
        "mentor", "rival", "friend", "enemies-to-lovers", "found-family",
        "royalty", "commoner", "stranger", "ex", "boss", "subordinate",
        "tsundere", "yandere", "kuudere", "dandere", "pet", "owner",

        // Roles / profession
        "warrior", "mage", "rogue", "healer", "scholar", "captain", "soldier",
        "detective", "courier", "archer", "knight", "assassin", "noble",
        "outlaw", "prophet", "oracle", "courtesan", "gladiator", "pirate",
        "smuggler", "merchant", "blacksmith", "innkeeper", "barmaid",
        "professor", "student", "doctor", "nurse", "engineer",

        // Settings / location
        "tavern", "castle", "ship", "dungeon", "forest", "desert", "city",
        "station", "lab", "school", "office", "home", "cabin", "manor",
        "ruins", "temple", "battlefield", "marketplace",

        // Appearance traits
        "tall", "short", "muscular", "slim", "curvy", "scarred", "tattooed",
        "robed", "armored", "casual", "elegant",

        // NSFW posture
        "nsfw", "sfw", "smut", "suggestive", "explicit", "vanilla", "kinky",
        "taboo", "consensual", "dub-con",

        // Misc
        "assistant", "companion", "romantic-interest", "antagonist",
        "protagonist", "side-character", "npc",
    ]
}
