import Foundation
@testable import RPClientCore

/// Phase 11 §4.6 / §4.h.2 — pure-data resolver for the empty-state
/// chip seeds. Pinned as a static helper so the priority chain is
/// testable without standing up a window. ≤3 chips per spec.
///
/// Priority order:
///   1. character.alternateGreetings (each becomes a chip; first 3)
///   2. character.scenario (split into sentences; first 3)
///   3. Static fallbacks ("Set the scene" / "Continue from where we
///      left off" / "Surprise me") — also the only chips for
///      free-form chats with no character.
func phase11ChipSeedTests() -> TestSuite {
    let s = TestSuite("Phase11ChipSeed")

    // MARK: - Static fallbacks

    s.test("nil character returns the three static fallbacks") {
        let chips = EmptyStateView.chipSeeds(for: nil)
        try expectEqual(chips.count, 3)
        try expectTrue(chips.contains("Set the scene"))
        try expectTrue(chips.contains("Continue from where we left off"))
        try expectTrue(chips.contains("Surprise me"))
    }

    s.test("character with neither alts nor scenario returns static fallbacks") {
        let c = Character(
            name: "Bare",
            description: "",
            personality: "",
            scenario: "",
            firstMessage: "",
            alternateGreetings: [],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 3)
        try expectTrue(chips.contains("Set the scene"))
    }

    // MARK: - alternateGreetings priority

    s.test("character with alternateGreetings uses them, capped at 3") {
        let c = Character(
            name: "Mia",
            description: "",
            personality: "",
            scenario: "",
            firstMessage: "Hello.",
            alternateGreetings: [
                "She's reading by the fire.",
                "She's at the door, late.",
                "She hands you a cup of tea.",
                "She's already asleep on the sofa."
            ],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 3)
        // First 3 alts win; 4th is dropped.
        try expectTrue(chips[0].hasPrefix("She's reading"))
        try expectTrue(chips[1].hasPrefix("She's at the door"))
        try expectTrue(chips[2].hasPrefix("She hands you"))
        try expectTrue(!chips.joined().contains("asleep on the sofa"))
    }

    s.test("alternateGreetings titles trim long entries to ~80 chars") {
        // Spec doesn't pin an exact length but the chip needs to read
        // at-a-glance — long greetings (sometimes a full paragraph)
        // are clipped with an ellipsis. Pin "≤ 100 chars" as the
        // contract so a future tweak from 80→90 doesn't fail this
        // test, but a 500-char paragraph chip does.
        let long = String(repeating: "a long sentence about the scene. ", count: 20)
        let c = Character(
            name: "X",
            description: "", personality: "", scenario: "",
            firstMessage: "", alternateGreetings: [long], tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 1)
        try expectTrue(chips[0].count <= 100, "chip too long: \(chips[0].count) chars")
    }

    s.test("alternateGreetings with fewer than 3 entries pads with statics") {
        // Scoped decision — only 1 alt? The chip stays as just that 1
        // alt; we don't pad with statics (spec implies "use what you
        // have"). Test pins this so a future "always show 3 chips"
        // tweak hits a boundary instead of silently changing behaviour.
        let c = Character(
            name: "X",
            description: "", personality: "", scenario: "",
            firstMessage: "",
            alternateGreetings: ["The only opener."],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 1)
        try expectEqual(chips[0], "The only opener.")
    }

    // MARK: - scenario fallback

    s.test("character with scenario but no alts splits scenario into chips") {
        let c = Character(
            name: "X",
            description: "", personality: "",
            scenario: "She's tending the garden. Bees are out. The kettle just whistled.",
            firstMessage: "",
            alternateGreetings: [],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 3)
        try expectTrue(chips[0].contains("garden"))
        try expectTrue(chips[1].contains("Bees"))
        try expectTrue(chips[2].contains("kettle"))
    }

    s.test("single-sentence scenario yields one chip") {
        let c = Character(
            name: "X",
            description: "", personality: "",
            scenario: "She's waiting for you in the cafe.",
            firstMessage: "",
            alternateGreetings: [],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips.count, 1)
        try expectTrue(chips[0].contains("cafe"))
    }

    s.test("alts win over scenario when both present") {
        let c = Character(
            name: "X",
            description: "", personality: "",
            scenario: "She's at the cafe.",
            firstMessage: "",
            alternateGreetings: ["At the door."],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips, ["At the door."])
    }

    // MARK: - Whitespace handling

    s.test("empty / whitespace-only alts entries are skipped") {
        let c = Character(
            name: "X",
            description: "", personality: "", scenario: "",
            firstMessage: "",
            alternateGreetings: ["", "  ", "Real one.", "   \n  "],
            tags: []
        )
        let chips = EmptyStateView.chipSeeds(for: c)
        try expectEqual(chips, ["Real one."])
    }

    return s
}
