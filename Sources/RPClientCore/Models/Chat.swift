import Foundation

/// How a character card's `system_prompt` interacts with chat memory at the
/// top of the prompt. `.override` (default) replaces `chat.memory` for the
/// session; `.merge` prepends and keeps both. Per-chat by design — global
/// defaulting can be added to `Settings` later if the need actually emerges.
enum CardPromptMode: String, Codable, Equatable {
    case override
    case merge
}

struct FactExtractionPriority: Codable, Equatable, Identifiable {
    let id: UUID
    var text: String
    var enabled: Bool

    init(id: UUID = UUID(), text: String, enabled: Bool = true) {
        self.id = id
        self.text = text
        self.enabled = enabled
    }
}

struct FactSuggestion: Codable, Equatable, Identifiable {
    let id: UUID
    var category: String
    var fact: String
    var createdTurn: Int

    init(id: UUID = UUID(), category: String, fact: String, createdTurn: Int) {
        self.id = id
        self.category = category
        self.fact = fact
        self.createdTurn = createdTurn
    }
}

struct Chat: Codable, Equatable, Identifiable {
    let id: UUID
    var title: String
    var created: Date
    var modified: Date
    var templateId: String
    var samplerPresetId: String
    var memory: String
    var memoryTokenCap: Int
    var summary: String
    var summarizedThrough: Int
    var summaryTokenCap: Int
    var summaryTriggerRatio: Double
    var authorsNote: AuthorsNote
    var worldInfo: [WorldInfoEntry]
    var turns: [Turn]
    var pendingFactSuggestions: [FactSuggestion]
    /// Frozen rolling-summary snapshots, oldest first. Each entry is the
    /// summary that was live when the user pressed "Scene break", carrying
    /// `firstTurn`/`lastTurn` markers for the range it covers (nil on
    /// legacy entries that predate the typed storage). Injected in
    /// chronological order above the live rolling summary so older arc
    /// content survives the auto-compress cycle. See MEMORY_RESEARCH.md §9.2
    /// and MEMORY_AUDIT.md §4.1.
    var sceneSummaries: [SceneSummary]
    /// Steering topics for the §9.3 fact extractor — each entry can be
    /// individually toggled to make A/B testing easier. Soft hint passed to
    /// the model, not a hard filter; the extractor still captures other
    /// significant changes.
    var factExtractionPriorities: [FactExtractionPriority]
    /// When true, the most recent ~300 tokens of pinned memory are re-injected
    /// into the latest user turn — counters Gemma's first-turn fold drift on
    /// long chats. Costs ~0.3–1s of prefill per turn but preserves cache for
    /// everything above. See MEMORY_RESEARCH.md §9.6.
    var tailReinforceMemory: Bool
    /// Highest turn index already covered by an auto-extraction pass. Counted
    /// against `turns.count` to gate the §9.3 cadence so we don't re-extract
    /// the same window. Defaults to 0 for chats created before Step B.
    var lastExtractedTurn: Int
    /// How many recent turns to feed the extractor on each run. 0 = use the
    /// dynamic default (cover the unseen window since `lastExtractedTurn`
    /// plus a small overlap). Per-chat because long-form scenes typically
    /// want more, action-heavy chats less.
    var factExtractionScanTurns: Int
    /// Structured entity store (V2 — Step C). Replaces `memory` as the primary
    /// home for long-term facts; `memory` is kept as freeform notes that
    /// always inject. Selective injection (`PromptBuilder.entitiesBlock`)
    /// keeps the prompt small even on chats with hundreds of entities.
    var entities: [Entity]
    /// Persisted schema version for the chat document. v1 = pre-Step-C (no
    /// entity store), v2 = entity store seeded from `memory`, v3 = scene
    /// summaries carry per-entry markers + entity store deduped of legacy
    /// migrated rows. Read once at decode-time so migration runs exactly
    /// once per chat.
    var schemaVersion: Int
    /// Cumulative prompt-token count across every send on this chat (initial
    /// sends, regens, and continuations all count). Tallied from
    /// `BudgetUsage.prompt` at stream start. Surfaced in the status bar so
    /// the user can eyeball compute spend per chat. Defaults to 0 for chats
    /// written before this field existed; not retroactively backfilled.
    var tokensSent: Int
    /// Cumulative reply-token count across every stream. Tallied from
    /// koboldcpp's `last_token_count` perf reading at stream finish, so it
    /// matches what the server actually generated (including any tokens
    /// stripped by the think-block filter — those still cost wall time).
    var tokensReceived: Int
    /// Character card driving this chat (nil = free-form chat with no card).
    /// Phase 3 §4. The card's content is *not* duplicated onto the chat —
    /// PromptBuilder reads the live `Character` out of `AppState.characters`
    /// at send time so edits to the card propagate without rewriting chats.
    /// Existing chats decode as nil and behave exactly as before.
    var characterId: UUID?
    /// User-side persona for this chat (nil = anonymous — falls back to
    /// `Settings.userName`). Same indirection as `characterId`: the persona
    /// description lives on the `Persona`, not the chat.
    var personaId: UUID?
    /// How the linked character's `system_prompt` interacts with `memory`.
    /// Default `.override` matches SillyTavern. Existing chats without this
    /// key decode as `.override`. See `CardPromptMode`.
    var systemPromptMode: CardPromptMode
    /// Server pin for this chat's generation calls (Phase 4 §5.4). Nil = use
    /// `Settings.defaultServerId`. Side-call routing (summarizer, extractor,
    /// embeddings) ignores this field — those go through the role overrides
    /// on Settings instead. Pre-Phase-4 chats decode as nil.
    var serverId: UUID?
    /// Per-chat default narrator voice. Phase 6 §7.2c. Nil falls back to
    /// `Settings.defaultVoice`; entities with their own `voice` override
    /// both. The speaker layer (§7.4) is the consumer.
    var voice: VoicePreference?
    /// How the speaker layer splits a turn's text into per-entity segments.
    /// Phase 6 §7.3. Default `.heuristic` produces *some* per-character
    /// routing on day one with no convention; `.tagged` is cleaner when the
    /// model is producing `Sage: "…"` style output. UI for picking lands in
    /// §7.5d; pre-§7.3 chats decode as `.heuristic`.
    var attributionMode: AttributionMode
    /// Phase 7 §3.1 — ordered list of turn IDs from root to active leaf.
    /// `Chat.turns` stays as the storage of *all* turns ever created in
    /// this chat (including off-path branches); `activeTurns` derives the
    /// renderable list from this path. Pre-Phase-7 chats decode as a spine
    /// derived from `turns`-in-order.
    var activePath: [UUID]

