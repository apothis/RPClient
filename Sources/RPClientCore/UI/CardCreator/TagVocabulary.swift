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

    /// Case-insensitive prefix match. Sorted alphabetically; capped at 12
    /// results so the dropdown stays scannable.
    func matches(prefix: String) -> [String] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return [] }
        return entries
            .filter { $0.hasPrefix(needle) }
            .sorted()
            .prefix(12)
            .map { $0 }
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
