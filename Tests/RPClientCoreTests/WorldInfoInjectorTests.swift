import Foundation
@testable import RPClientCore

func worldInfoInjectorTests() -> TestSuite {
    let s = TestSuite("WorldInfoInjector")

    func turn(_ role: TurnRole, _ text: String) -> Turn {
        Turn(role: role, text: text)
    }

    func entry(
        _ name: String,
        keys: [String],
        content: String? = nil,
        secondaryKeys: [String] = [],
        enabled: Bool = true,
        mode: WorldInfoInjectionMode = .keyword,
        scope: WorldInfoMatchScope = .recentTurns(4),
        priority: Int = 0
    ) -> WorldInfoEntry {
        WorldInfoEntry(
            name: name,
            keys: keys,
            secondaryKeys: secondaryKeys,
            content: content ?? name,
            enabled: enabled,
            injectionMode: mode,
            matchScope: scope,
            priority: priority
        )
    }

    s.test("keyword match — case-insensitive, word-boundary respected") {
        let entries = [
            entry("Mournbringer", keys: ["Mournbringer"], content: "humming blade"),
        ]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "I draw the MOURNBRINGER from its sheath.")]
        )
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].content, "humming blade")
    }

    s.test("word-boundary excludes substring inside a longer word") {
        let entries = [entry("sword", keys: ["sword"], content: "blade lore")]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "The swordsmith was busy.")]
        )
        try expectTrue(hits.isEmpty)
    }

    s.test("punctuation around the key still matches") {
        let entries = [entry("sword", keys: ["sword"], content: "x")]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "He raised the sword!")]
        )
        try expectEqual(hits.count, 1)
    }

    s.test("disabled entry never fires") {
        let entries = [entry("Mournbringer", keys: ["Mournbringer"], enabled: false)]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "Mournbringer hums.")]
        )
        try expectTrue(hits.isEmpty)
    }

    s.test("always mode bypasses key check") {
        let entries = [entry("Lore", keys: ["never appears"], content: "always-on lore", mode: .always)]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "Hello.")]
        )
        try expectEqual(hits.count, 1)
        try expectEqual(hits[0].content, "always-on lore")
    }

    s.test("vectorized mode is skipped today") {
        let entries = [entry("V", keys: ["V"], mode: .vectorized)]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "V is here.")]
        )
        try expectTrue(hits.isEmpty)
    }

    s.test("secondary key AND-gate requires both primary and secondary in scope") {
        let entries = [
            entry("Mournbringer", keys: ["Mournbringer"], content: "x", secondaryKeys: ["sword", "blade"]),
        ]
        let onlyPrimary = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "Mournbringer is here.")]
        )
        try expectTrue(onlyPrimary.isEmpty)

        let both = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "He drew the Mournbringer, that legendary blade.")]
        )
        try expectEqual(both.count, 1)
    }

    s.test("matchScope.recentTurns honours the window") {
        let entries = [entry("Old", keys: ["dragon"], scope: .recentTurns(2))]
        let turns: [Turn] = [
            turn(.user, "There was a dragon here long ago."),
            turn(.assistant, "Indeed."),
            turn(.user, "Now we talk of trees."),
            turn(.assistant, "Trees are nice."),
        ]
        let hits = WorldInfoInjector.matchingEntries(entries: entries, turns: turns)
        try expectTrue(hits.isEmpty, "dragon turn fell out of last-2 window")
    }

    s.test("matchScope.lastUserTurn ignores assistant turns") {
        let entries = [entry("E", keys: ["dragon"], scope: .lastUserTurn)]
        let turns: [Turn] = [
            turn(.user, "Trees today."),
            turn(.assistant, "There is a dragon nearby."),
        ]
        let hits = WorldInfoInjector.matchingEntries(entries: entries, turns: turns)
        try expectTrue(hits.isEmpty, "dragon was only in assistant turn")
    }

    s.test("matchScope.entireChat searches every turn") {
        let entries = [entry("E", keys: ["dragon"], scope: .entireChat)]
        let turns = (0..<20).map { i in
            turn(i.isMultiple(of: 2) ? .user : .assistant, i == 0 ? "dragon mentioned once" : "filler line \(i)")
        }
        let hits = WorldInfoInjector.matchingEntries(entries: entries, turns: turns)
        try expectEqual(hits.count, 1)
    }

    s.test("results sorted by priority desc, then name asc") {
        let entries = [
            entry("zeta", keys: ["x"], priority: 1),
            entry("alpha", keys: ["x"], priority: 5),
            entry("beta", keys: ["x"], priority: 5),
        ]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "x")]
        )
        try expectEqual(hits.map(\.name), ["alpha", "beta", "zeta"])
    }

    s.test("empty content entries are skipped even when keys match") {
        let entries = [entry("E", keys: ["x"], content: "")]
        let hits = WorldInfoInjector.matchingEntries(
            entries: entries,
            turns: [turn(.user, "x is here")]
        )
        try expectTrue(hits.isEmpty)
    }

    return s
}
