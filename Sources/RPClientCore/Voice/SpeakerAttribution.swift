import Foundation

// `RPClientCore.Character` is the SillyTavern character card model — it
// shadows `Swift.Character` inside this module. Alias the Swift primitive
// so the literals and comparisons below resolve unambiguously.
private typealias Char = Swift.Character

/// How a turn's text is split into per-entity segments for the speaker queue.
/// Phase 6 §7.3. Per-chat (`Chat.attributionMode`); user-pickable in §7.5d.
public enum AttributionMode: String, Codable, Equatable {
    /// Match `"…"` quoted spans to the most-recently-mentioned entity in
    /// surrounding narration. Cheap, requires no model cooperation; works
    /// the moment the user has entities defined.
    case heuristic
    /// Parse `^Name: …` lines against entity names + aliases. Cleaner
    /// attribution when the model follows the convention; falls back to
    /// narrator on untagged or unknown-name lines.
    case tagged
}

/// One contiguous run of text with its attributed entity (or nil for
/// narration). Consumers map `entityId` to a `VoicePreference` via the
/// chat's entity store; nil falls through to the chat-default voice.
public struct AttributedSegment: Equatable {
    public let text: String
    public let entityId: UUID?

    public init(text: String, entityId: UUID?) {
        self.text = text
        self.entityId = entityId
    }
}

/// Pure attribution algorithm — no AppKit, no engine knowledge. Output
/// drives `Speaker.speakSegments(_:)` in §7.4b. Phase 6 §7.3.
///
/// `internal` (not `public`) because `Entity` is internal — the algorithm is
/// only ever called from within `RPClientCore`. Tests use `@testable import`.
enum SpeakerAttribution {
    static func split(
        text: String,
        entities: [Entity],
        mode: AttributionMode
    ) -> [AttributedSegment] {
        switch mode {
        case .heuristic:
            return heuristicSplit(text: text, entities: entities)
        case .tagged:
            return taggedSplit(text: text, entities: entities)
        }
    }

    // MARK: - Heuristic

    /// Walks the text once, splitting on quote boundaries (ASCII `"` or
    /// curly `\u{201C}`/`\u{201D}`). Quoted spans are attributed to the
    /// most-recently-mentioned entity in *all preceding text* (not just
    /// the current paragraph — first-version simplicity; revisit if
    /// long-form drift becomes a problem). Unquoted text is narration.
    /// Unmatched opening quotes degrade to narration so a stray `"`
    /// doesn't blackhole the rest of the turn.
    private static func heuristicSplit(text: String, entities: [Entity]) -> [AttributedSegment] {
        guard !text.isEmpty else { return [] }

        // Lowercase needles for fast contains-check; sort by length descending
        // so multi-word aliases match before bare names ("the mage" before "Sage").
        let needles: [(needle: String, id: UUID)] = entities.flatMap { ent -> [(String, UUID)] in
            ([ent.name] + ent.aliases)
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
                .map { ($0, ent.id) }
        }.sorted { $0.0.count > $1.0.count }

        var segments: [AttributedSegment] = []
        var cursor = text.startIndex
        var inQuote = false
        var quoteOpener: Char = "\""

        // Find the next quote boundary from `cursor`. Returns (index, opener?)
        // where opener is the character we matched.
        func nextQuote(from start: String.Index) -> (String.Index, Char)? {
            var i = start
            while i < text.endIndex {
                let c = text[i]
                if !inQuote {
                    if c == "\"" || c == "\u{201C}" {
                        return (i, c)
                    }
                } else {
                    let closer: Char = (quoteOpener == "\u{201C}") ? "\u{201D}" : "\""
                    if c == closer {
                        return (i, c)
                    }
                }
                i = text.index(after: i)
            }
            return nil
        }

        while cursor < text.endIndex {
            guard let (boundary, char) = nextQuote(from: cursor) else {
                // No more quotes; everything from cursor on is narration.
                let tail = String(text[cursor...])
                if !tail.isEmpty {
                    appendSegment(&segments, text: tail, entityId: nil)
                }
                break
            }
            if !inQuote {
                // Narration up to the opening quote.
                if cursor < boundary {
                    let lead = String(text[cursor..<boundary])
                    appendSegment(&segments, text: lead, entityId: nil)
                }
                // Begin a quoted span. Decide the speaker by looking at
                // narration so far (everything before this quote).
                let leadingText = String(text[..<boundary])
                let speaker = mostRecentMention(in: leadingText, needles: needles)
                // Open a placeholder segment; we'll commit it when we see
                // the close quote (or the end of text — see fallback below).
                inQuote = true
                quoteOpener = char
                cursor = boundary
                // Try to find the close.
                let afterOpen = text.index(after: cursor)
                guard let (closeIdx, _) = nextQuote(from: afterOpen) else {
                    // Unmatched opener — degrade gracefully: emit the rest
                    // as narration so the text round-trips. Speaker stays
                    // narrator since we can't trust the attribution.
                    let rest = String(text[cursor...])
                    appendSegment(&segments, text: rest, entityId: nil)
                    cursor = text.endIndex
                    inQuote = false
                    break
                }
                let closeAfter = text.index(after: closeIdx)
                let quoted = String(text[cursor..<closeAfter])
                appendSegment(&segments, text: quoted, entityId: speaker)
                cursor = closeAfter
                inQuote = false
            }
        }
        return segments
    }

