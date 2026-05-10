import Foundation

/// Selective injection of world-info entries.
///
/// Given the current turn window, returns the entries whose keys appear in
/// the scoped portion of the conversation, ordered by priority (desc, ties
/// broken by name). `.always` entries bypass the key check; `.vectorized`
/// entries are skipped today (deferred to Memory V3).
///
/// Call site (PromptBuilder) is responsible for token-budget truncation
/// using each entry's `tokenCap` and a global cap.
enum WorldInfoInjector {
    static func matchingEntries(
        entries: [WorldInfoEntry],
        turns: [Turn]
    ) -> [WorldInfoEntry] {
        let candidates = entries.filter { $0.enabled && !$0.content.isEmpty }
        let matched = candidates.filter { entry in
            switch entry.injectionMode {
            case .always:
                return true
            case .vectorized:
                return false
            case .keyword:
                return matchesKeyword(entry: entry, turns: turns)
            }
        }
        return matched.sorted { lhs, rhs in
            if lhs.priority != rhs.priority { return lhs.priority > rhs.priority }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    /// Public so callers can render a `[String]` block when needed.
    static func contentBlocks(entries: [WorldInfoEntry], turns: [Turn]) -> [String] {
        matchingEntries(entries: entries, turns: turns).map(\.content)
    }

    // MARK: - Matching internals

    private static func matchesKeyword(entry: WorldInfoEntry, turns: [Turn]) -> Bool {
        let scopeText = scopedText(for: entry.matchScope, turns: turns).lowercased()
        guard !scopeText.isEmpty else { return false }
        guard anyKeyMatches(entry.keys, in: scopeText) else { return false }
        if entry.secondaryKeys.isEmpty { return true }
        return anyKeyMatches(entry.secondaryKeys, in: scopeText)
    }

    private static func scopedText(for scope: WorldInfoMatchScope, turns: [Turn]) -> String {
        switch scope {
        case .recentTurns(let n):
            let window = max(0, n)
            return turns.suffix(window).map(\.text).joined(separator: "\n")
        case .lastUserTurn:
            return turns.reversed().first(where: { $0.role == .user })?.text ?? ""
        case .entireChat:
            return turns.map(\.text).joined(separator: "\n")
        }
    }

    /// Word-boundary, case-insensitive match. Uses Unicode-aware boundary
    /// detection so "sword" doesn't match "swordsmith" but "sword!" does.
    static func anyKeyMatches(_ keys: [String], in lowerText: String) -> Bool {
        for key in keys {
            let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmed.isEmpty { continue }
            if matchesAsWord(needle: trimmed, in: lowerText) { return true }
        }
        return false
    }

    private static func matchesAsWord(needle: String, in lowerText: String) -> Bool {
        var searchStart = lowerText.startIndex
        while let range = lowerText.range(of: needle, range: searchStart..<lowerText.endIndex) {
            let leftOK: Bool = {
                guard range.lowerBound > lowerText.startIndex else { return true }
                let prev = lowerText[lowerText.index(before: range.lowerBound)]
                return !isWordChar(prev)
            }()
            let rightOK: Bool = {
                guard range.upperBound < lowerText.endIndex else { return true }
                let next = lowerText[range.upperBound]
                return !isWordChar(next)
            }()
            if leftOK && rightOK { return true }
            searchStart = lowerText.index(after: range.lowerBound)
        }
        return false
    }

    private static func isWordChar(_ ch: Swift.Character) -> Bool {
        for scalar in ch.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) { return true }
            if scalar == "_" { return true }
        }
        return false
    }
}