    init(
        id: UUID = UUID(),
        title: String = "New Chat",
        templateId: String = "gemma",
        samplerPresetId: String = "balanced"
    ) {
        let now = Date()
        self.id = id
        self.title = title
        self.created = now
        self.modified = now
        self.templateId = templateId
        self.samplerPresetId = samplerPresetId
        self.memory = ""
        self.memoryTokenCap = 800
        self.summary = ""
        self.summarizedThrough = 0
        self.summaryTokenCap = 350
        self.summaryTriggerRatio = 0.85
        self.authorsNote = .default
        self.worldInfo = []
        self.turns = []
        self.pendingFactSuggestions = []
        self.sceneSummaries = []
        self.factExtractionPriorities = []
        self.tailReinforceMemory = false
        self.lastExtractedTurn = 0
        self.factExtractionScanTurns = 0
        self.entities = []
        self.schemaVersion = 3
        self.tokensSent = 0
        self.tokensReceived = 0
        self.characterId = nil
        self.personaId = nil
        self.systemPromptMode = .override
        self.serverId = nil
        self.voice = nil
        self.attributionMode = .heuristic
        self.activePath = []
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        created = try c.decode(Date.self, forKey: .created)
        modified = try c.decode(Date.self, forKey: .modified)
        templateId = try c.decode(String.self, forKey: .templateId)
        samplerPresetId = try c.decode(String.self, forKey: .samplerPresetId)
        memory = try c.decodeIfPresent(String.self, forKey: .memory) ?? ""
        memoryTokenCap = try c.decodeIfPresent(Int.self, forKey: .memoryTokenCap) ?? 800
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        summarizedThrough = try c.decodeIfPresent(Int.self, forKey: .summarizedThrough) ?? 0
        summaryTokenCap = try c.decodeIfPresent(Int.self, forKey: .summaryTokenCap) ?? 350
        summaryTriggerRatio = try c.decodeIfPresent(Double.self, forKey: .summaryTriggerRatio) ?? 0.85
        authorsNote = try c.decodeIfPresent(AuthorsNote.self, forKey: .authorsNote) ?? .default
        worldInfo = try c.decodeIfPresent([WorldInfoEntry].self, forKey: .worldInfo) ?? []
        turns = try c.decodeIfPresent([Turn].self, forKey: .turns) ?? []
        pendingFactSuggestions = try c.decodeIfPresent([FactSuggestion].self, forKey: .pendingFactSuggestions) ?? []
        // Scene summaries: prefer the typed shape, fall back to the legacy
        // `[String]` shape for chats written before MEMORY_AUDIT §4.1-A.
        if let typed = try? c.decode([SceneSummary].self, forKey: .sceneSummaries) {
            sceneSummaries = typed
        } else if let strs = try? c.decode([String].self, forKey: .sceneSummaries) {
            sceneSummaries = strs.map { SceneSummary(text: $0) }
        } else {
            sceneSummaries = []
        }
        if let arr = try? c.decode([FactExtractionPriority].self, forKey: .factExtractionPriorities) {
            factExtractionPriorities = arr
        } else if let str = try? c.decode(String.self, forKey: .factExtractionPriorities), !str.isEmpty {
            // Migrate from the old single-string representation.
            factExtractionPriorities = str
                .components(separatedBy: CharacterSet(charactersIn: ",\n"))
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
                .map { FactExtractionPriority(text: $0, enabled: true) }
        } else {
            factExtractionPriorities = []
        }
        tailReinforceMemory = try c.decodeIfPresent(Bool.self, forKey: .tailReinforceMemory) ?? false
        lastExtractedTurn = try c.decodeIfPresent(Int.self, forKey: .lastExtractedTurn) ?? 0
        factExtractionScanTurns = try c.decodeIfPresent(Int.self, forKey: .factExtractionScanTurns) ?? 0
        let decodedEntities = try c.decodeIfPresent([Entity].self, forKey: .entities) ?? []
        let decodedVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        var seeded: [Entity]
        if decodedVersion < 2 && decodedEntities.isEmpty && !memory.isEmpty {
            // One-time migration: seed each parsed memory line as a one-fact
            // entity so the user has something to curate in the new pane.
            // Memory itself is preserved as freeform notes — the user can clear
            // it by hand once they're happy with the entity layout.
            seeded = Chat.migrateMemoryToEntities(memory)
        } else {
            seeded = decodedEntities
        }
        if decodedVersion < 3 {
            // v3: dedupe legacy migrated rows. Step C left some chats with
            // pairs like `[character] Sarah / type=event` AND
            // `Sarah / type=character` because the suggestion path created the
            // typed entity while the older `memory` migration kept the bracket-
            // prefixed name. Merge them so the entities block stops re-injecting
            // stale state from the old `memory` lines.
            seeded = Chat.dedupeMigratedEntities(seeded)
        }
        entities = seeded
        schemaVersion = max(decodedVersion, 3)
        tokensSent = try c.decodeIfPresent(Int.self, forKey: .tokensSent) ?? 0
        tokensReceived = try c.decodeIfPresent(Int.self, forKey: .tokensReceived) ?? 0
        characterId = try c.decodeIfPresent(UUID.self, forKey: .characterId)
        personaId = try c.decodeIfPresent(UUID.self, forKey: .personaId)
        systemPromptMode = try c.decodeIfPresent(CardPromptMode.self, forKey: .systemPromptMode) ?? .override
        serverId = try c.decodeIfPresent(UUID.self, forKey: .serverId)
        voice = try c.decodeIfPresent(VoicePreference.self, forKey: .voice)
        attributionMode = try c.decodeIfPresent(AttributionMode.self, forKey: .attributionMode) ?? .heuristic

        // Phase 7 §3.1 — branching migration + validation. Two cases:
        //
        //  (a) **Legacy.** Decoded chat has turns but zero `parentId` set on
        //      any of them. Treat as a flat pre-Phase-7 chat regardless of
        //      whether `activePath` is missing/empty — patch parentIds into a
        //      spine and derive activePath from turn order. Catches both the
        //      on-disk legacy shape and the in-memory case where existing
        //      callers built a chat the old way (initializer + `chat.turns =
        //      [...]`) and we round-tripped through encode/decode.
        //
        //  (b) **Phase 7+.** At least one turn has parentId set. Trust the
        //      decoded `activePath` (or default to empty for an empty turns
        //      array), then run validation.
        let decodedPath = try c.decodeIfPresent([UUID].self, forKey: .activePath)
        let hasAnyParents = turns.contains { $0.parentId != nil }
        let pathExplicitlyPopulated = !(decodedPath ?? []).isEmpty
        if !turns.isEmpty && !hasAnyParents && !pathExplicitlyPopulated {
            // Legacy on-disk shape OR an in-memory chat built via the old
            // initializer + `chat.turns = [...]` pattern that round-tripped
            // through encode/decode. Patch a spine and ignore any empty
            // activePath that came along for the ride.
            for i in turns.indices {
                turns[i].parentId = i > 0 ? turns[i - 1].id : nil
            }
            activePath = turns.map(\.id)
        } else {
            activePath = decodedPath ?? (turns.isEmpty ? [] : turns.map(\.id))
        }
        try Chat.validateBranching(turns: turns, activePath: activePath)

        // Phase 7 §3.2 — SceneSummary post-resolve. Legacy scenes stored
        // Int turn positions; resolve to UUIDs against the (now-built)
        // activePath so subsequent reads go through the branch-aware
        // `firstTurnPosition(in:)`/`lastTurnPosition(in:)` helpers. Out-of-
        // bounds Ints stay unresolved (UUID nil) — readers fall back to the
        // Int snapshot.
        for i in sceneSummaries.indices {
            if sceneSummaries[i].firstTurnId == nil,
               let firstIdx = sceneSummaries[i].firstTurn,
               activePath.indices.contains(firstIdx) {
                sceneSummaries[i].firstTurnId = activePath[firstIdx]
            }
            if sceneSummaries[i].lastTurnId == nil,
               let lastIdx = sceneSummaries[i].lastTurn,
               activePath.indices.contains(lastIdx) {
                sceneSummaries[i].lastTurnId = activePath[lastIdx]
            }
        }
    }