    /// Returns the entity id whose name/alias appears latest in `text`
    /// (or nil if none match).
    private static func mostRecentMention(
        in text: String,
        needles: [(needle: String, id: UUID)]
    ) -> UUID? {
        let lower = text.lowercased()
        var bestEnd: String.Index? = nil
        var bestId: UUID? = nil
        for (needle, id) in needles {
            // Find the *last* occurrence of `needle` in `lower`.
            var searchRange = lower.startIndex..<lower.endIndex
            var found: Range<String.Index>? = nil
            while let r = lower.range(of: needle, options: .literal, range: searchRange) {
                found = r
                searchRange = r.upperBound..<lower.endIndex
            }
            guard let end = found?.upperBound else { continue }
            if bestEnd == nil || end > bestEnd! {
                bestEnd = end
                bestId = id
            }
        }
        return bestId
    }

    private static func appendSegment(
        _ segments: inout [AttributedSegment],
        text: String,
        entityId: UUID?
    ) {
        guard !text.isEmpty else { return }
        // Coalesce adjacent same-speaker segments so the queue plays one
        // utterance per speaker rather than chopping at every quote boundary.
        if let last = segments.last, last.entityId == entityId {
            segments[segments.count - 1] = AttributedSegment(
                text: last.text + text,
                entityId: entityId
            )
        } else {
            segments.append(AttributedSegment(text: text, entityId: entityId))
        }
    }

    // MARK: - Tagged

    /// Line-based parser. Each line is checked for a leading `Name: ` tag;
    /// if the captured name matches an entity name or alias (case-insensitive),
    /// the rest of the line is attributed to that entity. Unmatched names
    /// or untagged lines are narration. The tag itself is preserved in the
    /// segment text so screen readers / debug logs can see the source — the
    /// engine speaks it but the user typically wants to hear the tag too
    /// ("Sage: Hello." reads naturally either way).
    private static func taggedSplit(text: String, entities: [Entity]) -> [AttributedSegment] {
        guard !text.isEmpty else { return [] }

        // Build a name → id table for O(1) lookups.
        var lookup: [String: UUID] = [:]
        for ent in entities {
            lookup[ent.name.trimmingCharacters(in: .whitespaces).lowercased()] = ent.id
            for a in ent.aliases {
                lookup[a.trimmingCharacters(in: .whitespaces).lowercased()] = ent.id
            }
        }

        let lines = text.components(separatedBy: "\n")
        var segments: [AttributedSegment] = []
        for (i, line) in lines.enumerated() {
            let withNewline = (i < lines.count - 1) ? line + "\n" : line
            if let id = matchTag(in: line, lookup: lookup) {
                appendSegment(&segments, text: withNewline, entityId: id)
            } else {
                appendSegment(&segments, text: withNewline, entityId: nil)
            }
        }
        return segments
    }

    /// Matches `^\s*<name>\s*:\s+\S` where `<name>` is one or more letters
    /// (with optional internal spaces, hyphens, apostrophes) and is in
    /// `lookup`. Returns the entity id or nil. The trailing `\S` requires
    /// some content after the colon — empty `"Sage: "` is treated as
    /// narration since there's nothing to speak.
    private static func matchTag(in line: String, lookup: [String: UUID]) -> UUID? {
        // Find the first `:` — if absent, can't be a tag.
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let prefix = line[..<colon]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !prefix.isEmpty else { return nil }
        // Reject prefixes that contain non-name characters (digits, quotes,
        // sentence-ending punctuation that suggests we found a colon mid-line).
        let allowed = CharacterSet.letters
            .union(.whitespaces)
            .union(CharacterSet(charactersIn: "-'"))
        if prefix.unicodeScalars.contains(where: { !allowed.contains($0) }) {
            return nil
        }
        // Require some content after the colon.
        let after = line.index(after: colon)
        let remainder = line[after...].trimmingCharacters(in: .whitespaces)
        guard !remainder.isEmpty else { return nil }
        return lookup[prefix]
    }
}
