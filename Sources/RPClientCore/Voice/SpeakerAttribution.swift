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

    /// Human-readable label for the §7.5d chat-header picker.
    public var displayName: String {
        switch self {
        case .heuristic: return "Heuristic"
        case .tagged: return "Tagged"
        }
    }
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
    /// Split a turn into per-entity segments.
    ///
    /// - Parameter firstPersonEntityId: Hint for who's speaking when the
    ///   surrounding narration uses a word-bounded `I`. In RP this is
    ///   typically the chat's character card resolved to its matching
    ///   entity — the AI's own persona speaking in first person. Nil
    ///   disables first-person handling and the older "most-recently-mentioned
    ///   third-person entity wins" rule applies on its own.
    static func split(
        text: String,
        entities: [Entity],
        mode: AttributionMode,
        firstPersonEntityId: UUID? = nil
    ) -> [AttributedSegment] {
        switch mode {
        case .heuristic:
            return heuristicSplit(
                text: text,
                entities: entities,
                firstPersonEntityId: firstPersonEntityId
            )
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
    ///
    /// First-person handling: if `firstPersonEntityId` is non-nil, the
    /// position of the most-recent word-bounded `I` is compared against
    /// the position of the most-recent entity-name match. Whichever
    /// appears later in the text wins. This catches the common RP shape
    /// `I felt nervous. "Hello."` — without the hint, no third-person
    /// entity has been named, so the quote falls to narrator; with it,
    /// the quote attributes to the chat's character.
    private static func heuristicSplit(
        text: String,
        entities: [Entity],
        firstPersonEntityId: UUID?
    ) -> [AttributedSegment] {
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
                // Begin a quoted span. Decide the speaker.
                inQuote = true
                quoteOpener = char
                cursor = boundary
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
                // Speaker resolution priority:
                //   1. Dialogue-verb subject AFTER the close quote
                //      (`"Hi," Sage said.`) — most explicit.
                //   2. Dialogue-verb subject BEFORE the open quote
                //      (`Sage said, "Hi."`).
                //   3. Most-recent entity / first-person mention in the
                //      preceding text (the pre-Step-1.5 fallback).
                // Pronoun subjects (she/he/they/…) attached to a dialogue
                // verb intentionally fall through so the most-recent rule
                // can do its best with the surrounding context.
                let speaker: UUID? =
                    speakerFromDialogueVerb(
                        afterQuoteAt: closeAfter,
                        in: text,
                        needles: needles,
                        firstPersonEntityId: firstPersonEntityId
                    )
                    ?? speakerFromDialogueVerb(
                        beforeQuoteAt: boundary,
                        in: text,
                        needles: needles,
                        firstPersonEntityId: firstPersonEntityId
                    )
                    ?? mostRecentMention(
                        in: scopedLookback(in: text, before: boundary),
                        needles: needles,
                        firstPersonEntityId: firstPersonEntityId
                    )
                let quoted = String(text[cursor..<closeAfter])
                appendSegment(&segments, text: quoted, entityId: speaker)
                cursor = closeAfter
                inQuote = false
            }
        }
        return segments
    }

    // MARK: - Dialogue-verb subject detection

    /// Common attribution verbs in English RP. Word-bounded match. Kept as
    /// a Set so lookups are O(1); add to it sparingly — false positives on
    /// generic verbs ("walked", "smiled") would mis-attribute lots of
    /// quotes. The list below is intentionally conservative: only words
    /// that almost always introduce direct speech.
    private static let dialogueVerbs: Set<String> = [
        "said", "asked", "replied", "whispered", "murmured", "shouted",
        "exclaimed", "answered", "continued", "added", "cried", "muttered",
        "breathed", "hissed", "sighed", "called", "yelled",
    ]

    /// Pronouns the subject capture might land on. We deliberately don't
    /// resolve these — their referent depends on context the attribution
    /// algorithm doesn't track. Returning nil here lets the caller fall
    /// through to the most-recent-mention rule, which usually does the
    /// right thing.
    private static let speakerPronouns: Set<String> = [
        "she", "he", "they", "we", "you", "it",
    ]

    /// Pattern: `<subject> <verb>` immediately after a closing quote
    /// (allowing one optional comma + whitespace between the quote and
    /// the subject). Returns the resolved entity id when the subject is
    /// `I` (first-person hint), an entity name, or an alias. Pronoun
    /// subjects return nil so the caller falls through.
    private static func speakerFromDialogueVerb(
        afterQuoteAt closeAfter: String.Index,
        in text: String,
        needles: [(needle: String, id: UUID)],
        firstPersonEntityId: UUID?
    ) -> UUID? {
        var i = closeAfter
        let endIdx = text.endIndex
        // Allow one comma and whitespace between the close quote and the
        // subject. Anything else (period, another quote) means there's no
        // dialogue verb attached to this quote.
        if i < endIdx, text[i] == "," { i = text.index(after: i) }
        while i < endIdx, text[i].isWhitespace { i = text.index(after: i) }
        guard i < endIdx else { return nil }

        // First-word short-circuit: if the very first word after the
        // (optional) comma + whitespace is a bare `I`, treat as first-person
        // regardless of what verb (if any) follows. Catches `"...," I begin /
        // murmur / sigh / huff / ...` — the action verbs we'd otherwise need
        // to add to the verb list one-by-one. `I` is unambiguous as a
        // subject (English capitalisation), so the false-positive risk is
        // low.
        let firstWordStart = i
        var firstWordEnd = i
        while firstWordEnd < endIdx, text[firstWordEnd].isLetter {
            firstWordEnd = text.index(after: firstWordEnd)
        }
        let firstWord = String(text[firstWordStart..<firstWordEnd])
        if firstWord == "I" {
            return firstPersonEntityId
        }

        // Otherwise walk forward until a known dialogue verb word-bounded
        // match. Stop at sentence boundaries (`. ! ? \n`) or another quote
        // so we don't grab a verb from the *next* sentence.
        let subjectStart = i
        let lookaheadEnd = text.index(i, offsetBy: 80, limitedBy: endIdx) ?? endIdx
        var verbRange: Range<String.Index>? = nil
        var w = i
        while w < lookaheadEnd {
            let c = text[w]
            if c == "." || c == "?" || c == "!" || c == "\n"
                || c == "\"" || c == "\u{201C}" || c == "\u{201D}" {
                break
            }
            if c.isLetter {
                let wStart = w
                while w < lookaheadEnd, text[w].isLetter { w = text.index(after: w) }
                let candidate = String(text[wStart..<w]).lowercased()
                if dialogueVerbs.contains(candidate) {
                    verbRange = wStart..<w
                    break
                }
            } else {
                w = text.index(after: w)
            }
        }
        guard let verbRange else { return nil }
        let subject = String(text[subjectStart..<verbRange.lowerBound])
            .trimmingCharacters(in: .whitespaces)
        return resolveSubject(
            subject,
            needles: needles,
            firstPersonEntityId: firstPersonEntityId
        )
    }

    /// Pattern: `<subject> <verb>[,:]?\s*` immediately before an opening
    /// quote — `Sage said, "Hello."`. Walks backward from the opening
    /// quote position. Mirror of the post-quote variant.
    private static func speakerFromDialogueVerb(
        beforeQuoteAt openIdx: String.Index,
        in text: String,
        needles: [(needle: String, id: UUID)],
        firstPersonEntityId: UUID?
    ) -> UUID? {
        var i = openIdx
        let startIdx = text.startIndex
        // Skip whitespace
        while i > startIdx, text[text.index(before: i)].isWhitespace { i = text.index(before: i) }
        // Optional comma or colon
        if i > startIdx, let prev = Optional(text.index(before: i)),
           text[prev] == "," || text[prev] == ":" {
            i = prev
            while i > startIdx, text[text.index(before: i)].isWhitespace { i = text.index(before: i) }
        }
        // Capture the verb (a run of letters ending at i).
        let verbEnd = i
        while i > startIdx, text[text.index(before: i)].isLetter { i = text.index(before: i) }
        let verb = String(text[i..<verbEnd]).lowercased()
        guard dialogueVerbs.contains(verb), !verb.isEmpty else { return nil }
        // Skip whitespace before the verb
        while i > startIdx, text[text.index(before: i)].isWhitespace { i = text.index(before: i) }
        // Capture the subject — walk back to the previous sentence boundary
        // (or up to ~80 chars, whichever comes first).
        let subjectEnd = i
        let lookbackLimit = text.index(i, offsetBy: -80, limitedBy: startIdx) ?? startIdx
        while i > lookbackLimit {
            let prev = text.index(before: i)
            let ch = text[prev]
            if ch == "." || ch == "?" || ch == "!" || ch == "\n"
                || ch == "\"" || ch == "\u{201C}" || ch == "\u{201D}" {
                break
            }
            i = prev
        }
        let subject = String(text[i..<subjectEnd])
            .trimmingCharacters(in: .whitespaces)
        return resolveSubject(
            subject,
            needles: needles,
            firstPersonEntityId: firstPersonEntityId
        )
    }

    /// Map a dialogue-verb subject string to an entity id.
    /// - `"I"` (case-sensitive, English capitalisation) → `firstPersonEntityId`.
    /// - Pronouns (`she`, `he`, `they`, …) → nil so the caller falls through.
    /// - Otherwise → first needle whose name/alias matches case-insensitively.
    /// - Subject empty / no match → nil.
    private static func resolveSubject(
        _ subject: String,
        needles: [(needle: String, id: UUID)],
        firstPersonEntityId: UUID?
    ) -> UUID? {
        guard !subject.isEmpty else { return nil }
        if subject == "I" { return firstPersonEntityId }
        let lower = subject.lowercased()
        if speakerPronouns.contains(lower) { return nil }
        for (needle, id) in needles where needle == lower {
            return id
        }
        return nil
    }

    /// Lookback window for the most-recent-mention rule. Without this,
    /// long replies suffer from "first mention wins forever" — the entity
    /// named at the start of a reply keeps outranking any closer signals
    /// because it's the only entity in the preceding text. We cap the
    /// window at the start of the current paragraph (split by `\n\n`) or
    /// the last 200 chars before the quote, whichever is more recent
    /// (i.e. the smaller window).
    private static func scopedLookback(in text: String, before quotePos: String.Index) -> String {
        let leading = text[..<quotePos]
        let total = leading.count
        let charCap = 200
        let charStartOffset = max(0, total - charCap)

        // Find the start of the current paragraph (after the last \n\n).
        var paraStartOffset = 0
        if let r = leading.range(of: "\n\n", options: .backwards) {
            paraStartOffset = leading.distance(from: leading.startIndex, to: r.upperBound)
        }

        // Pick the later (smaller-window) start.
        let startOffset = max(charStartOffset, paraStartOffset)
        guard let start = leading.index(leading.startIndex, offsetBy: startOffset, limitedBy: leading.endIndex)
        else { return String(leading) }
        return String(leading[start...])
    }

    /// Returns the entity id whose name/alias appears latest in `text`
    /// (or `firstPersonEntityId` if a word-bounded `I` appears later than
    /// any third-person entity, or nil if nothing matches).
    private static func mostRecentMention(
        in text: String,
        needles: [(needle: String, id: UUID)],
        firstPersonEntityId: UUID?
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
        // First-person check: word-bounded `I` (case-sensitive — English
        // capitalisation makes this safe and sidesteps "Iron" / "Ireland"
        // false positives that case-insensitive substring search would hit).
        // Compares against the third-person mention end and wins if more
        // recent.
        if let fpId = firstPersonEntityId,
           let fpEnd = lastWordBoundedIEnd(in: text) {
            if bestEnd == nil || fpEnd > bestEnd! {
                return fpId
            }
        }
        return bestId
    }

    /// Returns the end index of the most-recent occurrence of a word-bounded
    /// `I` in `text` — i.e. surrounded by non-letter characters (or string
    /// edges). Other first-person markers ("me", "my", "myself") are
    /// deliberately not included: they're lowercase, much more ambiguous,
    /// and the bare "I" alone catches the common RP shape.
    private static func lastWordBoundedIEnd(in text: String) -> String.Index? {
        var i = text.startIndex
        var lastEnd: String.Index? = nil
        while i < text.endIndex {
            let c = text[i]
            if c == "I" {
                let beforeIsBoundary: Bool
                if i == text.startIndex {
                    beforeIsBoundary = true
                } else {
                    let prev = text[text.index(before: i)]
                    beforeIsBoundary = !prev.isLetter
                }
                let next = text.index(after: i)
                let afterIsBoundary: Bool
                if next == text.endIndex {
                    afterIsBoundary = true
                } else {
                    afterIsBoundary = !text[next].isLetter
                }
                if beforeIsBoundary && afterIsBoundary {
                    lastEnd = next
                }
            }
            i = text.index(after: i)
        }
        return lastEnd
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
