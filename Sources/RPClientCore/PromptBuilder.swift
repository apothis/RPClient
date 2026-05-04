import Foundation

/// Assembles the final prompt sent to koboldcpp.
///
/// **Cache-friendly layout contract** (see MEMORY_RESEARCH.md §9.10).
/// The prompt is structured top-to-bottom so that frequently-changing
/// content lives below a notional "cache boundary" — keeping the prefix
/// stable across turns lets KoboldCpp's Context Shifting + SmartCache
/// reuse KV state and skip prefill (~10–30× faster TTFT on long prompts).
///
/// ```text
///   [stable above the boundary — invalidate sparingly]
///     1. system prompt (immutable per session)
///     2. style block            (V2 — §9.8)
///     3. pinned-fact memory     (rare edits)
///     4. rolling summary        (between-turn updates only)
///     5. scene summaries        (§9.2 — append-only via "Scene break")
///     6. older verbatim turns
///   ─── cache boundary ───────────────────────────────────
///   [recomputed each turn — anything below this point is cheap to change]
///     7. vector retrieval block (V2 — §9.1)
///     8. entity block (V2 — Step C: selective, on-stage entities only)
///     9. recent verbatim turns
///    10. author's note(s) at depth ≥ 1
///    11. tail memory reinforcement (§9.6 — opt-in per chat)
///    12. new user turn
/// ```
///
/// Today we have items 1, 3, 4, 6, 7, 8, 9, 10, 11. The numbered slots are
/// kept so future features land in cache-friendly positions.
struct PromptBuilder {

    // MARK: nested helper used by templates

    /// Renders the scene-summary block that lives in the preamble. Frames each
    /// entry as a *completed prior arc* (with its turn range when known) so
    /// the model doesn't read a vivid stale description as the active scene.
    /// See MEMORY_AUDIT §4.1-B / §4.3-D.
    enum SceneSummaryFormatter {
        /// Default staleness threshold: a scene summary whose covered period
        /// ends more than this many verbatim turns behind the current head
        /// gets compressed to a one-sentence headline. Empirically tuned —
        /// the 2026-05-03 failure case had a scene 13 turns behind, and
        /// `staleAge: 8` is enough to catch it without compressing scenes
        /// the user is actively still in.
        static let defaultStalenessThreshold = 8

        static func renderBlock(_ scenes: [SceneSummary]) -> String {
            scenes.enumerated().map { i, scene in
                renderEntry(scene, index: i)
            }.joined(separator: "\n\n")
        }

        static func renderEntry(_ scene: SceneSummary, index: Int) -> String {
            let header: String
            if let first = scene.firstTurn, let last = scene.lastTurn, last >= first {
                header = "[Earlier in the story — completed arc \(index + 1), turns \(first)–\(last)]"
            } else {
                header = "[Earlier in the story — completed arc \(index + 1)]"
            }
            return "\(header)\n\(scene.text)"
        }