    /// Phase 7 §3.1 — runs at decode time after migration. Throws a
    /// `DecodingError` describing the first violation found. Defensive
    /// rules per V2_PHASE7_FULL_BRANCHING.md §2.2:
    /// - Every non-nil parentId points to a turn that exists.
    /// - Exactly one root (parentId == nil) when turns is non-empty.
    /// - activePath is connected: each successor's parentId == predecessor.
    /// - First activePath entry is the root.
    /// - No cycles in the parentId chain (parent walk terminates within
    ///   turns.count steps from any turn).
    static func validateBranching(turns: [Turn], activePath: [UUID]) throws {
        guard !turns.isEmpty else {
            if !activePath.isEmpty {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "activePath has \(activePath.count) entries but turns is empty"
                ))
            }
            return
        }

        let idsArray = turns.map(\.id)
        let ids = Set(idsArray)
        if ids.count != turns.count {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "duplicate turn IDs in turns array"
            ))
        }

        var rootCount = 0
        for t in turns {
            if let pid = t.parentId {
                if !ids.contains(pid) {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "turn \(t.id) has parentId \(pid) that doesn't exist in turns"
                    ))
                }
            } else {
                rootCount += 1
            }
        }
        if rootCount != 1 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "expected exactly one root turn (parentId == nil), found \(rootCount)"
            ))
        }

        // Cycle detection: from each turn, walk parentId until nil. If the
        // walk exceeds turns.count, the chain has a cycle. (Both Open WebUI
        // and LibreChat ship explicit cycle guards — cheap, prevents infinite
        // loops in switchBranch / children resolution.)
        let parentByID: [UUID: UUID?] = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.parentId) })
        for t in turns {
            var cur: UUID? = t.parentId
            var steps = 0
            while let p = cur {
                steps += 1
                if steps > turns.count {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "parentId cycle detected starting from turn \(t.id)"
                    ))
                }
                cur = parentByID[p] ?? nil
            }
        }

        // activePath must be connected from the root.
        if !activePath.isEmpty {
            for id in activePath {
                if !ids.contains(id) {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "activePath references unknown turn id \(id)"
                    ))
                }
            }
            let parentsByID: [UUID: UUID?] = Dictionary(uniqueKeysWithValues: turns.map { ($0.id, $0.parentId) })
            // First entry must be a root (parentId nil).
            if (parentsByID[activePath[0]] ?? nil) != nil {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "activePath[0] is not a root turn (parentId != nil)"
                ))
            }
            // Each consecutive pair must satisfy successor.parentId == predecessor.
            for i in 1..<activePath.count {
                let succParent = parentsByID[activePath[i]] ?? nil
                if succParent != activePath[i - 1] {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: [],
                        debugDescription: "activePath disconnected at index \(i): turn \(activePath[i])'s parent is \(String(describing: succParent)), expected \(activePath[i - 1])"
                    ))
                }
            }
        }
    }

    /// Best-effort parse of a `memory` string (one fact per line) into entities.
    /// Recognises the `[type] name — text` shape produced by the old
    /// `acceptSuggestion` path; falls back to `.event` with the whole line as
    /// the fact otherwise. Public so tests can poke at it directly.
    static func migrateMemoryToEntities(_ memory: String) -> [Entity] {
        let lines = memory
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return [] }

        var byKey: [String: Int] = [:]
        var out: [Entity] = []

        for line in lines {
            var typeRaw: String? = nil
            var rest = line
            // Optional `[type] ` prefix.
            if rest.hasPrefix("[") {
                if let close = rest.firstIndex(of: "]") {
                    let inside = String(rest[rest.index(after: rest.startIndex)..<close])
                        .trimmingCharacters(in: .whitespaces)
                    typeRaw = inside.lowercased()
                    let after = rest.index(after: close)
                    rest = String(rest[after...]).trimmingCharacters(in: .whitespaces)
                }
            }
            let type = EntityType(rawValue: typeRaw ?? "") ?? .event

            // Try to split on " — " (em dash) first, then " - " as a fallback.
            let name: String
            let factText: String
            if let r = rest.range(of: " — ") {
                name = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                factText = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else if let r = rest.range(of: " - ") {
                name = String(rest[..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                factText = String(rest[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            } else {
                name = String(rest.prefix(40)).trimmingCharacters(in: .whitespaces)
                factText = rest
            }

            let canonName = name.isEmpty ? "Note" : name
            let key = "\(type.rawValue)|\(canonName.lowercased())"
            let fact = Fact(text: factText.isEmpty ? line : factText)
            if let idx = byKey[key] {
                out[idx].facts.append(fact)
            } else {
                byKey[key] = out.count
                out.append(Entity(
                    name: canonName,
                    type: type,
                    facts: [fact],
                    pinnedByUser: true
                ))
            }
        }
        return out
    }

    /// Stable, deterministic hash of the turns that make up a variant's
    /// upstream context. We store the result on `TurnVariant` at generation
    /// time and recompute on demand to detect when an upstream edit, reorder,
    /// delete, or page-swap has invalidated the context the variant was
    /// generated against. FNV-1a over (id, role, text) per turn keeps the
    /// implementation dep-free and the value stable across launches.
    static func makeContextFingerprint<S: Sequence>(_ turns: S) -> String
        where S.Element == Turn
    {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        func mix(_ s: String) {
            for byte in s.utf8 {
                hash ^= UInt64(byte)
                hash = hash &* prime
            }
            // Field separator so "ab" + "c" doesn't collide with "a" + "bc".
            hash ^= 0x1f
            hash = hash &* prime
        }
        for t in turns {
            mix(t.id.uuidString)
            mix(t.role.rawValue)
            mix(t.text)
        }
        return String(hash, radix: 16)
    }

    /// Returns true when the variant at `(turnIndex, variantIndex)` has a
    /// recorded fingerprint that no longer matches the chat's live prefix.
    /// Variants without a fingerprint (legacy seeds, hand-edited rows) are
    /// reported as not-stale — we have no provenance to compare against.
    func isVariantStale(turnIndex: Int, variantIndex: Int) -> Bool {
        guard turns.indices.contains(turnIndex) else { return false }
        guard turns[turnIndex].variants.indices.contains(variantIndex) else { return false }
        guard let recorded = turns[turnIndex].variants[variantIndex].contextFingerprint else {
            return false
        }
        let live = Chat.makeContextFingerprint(turns[..<turnIndex])
        return recorded != live
    }

    // MARK: - Phase 7 §3.1 — branching helper API

    /// Renderable in-order list of turns following the active path. Use this
    /// everywhere the old `chat.turns` was treated as "the visible chat";
    /// `chat.turns` itself stays as the storage of *all* turns including
    /// off-path branches. Stale activePath entries (pointing to a deleted
    /// turn) are silently dropped — decode-time validation prevents the
    /// case in persisted state, but in-memory mutation can produce
    /// transient invalids.
    var activeTurns: [Turn] {
        activePath.compactMap { id in turns.first(where: { $0.id == id }) }
    }

    /// Lookup a turn by id. O(n) walk; chats are typically small (<500 turns)
    /// so a derived index isn't worth the staleness risk on a value type.
    func turn(id: UUID) -> Turn? {
        turns.first(where: { $0.id == id })
    }

    /// Position of `turnId` along `activePath`, or nil if not on the current
    /// path. The replacement for "turn index" in the new branching world.
    func activePosition(of turnId: UUID) -> Int? {
        activePath.firstIndex(of: turnId)
    }

    /// All turns whose `parentId` matches `turnId`. Sorted by `ts` so the
    /// iteration order is deterministic (creation order under normal
    /// generation). Used by the gutter glyph (siblings popover), Branches
    /// pane, and switchBranch's drill-down.
    func children(of turnId: UUID) -> [Turn] {
        turns.filter { $0.parentId == turnId }.sorted { $0.ts < $1.ts }
    }

    /// Switch the active branch to the path that ends at `turnId`'s subtree
    /// leaf. Walks parentId chain up from `turnId` to find the path-from-root,
    /// then drills back down via `activeChildId` (or earliest child by ts if
    /// `activeChildId` is unset) until reaching a leaf. Updates each
    /// ancestor's `activeChildId` so subsequent loads land here.
    ///
    /// Drill-to-deepest-descendant matches Open WebUI's `Messages.svelte:179`
    /// behaviour — switching to a sibling that has descendants takes you to
    /// that subtree's leaf, not to the sibling itself. Avoids the user
    /// having to drill manually.
    ///
    /// No-op if `turnId` is not in `turns`.
    mutating func switchBranch(to turnId: UUID) {
        guard turns.contains(where: { $0.id == turnId }) else { return }

        // 1. Walk parents from turnId up to root, collecting the path.
        var pathToRoot: [UUID] = []
        var cur: UUID? = turnId
        var safety = turns.count + 1
        while let id = cur {
            pathToRoot.append(id)
            safety -= 1
            if safety < 0 { return } // defensive — should be impossible after decode validation
            cur = turns.first(where: { $0.id == id })?.parentId
        }
        let pathFromRoot = Array(pathToRoot.reversed())

        // 2. Update each ancestor's activeChildId to record the choice.
        //    pathFromRoot[i] is the parent of pathFromRoot[i+1].
        for i in 0..<(pathFromRoot.count - 1) {
            let parent = pathFromRoot[i]
            let child = pathFromRoot[i + 1]
            if let idx = turns.firstIndex(where: { $0.id == parent }) {
                turns[idx].activeChildId = child
            }
        }

        // 3. Drill down from turnId via activeChildId (or earliest by ts).
        var fullPath = pathFromRoot
        var leaf = turnId
        while let chosenChild = nextChildToDescend(from: leaf) {
            fullPath.append(chosenChild)
            // Record the descent choice on the parent so it sticks.
            if let idx = turns.firstIndex(where: { $0.id == leaf }) {
                turns[idx].activeChildId = chosenChild
            }
            leaf = chosenChild
        }
        activePath = fullPath

        // 4. Clamp summarizedThrough to the new path's length so
        //    PromptBuilder.verbatimTurns doesn't slice past the end. Phase 7
        //    §3.2.D — per-branch rolling-summary state is correct long-term
        //    but a separate refactor; for now, accept that switching to a
        //    shorter branch loses the high-water mark for "how far we'd
        //    summarised the previous branch." Next summarizer cycle on the
        //    new branch will naturally re-establish it.
        if summarizedThrough > activePath.count {
            summarizedThrough = activePath.count
        }
    }

    /// Pick the next child to descend into when walking down from `turnId`.
    /// Honours `activeChildId` if set and pointing to an existing child;
    /// otherwise picks the earliest child by ts. Returns nil at a leaf.
    private func nextChildToDescend(from turnId: UUID) -> UUID? {
        let kids = children(of: turnId)
        guard !kids.isEmpty else { return nil }
        if let recorded = turn(id: turnId)?.activeChildId,
           kids.contains(where: { $0.id == recorded }) {
            return recorded
        }
        return kids.first?.id
    }

    /// Collapse legacy bracket-prefixed entity rows into their typed twins.
    /// Pre-v3 chats can carry rows like `name="[character] Sarah", type=.event`
    /// alongside `name="Sarah", type=.character` because two separate code
    /// paths populated the store. We parse the prefix off the legacy name,
    /// re-key on `(type, name.lowercased())`, and merge facts/aliases — text-
    /// level dedup so the same fact text isn't appended twice. Public so the
    /// migration is testable without hitting Codable.
    static func dedupeMigratedEntities(_ entities: [Entity]) -> [Entity] {
        guard !entities.isEmpty else { return [] }
        var byKey: [String: Int] = [:]
        var out: [Entity] = []

        for ent in entities {
            var name = ent.name
            var type = ent.type
            // Detect a leading "[type] " prefix in the name, e.g.
            // "[character] Sarah". Only rewrite if the prefix names a real
            // EntityType — otherwise leave the name alone (it might just be
            // user-entered text that happens to start with a bracket).
            if name.hasPrefix("[") {
                if let close = name.firstIndex(of: "]") {
                    let inside = String(name[name.index(after: name.startIndex)..<close])
                        .trimmingCharacters(in: .whitespaces)
                        .lowercased()
                    if let parsed = EntityType(rawValue: inside) {
                        let after = name.index(after: close)
                        let stripped = String(name[after...]).trimmingCharacters(in: .whitespaces)
                        if !stripped.isEmpty {
                            name = stripped
                            type = parsed
                        }
                    }
                }
            }

            let key = "\(type.rawValue)|\(name.lowercased())"
            if let idx = byKey[key] {
                var merged = out[idx]
                let existingTexts = Set(merged.facts.map(\.text))
                for f in ent.facts where !existingTexts.contains(f.text) {
                    merged.facts.append(f)
                }
                let existingAliases = Set(merged.aliases.map { $0.lowercased() })
                for a in ent.aliases where !existingAliases.contains(a.lowercased()) {
                    merged.aliases.append(a)
                }
                merged.pinnedByUser = merged.pinnedByUser || ent.pinnedByUser
                merged.createdTurn = min(merged.createdTurn, ent.createdTurn)
                out[idx] = merged
            } else {
                var rewritten = ent
                rewritten.name = name
                rewritten.type = type
                byKey[key] = out.count
                out.append(rewritten)
            }
        }
        return out
    }
}