        /// Compress a long scene-summary body to a short headline the model
        /// can use as a continuity reference without being pulled back to the
        /// prior setting by sheer prose weight. Strategy: take up to the
        /// first **clause break** (comma, semicolon, sentence terminator)
        /// within an 80-char cap so even compound first sentences get their
        /// interior detail stripped. Word-aligned fallback if no break is
        /// found inside the cap.
        static func compact(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return trimmed }
            let capCount = min(80, trimmed.count)
            let cap = trimmed.index(trimmed.startIndex, offsetBy: capCount)
            let segment = trimmed[..<cap]
            let breakers: Set<Swift.Character> = [",", ";", ".", "!", "?", ":"]
            var body: String
            if let cut = segment.firstIndex(where: { breakers.contains($0) }) {
                body = String(trimmed[..<cut])
            } else if capCount < trimmed.count, let lastSpace = segment.lastIndex(of: " ") {
                body = String(trimmed[..<lastSpace])
            } else {
                body = String(segment)
            }
            // Drop trailing punctuation/whitespace so the suffix reads cleanly.
            while let last = body.last, last.isWhitespace || breakers.contains(last) {
                body.removeLast()
            }
            if body.count < trimmed.count {
                return body + "… […earlier scene compressed; refer back only for continuity.]"
            }
            return body
        }
    }

    /// Apply per-entry staleness compression to the chat's scene summaries
    /// before they reach the templates. A scene whose covered range ended
    /// more than `staleAge` verbatim turns ago — or whose markers are nil
    /// (legacy entries that, by definition, predate any turn that knew about
    /// markers) — is rendered with only its first sentence so its prose
    /// weight can't out-pull the recent verbatim turns. See MEMORY_AUDIT
    /// §4.3-D and the 2026-05-03 empirical failure where the v3-shipped
    /// reframing alone wasn't enough.
    static func renderableScenes(chat: Chat, staleAge: Int = SceneSummaryFormatter.defaultStalenessThreshold) -> [SceneSummary] {
        let head = chat.turns.count
        return chat.sceneSummaries.map { scene in
            let isStale: Bool = {
                guard let last = scene.lastTurn else { return true }
                return (head - last - 1) > staleAge
            }()
            guard isStale else { return scene }
            var compressed = scene
            compressed.text = SceneSummaryFormatter.compact(scene.text)
            return compressed
        }
    }

    /// Returns the slice of turns sent to the model verbatim — i.e. the ones
    /// past whatever has been folded into the rolling summary.
    /// If the summary is empty, ignore `summarizedThrough` and return all turns —
    /// this self-heals chats where a side-call advanced the index but produced
    /// no summary content (otherwise those turns would silently vanish from the prompt).
    ///
    /// A trailing **empty** assistant turn is dropped: that turn is the UI's
    /// stream target (added by `sendUserMessage` / `regenerate`), not a
    /// historical reply. Including it renders an empty
    /// `<start_of_turn>model\n<end_of_turn>\n` block right before the
    /// generation marker, which the model pattern-matches and continues by
    /// emitting another empty turn — particularly visible on fresh chats
    /// where there's no prior non-empty assistant content to outweigh the
    /// signal. See `Templates` continuation flag for the resume case (where
    /// the trailing assistant is non-empty and intentionally left open).
    static func verbatimTurns(_ chat: Chat) -> [Turn] {
        let raw: [Turn] = {
            if chat.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return chat.turns
            }
            let start = max(0, min(chat.summarizedThrough, chat.turns.count))
            return Array(chat.turns[start...])
        }()
        if let last = raw.last, last.role == .assistant, last.text.isEmpty {
            return Array(raw.dropLast())
        }
        return raw
    }

    /// `character` / `persona` are looked up by the caller from `AppState` and
    /// passed in rather than fetched here so `PromptBuilder` stays a pure
    /// function of its inputs (testable without AppState). Both default to
    /// nil for the free-form chat path. Step 4a plumbs them through; later
    /// sub-steps consume them.
    static func build(chat: Chat, character: Character? = nil, persona: Persona? = nil, relevantMemories: String? = nil, continuation: Bool = false, qwenThinking: Bool = false) -> (prompt: String, stops: [String]) {
        _ = persona
        let memoryBlock = composeMemoryBlock(chat: chat, character: character, userName: "")
        let template = Templates.byId(chat.templateId, qwenThinking: qwenThinking)
        let prompt = template.assemble(
            memoryBlock: memoryBlock,
            entitiesBlock: entitiesBlock(chat: chat),
            sceneSummaries: renderableScenes(chat: chat),
            summary: chat.summary.isEmpty ? nil : chat.summary,
            worldInfoHits: worldInfoHits(chat: chat),
            authorsNote: effectiveAuthorsNote(chat: chat, character: character),
            relevantMemories: relevantMemories,
            tailMemoryDigest: tailMemoryDigest(chat: chat, continuation: continuation),
            currentSceneAnchor: currentSceneAnchor(chat: chat, continuation: continuation),
            turns: verbatimTurns(chat),
            continuation: continuation
        )
        return (prompt, template.stopSequences)
    }

    /// Header on the read-only "from card" block (description + personality +
    /// scenario). Plain-prose framing — same pattern as `worldInfoHeader` and
    /// the entities block — so the model treats it as a private reference
    /// card rather than a heading to restate verbatim.
    ///
    /// The trailing nuance about Scenario exists because v2 cards bundle
    /// `scenario` (a static default opening) with `alternate_greetings`
    /// (sibling openings). When the user swipes to an alt that disagrees
    /// with the scenario, the model otherwise leans on the system-block
    /// scenario over the recent assistant turn — putting Marin on the
    /// quarterdeck when the active greeting placed her in her cabin. This
    /// hint defuses that conflict without dropping the field. See V2_PLAN §4.4.
    static let cardPrefixHeader = "(Character card — reference details for continuity. Use silently; do not restate, quote, or copy these lines into your reply. The Scenario below describes the default opening; defer to the most recent turns for the current scene.)"

    /// Compose the memory-block string the templates see at the top of the
    /// prompt (slot 1/3 of the cache-friendly layout). Pure function of its
    /// inputs so both `PromptBuilder.build` (test path) and
    /// `TokenBudget.assemble` (production) can share it.
    ///
    /// Layering, top-to-bottom, when each piece is non-empty:
    /// 1. `character.systemPrompt` — directive at the top.
    /// 2. `userName` line — "The user's name is X."
    /// 3. `[from card]` block — description / personality / scenario,
    ///    each on their own line under a single header.
    /// 4. `chat.memory` — user-editable notes. **Suppressed** when
    ///    `chat.systemPromptMode == .override` AND `character.systemPrompt`
    ///    is non-empty (the override is *of chat memory*, not of the card
    ///    biographical prefix). In `.merge` mode, both ride together.
    ///
    /// Returns nil when nothing would be emitted, so callers can pass that
    /// through to the templates' `memoryBlock: String?` slot unchanged.
    static func composeMemoryBlock(chat: Chat, character: Character?, userName: String) -> String? {
        let trimmedName = userName.trimmingCharacters(in: .whitespacesAndNewlines)
        var sections: [String] = []

        if let c = character, let sp = c.systemPrompt?.trimmingCharacters(in: .whitespacesAndNewlines), !sp.isEmpty {
            sections.append(sp)
        }
        if !trimmedName.isEmpty {
            sections.append("The user's name is \(trimmedName).")
        }
        if let c = character {
            let cardPrefix = renderCardPrefix(c)
            if !cardPrefix.isEmpty {
                sections.append(cardPrefix)
            }
        }

        // Decide whether to include the user-editable chat memory. The toggle
        // only matters when the card actually carried a system_prompt — with
        // no system_prompt there's nothing to "override" and chat.memory rides
        // through regardless of mode.
        let cardHasSystemPrompt: Bool = {
            guard let sp = character?.systemPrompt else { return false }
            return !sp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }()
        let suppressUserMemory = cardHasSystemPrompt && chat.systemPromptMode == .override
        if !suppressUserMemory {
            let mem = chat.memory.trimmingCharacters(in: .whitespacesAndNewlines)
            if !mem.isEmpty {
                sections.append(chat.memory)
            }
        }

        if sections.isEmpty { return nil }
        return sections.joined(separator: "\n\n")
    }

    /// Pick the effective author's note for the prompt. User-set notes always
    /// win — only when `chat.authorsNote.text` is empty do we fall back to
    /// the card's `postHistoryInstructions`. The synthesized note inherits
    /// the chat's existing depth so a user can still tune position without
    /// having to type a note. Returns `nil` when there's nothing to inject,
    /// matching what the templates expect.
    static func effectiveAuthorsNote(chat: Chat, character: Character?) -> AuthorsNote? {
        let userText = chat.authorsNote.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !userText.isEmpty {
            return chat.authorsNote
        }
        guard let phi = character?.postHistoryInstructions?
            .trimmingCharacters(in: .whitespacesAndNewlines), !phi.isEmpty
        else {
            return nil
        }
        return AuthorsNote(text: phi, depth: chat.authorsNote.depth)
    }

    /// Render the read-only `[from card]` biographical prefix
    /// (description / personality / scenario). Returns "" when all three are
    /// blank so the caller can drop the section entirely. Empty fields are
    /// omitted individually so a card with only a description doesn't render
    /// stray blank lines.
    static func renderCardPrefix(_ c: Character) -> String {
        let pieces: [(String, String)] = [
            ("Description", c.description),
            ("Personality", c.personality),
            ("Scenario", c.scenario),
        ]
        let body = pieces
            .map { ($0.0, $0.1.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.1.isEmpty }
            .map { "\($0.0): \($0.1)" }
            .joined(separator: "\n")
        if body.isEmpty { return "" }
        return cardPrefixHeader + "\n" + body
    }

    /// Framing line that prefixes the world-info block. Same pattern as the
    /// entities block: an imperative aside framed in plain prose so the model
    /// treats the body as a private reference rather than something to
    /// restate verbatim.
    static let worldInfoHeader = "(World info — background facts about this setting and its inhabitants. Use these silently for continuity; do not restate, quote, or copy them into your reply.)"

    /// Selective world-info injection. Runs the injector against the chat's
    /// verbatim turn window and returns the framing header followed by each
    /// matched entry's `content` (labelled `[name]`) truncated to roughly
    /// `tokenCap * charsPerToken` characters at a word boundary. Order
    /// matches the injector (priority desc, then name).
    /// See V2_PLAN.md §2.2.
    static func worldInfoHits(chat: Chat, charsPerToken: Int = 4) -> [String] {
        let matched = WorldInfoInjector.matchingEntries(
            entries: chat.worldInfo,
            turns: chat.turns
        )
        guard !matched.isEmpty else { return [] }
        var out: [String] = [worldInfoHeader]
        for entry in matched {
            let body = truncateToCharCap(entry.content, capChars: max(0, entry.tokenCap) * charsPerToken)
            if body.isEmpty { continue }
            let label = entry.name.isEmpty ? "Untitled" : entry.name
            out.append("[\(label)]\n\(body)")
        }
        // If every match's content was empty after truncation, drop the
        // header too — emitting a lone framing line with no body underneath
        // is worse than emitting nothing.
        return out.count > 1 ? out : []
    }

    /// Word-aligned hard truncate. If the text is already within the cap,
    /// returns it unchanged; otherwise drops at the last whitespace inside
    /// the cap and appends an ellipsis. A `capChars` of 0 returns "".
    static func truncateToCharCap(_ text: String, capChars: Int) -> String {
        if capChars <= 0 { return "" }
        if text.count <= capChars { return text }
        let cap = text.index(text.startIndex, offsetBy: capChars)
        let head = text[..<cap]
        if let lastSpace = head.lastIndex(where: { $0.isWhitespace }) {
            return String(text[..<lastSpace]) + "…"
        }
        return String(head) + "…"
    }

    /// Tiny "the recent turns are authoritative" nudge injected at the very
    /// end of the last user turn — closest possible position to the assistant
    /// generation marker. Counters the failure mode where a vivid completed-
    /// arc scene summary in the preamble out-weighs the actual recent
    /// verbatim turns. See MEMORY_AUDIT §2.1 / §4.1-C.
    ///
    /// Returns `nil` (so the existing prompt shape is unchanged) when there
    /// are no scene summaries to disambiguate against, when the chat has no
    /// verbatim turns yet, or in continuation mode (the assistant turn is
    /// mid-stream, no user turn to attach to).
    static func currentSceneAnchor(chat: Chat, continuation: Bool = false) -> String? {
        guard !continuation else { return nil }
        guard !chat.sceneSummaries.isEmpty else { return nil }
        guard !verbatimTurns(chat).isEmpty else { return nil }
        return """
        [Current scene — read this as the source of truth]
        Continue the story from exactly where the most recent turns above leave off. Stay in the location, situation, and physical state that those turns establish. The earlier-arc summaries near the top of this prompt describe events that have already happened — do not restart, revisit, or relocate the scene back to those settings.
        """
    }

    /// Selective entity injection — emit only entities whose name or any alias
    /// appears in the most recent K turns. Output is attached to the LAST
    /// user turn (alongside retrieval), i.e. **below the cache boundary**, so
    /// turn-to-turn changes in the on-stage cast don't invalidate the prefill
    /// prefix. The prompt-builder injects this at the same depth as
    /// `relevantMemories` and `tailMemoryDigest`. See MEMORY_V2_PLAN.md
    /// "Step C — Entity store".
    ///
    /// - `recentTurns`: how many trailing turns (any role) to scan for mentions.
    /// - `maxChars`: hard cap on the rendered block. When over budget, entities
    ///   evict by salience: pinned entities never drop; among non-pinned,
    ///   lowest max `(lastReinforcedTurn, mentionCount, addedTurn)` drops first.
    ///   Within each rendered entity, facts are ordered by the same salience
    ///   key so the model sees the freshest details first.
    static func entitiesBlock(chat: Chat, recentTurns: Int = 6, maxChars: Int = 600) -> String? {
        let entities = chat.entities
        guard !entities.isEmpty else { return nil }
        let recent = chat.turns.suffix(recentTurns)
        guard !recent.isEmpty else { return nil }
        let lowerText = recent.map { $0.text }.joined(separator: "\n").lowercased()
        guard !lowerText.isEmpty else { return nil }

        var hits: [Entity] = []
        for var ent in entities where ent.mentioned(in: lowerText) {
            // Collapse contradictory transient facts on the same entity (e.g.
            // "Sarah is topless" → "Sarah is naked") before they reach the
            // model. Storage is untouched — the user can still see history
            // in the Entities pane. See MEMORY_AUDIT §4.3-E.
            ent.facts = supersedeStaleFactsByTopic(ent.facts)
            hits.append(ent)
        }
        guard !hits.isEmpty else { return nil }

        // Sort each hit's facts by salience: pinned first, then most-recently-
        // reinforced, then most-mentioned, then earliest-added (stable).
        for i in hits.indices {
            hits[i].facts.sort { lhs, rhs in
                if lhs.pinnedByUser != rhs.pinnedByUser { return lhs.pinnedByUser }
                if lhs.lastReinforcedTurn != rhs.lastReinforcedTurn {
                    return lhs.lastReinforcedTurn > rhs.lastReinforcedTurn
                }
                if lhs.mentionCount != rhs.mentionCount {
                    return lhs.mentionCount > rhs.mentionCount
                }
                return lhs.addedTurn < rhs.addedTurn
            }
        }

        var lines: [String] = hits.map(formatEntityLine)
        var rendered = lines.joined(separator: "\n")
        if rendered.count > maxChars {
            // Eviction order: non-pinned entities only, ranked ascending by
            // max-fact-salience. Pinned entities never drop even when the
            // block overflows — that's the whole point of a pin.
            let evictOrder = hits.enumerated()
                .filter { !$0.element.pinnedByUser }
                .sorted { lhs, rhs in
                    let l = entitySalience(lhs.element)
                    let r = entitySalience(rhs.element)
                    if l.0 != r.0 { return l.0 < r.0 }
                    if l.1 != r.1 { return l.1 < r.1 }
                    return l.2 > r.2 // older addedTurn drops first
                }
                .map { $0.offset }

            var droppable = evictOrder
            while rendered.count > maxChars && lines.count > 1 && !droppable.isEmpty {
                let dropIdx = droppable.removeFirst()
                if dropIdx < lines.count {
                    lines.remove(at: dropIdx)
                    droppable = droppable.map { $0 > dropIdx ? $0 - 1 : $0 }
                }
                rendered = lines.joined(separator: "\n")
            }
        }
        if rendered.isEmpty { return nil }
        // The header is phrased as an imperative aside, not a bracketed
        // section title, so the model treats it as a private reference card
        // rather than a heading to restate. Earlier wording
        // ("[Entities currently on-stage — keep details consistent]") was
        // routinely echoed back at the top of replies by Qwen3 with thinking
        // mode on — a Qwen3 trait of treating labeled prompt sections as
        // scene preambles to reproduce. Brackets are kept on each entity
        // line below since those are needed for the model to parse the
        // tag/content split, but the framing line is plain prose.
        let header = "(Reference only — character details for continuity. Do NOT restate, quote, or copy these lines into your reply. Use them silently to keep facts consistent.)"
        return header + "\n" + rendered
    }

    /// Group facts by transient-state topic and keep only the latest entry
    /// per non-nil topic. Topicless facts (timeless attributes — names,
    /// ages, occupations, traits) are never filtered. "Latest" is
    /// `(lastReinforcedTurn, addedTurn)` lexicographically — same recency
    /// notion the salience sort uses. Pinned facts always survive even if
    /// older, so user-curated state isn't silently dropped.
    /// See MEMORY_AUDIT §4.3-E.
    static func supersedeStaleFactsByTopic(_ facts: [Fact]) -> [Fact] {
        var latestByTopic: [String: Fact] = [:]
        var passthrough: [Fact] = []
        for f in facts {
            if f.pinnedByUser {
                passthrough.append(f)
                continue
            }
            guard let topic = factTopic(of: f.text) else {
                passthrough.append(f)
                continue
            }
            if let existing = latestByTopic[topic] {
                let lhs = (existing.lastReinforcedTurn, existing.addedTurn)
                let rhs = (f.lastReinforcedTurn, f.addedTurn)
                if rhs > lhs {
                    latestByTopic[topic] = f
                }
            } else {
                latestByTopic[topic] = f
            }
        }
        // Preserve the input order for kept facts so the existing salience
        // sort downstream remains stable.
        let kept = Set(passthrough.map(\.id)).union(latestByTopic.values.map(\.id))
        return facts.filter { kept.contains($0.id) }
    }

    /// Map a fact's text to a coarse transient-state topic bucket. Conservative:
    /// returns nil unless the text falls cleanly into a known mutually-
    /// exclusive bucket. Timeless attributes (age, height, occupation, traits,
    /// relationships) deliberately fall through and are never collapsed.
    static func factTopic(of text: String) -> String? {
        let lower = text.lowercased()
        // State of dress / clothing — what the user just hit (topless vs naked).
        // Tight keyword list to avoid false positives on figurative usage like
        // "dressed for success" or "wearing his heart on his sleeve".
        let clothing = [
            "naked", "nude", "topless", "stripped", "stripping",
            "panties", "bra ", "bra,", "bra.", "underwear", "lingerie", "thong",
            "in only", "in just",
            "is wearing", "are wearing", "wearing only", "wearing just",
            "is dressed", "are dressed",
            "took off", "removed her", "removed his", "removed their",
            "fully clothed", "half-dressed", "half dressed",
        ]
        for kw in clothing where lower.contains(kw) { return "clothing" }
        return nil
    }

    /// Entity-level salience score: max over its facts. Used when the block
    /// overflows and we need to drop whole entities. Tuple form so we can
    /// compare lexicographically on (recency, mentions, oldest-add).
    private static func entitySalience(_ ent: Entity) -> (Int, Int, Int) {
        let lr = ent.facts.map { $0.lastReinforcedTurn }.max() ?? 0
        let mc = ent.facts.map { $0.mentionCount }.max() ?? 0
        let added = ent.facts.map { $0.addedTurn }.min() ?? ent.createdTurn
        return (lr, mc, added)
    }

    private static func formatEntityLine(_ ent: Entity) -> String {
        let label = "\(ent.type.label): \(ent.name)"
        let factsList = ent.facts.enumerated().map { i, f in
            "(\(letter(at: i))) \(f.text)"
        }.joined(separator: " ")
        if factsList.isEmpty {
            return "[\(label)]"
        }
        return "[\(label)] \(factsList)"
    }

    /// "a", "b", ..., "z", "aa", "ab", ... — used to label per-fact bullets in
    /// the entity block so ordering is unambiguous to the model.
    private static func letter(at idx: Int) -> String {
        var n = idx
        var out = ""
        repeat {
            let r = n % 26
            out = String(UnicodeScalar(UInt8(97 + r))) + out
            n = n / 26 - 1
        } while n >= 0
        return out
    }

    /// Format retrieved chunks as a single text block to inject into the last
    /// user turn. Two regimes:
    ///
    ///  1. **Chunk has a `contextBlurb`** (the contextual-retrieval path) —
    ///     emit *only* the blurb, framed as a one-line factual recall.
    ///     Embedding still matches against `blurb + dialog`, so we get the
    ///     selectivity benefit, but the prompt sees only the blurb. This
    ///     prevents the "wall of past dialog right before the gen marker"
    ///     failure mode where the model picks up the dialog rhythm of an
    ///     earlier scene and continues from inside it.
    ///  2. **Legacy chunks without a blurb** — fall back to a shortened
    ///     dialog snippet with role prefixes stripped. Capped at ~400 chars
    ///     each so a few legacy chunks can't blow up the prompt the way
    ///     they used to.
    static func formatRelevantMemories(_ hits: [VectorStore.Hit]) -> String? {
        guard !hits.isEmpty else { return nil }
        let body = hits.map { hit in renderHit(hit) }
            .joined(separator: "\n")
        return """
        [Recall — facts from earlier in the story for continuity. These have already happened; do not continue from them, do not relocate the current scene to match them.]

        \(body)
        """
    }

    /// Per-hit cap for legacy chunks that lack a blurb — keeps the prompt
    /// from drowning in dialog when contextual retrieval hasn't backfilled
    /// older chunks yet. Public for testability.
    static let legacyChunkInjectionCap = 400

    private static func renderHit(_ hit: VectorStore.Hit) -> String {
        let range = "turns \(hit.chunk.firstTurnIdx)–\(hit.chunk.lastTurnIdx)"
        if let raw = hit.chunk.contextBlurb?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            return "• (\(range)) \(raw)"
        }
        // Legacy fallback: truncated dialog snippet, role prefixes stripped.
        var body = stripRolePrefixes(hit.chunk.text)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if body.count > legacyChunkInjectionCap {
            let cap = body.index(body.startIndex, offsetBy: legacyChunkInjectionCap)
            body = String(body[..<cap]) + "…"
        }
        return "• (\(range)) \(body)"
    }

    private static func stripRolePrefixes(_ text: String) -> String {
        text.components(separatedBy: "\n").map { line -> String in
            if line.hasPrefix("User: ") { return String(line.dropFirst(6)) }
            if line.hasPrefix("Assistant: ") { return String(line.dropFirst(11)) }
            return line
        }.joined(separator: "\n")
    }

    /// Re-injection digest for the latest user turn (§9.6). Returns nil unless
    /// the chat has tail reinforcement enabled and pinned memory to reinforce.
    /// Trailing-truncates to ~1200 chars (≈ 300 tokens) so the most recently
    /// added pins survive — proper salience-based selection ships with §9.7.
    /// Suppressed in continuation mode (the assistant turn is mid-stream; no
    /// new user turn to attach to).
    static func tailMemoryDigest(chat: Chat, continuation: Bool = false) -> String? {
        guard chat.tailReinforceMemory, !continuation else { return nil }
        let trimmed = chat.memory.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let cap = 1200
        let body: String
        if trimmed.count <= cap {
            body = trimmed
        } else {
            let suffix = String(trimmed.suffix(cap))
            body = "…" + suffix.drop(while: { !$0.isNewline && !$0.isWhitespace })
        }
        return "[Reminder — pinned facts, kept current]\n\n\(body)"
    }
}
