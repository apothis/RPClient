import Foundation

/// How a character card's `system_prompt` interacts with chat memory at the
/// top of the prompt. `.override` (default) replaces `chat.memory` for the
/// session; `.merge` prepends and keeps both. Per-chat by design — global
/// defaulting can be added to `Settings` later if the need actually emerges.
enum CardPromptMode: String, Codable, Equatable {
    case override
    case merge
}

/// Phase 8 §3.1 — how the next speaker is chosen in a multi-cast chat.
/// `.roundRobin` cycles through `Chat.cast` in declaration order; `.pooled`
/// gives each cast member one turn before anyone repeats (resets on each user
/// turn); `.manual` defers to a per-turn override; `.director` calls a small
/// router LLM to pick a name (opt-in, lands in §4.4 — this case exists in
/// the enum from §4.1 so on-disk state can hold it without a follow-up
/// migration). Solo chats (`cast.count <= 1`) ignore this field entirely.
enum SpeakerSelectionMode: String, Codable, Equatable {
    case roundRobin
    case pooled
    case manual
    case director
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
    ///
    /// Phase 8 §4.1 — `didSet` maintains the invariant `characterId non-nil
    /// implies characterId ∈ cast`, so any code path that assigns a
    /// character to a chat (new-chat creation, "switch character" in the
    /// Inspector) keeps `cast` in sync without each call site needing to
    /// know about Phase 8. Property observers don't fire during
    /// `init(from:)`, so the decode-time cast-seeding migration runs once
    /// and this observer takes over for every subsequent assignment.
    var characterId: UUID? {
        didSet {
            guard let cid = characterId else { return }
            if cast.isEmpty {
                cast = [cid]
            } else if !cast.contains(cid) {
                cast.append(cid)
            }
        }
    }
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
    /// Phase 8 §4.1 — character IDs in this chat's cast. Empty on free-form
    /// chats (no character bound) and on pre-Phase-8 chats whose
    /// `characterId` was nil. Single-entry on legacy single-character chats
    /// (decode-time migration promotes `characterId` into `cast[0]`). Order
    /// is significant: round-robin selection cycles in this order, and the
    /// input-bar speaker picker presents the cast in this order too.
    /// Per-speaker render metadata (display name, voice, avatar) is looked
    /// up from `AppState.characters[id]` at render time, so adding a member
    /// is just a UUID append — no duplicated fields to drift.
    var cast: [UUID]
    /// Phase 8 §3.1 — speaker selection mode. Default `.roundRobin`.
    /// Solo / free-form chats (cast.count <= 1) ignore this field; the
    /// single speaker is always the only candidate.
    var speakerSelection: SpeakerSelectionMode
    /// Phase 8 §4.2a — one-shot speaker override consumed by the next
    /// assistant generation. Set by the input-bar speaker picker (§4.3)
    /// when the user explicitly picks "make X speak next." Cleared via
    /// `consumePendingSpeaker()` when the send path picks the speaker.
    /// In `.manual` mode this is the primary input; in other modes it
    /// can still override (so the user can punch in a one-off without
    /// switching the chat's selection mode). Persisted across launches
    /// so a queued pick survives a restart; if it goes stale (points
    /// outside `cast`), `SpeakerPicker.next(in:)` ignores it.
    var pendingSpeakerId: UUID?

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
        self.schemaVersion = 4
        self.tokensSent = 0
        self.tokensReceived = 0
        self.characterId = nil
        self.personaId = nil
        self.systemPromptMode = .override
        self.serverId = nil
        self.voice = nil
        self.attributionMode = .heuristic
        self.activePath = []
        self.cast = []
        self.speakerSelection = .roundRobin
        self.pendingSpeakerId = nil
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
        let decodedCharacterId = try c.decodeIfPresent(UUID.self, forKey: .characterId)
        let decodedCast = try c.decodeIfPresent([UUID].self, forKey: .cast) ?? []
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
        // Phase 8 §4.1 — cast-seeding migration. Maintains the invariant
        // `characterId non-nil implies characterId ∈ cast`. Triggers on any
        // decoded chat where `cast` is empty AND `characterId` is set —
        // that's the malformed state we want to fix regardless of stored
        // version (v3 legacy chats, plus v4 chats written before the
        // `characterId.didSet` observer was added). Idempotent: once cast
        // has been seeded, the explicit decoded value is trusted.
        if decodedCast.isEmpty, let cid = decodedCharacterId {
            cast = [cid]
        } else {
            cast = decodedCast
        }
        speakerSelection = try c.decodeIfPresent(SpeakerSelectionMode.self, forKey: .speakerSelection) ?? .roundRobin
        pendingSpeakerId = try c.decodeIfPresent(UUID.self, forKey: .pendingSpeakerId)
        schemaVersion = max(decodedVersion, 4)
        tokensSent = try c.decodeIfPresent(Int.self, forKey: .tokensSent) ?? 0
        tokensReceived = try c.decodeIfPresent(Int.self, forKey: .tokensReceived) ?? 0
        characterId = decodedCharacterId
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
        // Phase 8 §4.3 — promotion-gap heal. Solo→multi promotion (the
        // user adds a 2nd cast member to a chat with a history) leaves
        // the pre-promotion assistant turns carrying speakerId=nil,
        // which validateGroupChat would otherwise reject when cast.count
        // jumps to > 1. Stamp those legacy turns with characterId (or
        // cast.first as fallback) — semantically correct, since they
        // were spoken by the only character in the room at the time.
        // Already-stamped turns are preserved.
        if cast.count > 1, let primary = characterId ?? cast.first {
            for i in turns.indices {
                if turns[i].role == .assistant && turns[i].speakerId == nil {
                    turns[i].speakerId = primary
                }
            }
        }
        try Chat.validateGroupChat(cast: cast, turns: turns)

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

    /// Phase 8 deferred polish — move a cast member from one position
    /// to another. Out-of-bounds indices are silent no-ops (defensive
    /// against UI race conditions). Order matters because `cast`
    /// drives both round-robin selection order and the input-bar
    /// speaker picker order — reordering is the user's lever for
    /// "I want X to speak before Y in the rotation."
    mutating func reorderCast(from: Int, to: Int) {
        guard cast.indices.contains(from), cast.indices.contains(to), from != to else { return }
        let member = cast.remove(at: from)
        cast.insert(member, at: to)
    }

    /// Phase 8 deferred polish — collapse the cast down to a single
    /// kept member. Sets `characterId` to match the kept member so
    /// legacy single-character paths (PromptBuilder solo, voice routing,
    /// inspector tabs that read characterId) keep working. Pending
    /// speaker picks pointing at removed members are cleared. Existing
    /// turns' `speakerId`s are intentionally preserved — `validateGroupChat`
    /// is solo-tolerant (cast.count <= 1 → unrestricted speakerId), so
    /// archived turns from now-removed members still resolve to their
    /// original character at render / playback time. No-op when the
    /// kept id isn't a current cast member (defensive against UI races).
    mutating func convertToSolo(keeping kept: UUID) {
        guard cast.contains(kept) else { return }
        cast = [kept]
        characterId = kept
        if let pending = pendingSpeakerId, pending != kept {
            pendingSpeakerId = nil
        }
    }

    /// Phase 8 §4.5 — auto-create a stub `Entity` for `character` if no
    /// matching entity already exists. Idempotent: multiple calls with
    /// the same character produce one entity. Existing entities (from
    /// the extractor's suggestion path or hand-curated) take priority,
    /// so this never overwrites user state.
    ///
    /// 2026-05-09 enhancement: also seeds Facts from the card's
    /// structured details + intimacy data (`extensions["rpclient/details"]`
    /// and `["rpclient/intimacy"]`, with description-fence fallback).
    /// User reported expecting populated entities for new chats — the
    /// previous behaviour was a name-only stub. Backfills empty existing
    /// stubs (the on-disk Emily case from before this fix shipped) but
    /// never overwrites a user-curated entity that already has facts.
    ///
    /// The point: entity-name-matched voice routing (Phase 6 §7.3 +
    /// Phase 8 §4.5) needs an entity to exist before the user can
    /// assign a voice. Pre-§4.5, that entity was only created when the
    /// fact extractor fired AND the user accepted a suggestion — a
    /// multi-step manual loop. Auto-creating on cast-bind (newChat
    /// withCharacter / CastPane add) closes the gap so voices can be
    /// assigned the moment the character enters the room.
    ///
    /// `pinnedByUser = true` because this is intentional user action
    /// (they bound a card to a chat / added it to the cast), not an
    /// extractor guess. Pinning protects the entity from auto-merge /
    /// auto-evict policies later.
    mutating func ensureCharacterEntity(_ character: Character) {
        let trimmed = character.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let cardFacts = Chat.factsFromCard(character)
        if let matchedId = Speaker.matchCharacterToEntity(characterName: character.name, entities: entities) {
            // Existing entity — backfill ONLY when it has zero facts
            // AND we have facts to seed. User-curated entities (any
            // facts present) are never modified; entities the user
            // explicitly curated to empty (rare) are also preserved
            // because we can't distinguish "user emptied it" from
            // "stub from before this fix shipped" without a
            // provenance bit. The trade-off: existing-empty stubs
            // get one-time backfill the next time the user opens
            // the chat, after which they're idempotent.
            if !cardFacts.isEmpty,
               let idx = entities.firstIndex(where: { $0.id == matchedId }),
               entities[idx].facts.isEmpty {
                entities[idx].facts = cardFacts
            }
            return
        }
        entities.append(Entity(
            name: trimmed,
            type: .character,
            facts: cardFacts,
            pinnedByUser: true
        ))
    }

    /// Lift the character's structured fields (CardDetails +
    /// CardIntimacy) into Fact entries — one fact per non-empty
    /// field, formatted as `Key: value`. Reads from
    /// `extensions["rpclient/details"]` first, falling back to the
    /// `[character_details]` description fence; same for intimacy.
    /// Returns an empty array when the card has neither (legacy v1
    /// imports / cards from other tools without RPClient's structured
    /// extensions). Public so `AppState`-side migrations and tests can
    /// drive it directly.
    static func factsFromCard(_ character: Character) -> [Fact] {
        let details = CardDetails.extractFrom(character)
            ?? CardStructuredFence.parseDetails(in: character.description)
        let intimacy = CardIntimacy.extractFrom(character)
            ?? CardStructuredFence.parseIntimacy(in: character.description)
        var out: [Fact] = []
        if let d = details {
            for (key, value) in d.orderedFields where !value.isEmpty {
                out.append(Fact(text: "\(formatKey(key)): \(value)"))
            }
        }
        if let i = intimacy {
            for (key, value) in i.orderedFields where !value.isEmpty {
                out.append(Fact(text: "\(formatKey(key)): \(value)"))
            }
        }
        return out
    }

    /// Snake_case → Title-Cased. `turn_ons` → `Turn Ons`. The
    /// CardDetails / CardIntimacy ordered-fields keys are
    /// snake_case for fence compatibility; for facts we want
    /// human-readable labels.
    private static func formatKey(_ key: String) -> String {
        key.split(separator: "_")
            .map { $0.prefix(1).uppercased() + $0.dropFirst() }
            .joined(separator: " ")
    }

    /// Phase 8 §4.2a — read and clear `pendingSpeakerId` in one mutation,
    /// so the send path doesn't accidentally re-use a one-shot pick on the
    /// next generation. Returns the previous value (`nil` when nothing was
    /// queued); callers feed it through `SpeakerPicker.next(in:)`'s
    /// override path.
    @discardableResult
    mutating func consumePendingSpeaker() -> UUID? {
        let v = pendingSpeakerId
        pendingSpeakerId = nil
        return v
    }

    /// Phase 8 §4.1 — multi-cast invariants. Runs at decode time after the
    /// branching pass AND after the §4.3 promotion-gap heal (which stamps
    /// nil speakerIds on multi-cast chats with characterId / cast.first
    /// before validation runs). Throws a `DecodingError.dataCorrupted`
    /// describing the first violation. Tolerated cases (deliberate,
    /// exercised by tests):
    /// - empty cast (free-form chat) — no constraints on turns.
    /// - single-cast (legacy migrated chat) — assistant turns may carry nil
    ///   speakerId for back-compat with pre-Phase-8 storage.
    ///
    /// Enforced cases:
    /// - no duplicate UUIDs within `cast`.
    /// - on multi-cast (`cast.count > 1`), every assistant turn must carry a
    ///   non-nil `speakerId` resolving to a member of `cast`. Nil
    ///   speakerIds get healed at decode time so this throw is unreachable
    ///   from `init(from:)`; direct callers (tests, in-memory mutation
    ///   audits) still get the diagnostic.
    /// - user turns must NEVER carry a `speakerId` regardless of cast size
    ///   (user-side persona is on `Chat.personaId`, not on the turn).
    static func validateGroupChat(cast: [UUID], turns: [Turn]) throws {
        if Set(cast).count != cast.count {
            throw DecodingError.dataCorrupted(.init(
                codingPath: [],
                debugDescription: "duplicate UUID in cast: \(cast)"
            ))
        }

        for t in turns {
            if t.role == .user, t.speakerId != nil {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "user turn \(t.id) carries a non-nil speakerId; user-side persona belongs on Chat.personaId, not on the turn"
                ))
            }
        }

        guard cast.count > 1 else {
            // Solo / free-form chats: no further checks. Assistant turns may
            // carry nil speakerId (legacy migrated state).
            return
        }

        let castSet = Set(cast)
        for t in turns where t.role == .assistant {
            guard let sid = t.speakerId else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "assistant turn \(t.id) is missing a speakerId in a multi-cast chat (cast count \(cast.count))"
                ))
            }
            if !castSet.contains(sid) {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: [],
                    debugDescription: "assistant turn \(t.id) has speakerId \(sid) not present in cast \(cast)"
                ))
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
    ///
    /// Pre-Phase-7 callers passed an index into `chat.turns` which doubled
    /// as the renderable position. Under branching the two diverge; this
    /// overload remains for the linear-chat case (and existing tests) and
    /// resolves the id of the turn at `turnIndex` to delegate through the
    /// id-based variant. Returns false on out-of-bounds.
    func isVariantStale(turnIndex: Int, variantIndex: Int) -> Bool {
        guard turns.indices.contains(turnIndex) else { return false }
        return isVariantStale(turnId: turns[turnIndex].id, variantIndex: variantIndex)
    }

    /// Phase 7 §3.3b — branch-aware staleness check. Computes the fingerprint
    /// against the active-path prefix up to `turnId` rather than the storage
    /// order, so a turn forked alongside off-path siblings still gets the
    /// right baseline. If `turnId` isn't on the active path, falls back to
    /// the position in storage (matches pre-§3.3b semantics).
    func isVariantStale(turnId: UUID, variantIndex: Int) -> Bool {
        guard let turn = turn(id: turnId) else { return false }
        guard turn.variants.indices.contains(variantIndex) else { return false }
        guard let recorded = turn.variants[variantIndex].contextFingerprint else {
            return false
        }
        let prefix: [Turn]
        if let pos = activePosition(of: turnId) {
            prefix = Array(activeTurns.prefix(pos))
        } else if let storeIdx = turns.firstIndex(where: { $0.id == turnId }) {
            prefix = Array(turns.prefix(storeIdx))
        } else {
            return false
        }
        let live = Chat.makeContextFingerprint(prefix)
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

    /// Append `turn` as a child of the current active leaf. Sets the new
    /// turn's `parentId` to `activePath.last` (or `nil` when the chat is
    /// empty — root case), records the choice on the previous leaf's
    /// `activeChildId` so a later switch-away-and-back drills here, then
    /// extends `turns` and `activePath` by one.
    ///
    /// The single mutation primitive used by every production "append a turn"
    /// path (newChat seeding the greeting, sendUserMessage's user+assistant
    /// pair, regenerate's user-trailing fallback). Replaces the pre-§3.3a
    /// pattern of `c.turns.append(...)` which silently left `parentId` and
    /// `activePath` stale, relying on the renderable-list fallbacks in
    /// Chunker / RetrievalEngine to paper over the inconsistency. Forking
    /// off the active leaf is the §3.3b primitive (`Chat.fork`) — different
    /// shape, different file location.
    mutating func appendTurn(_ turn: Turn) {
        var t = turn
        t.parentId = activePath.last
        if let prevLeafId = activePath.last,
           let idx = turns.firstIndex(where: { $0.id == prevLeafId }) {
            turns[idx].activeChildId = t.id
        }
        turns.append(t)
        activePath.append(t.id)
    }

    /// Fork a new branch by adding `newTurn` as a child of `parentId`.
    /// Rewrites `newTurn.parentId` to `parentId` (so callers can pass a
    /// freshly-constructed turn without pre-wiring), records the choice on
    /// `parentId.activeChildId`, and rebuilds `activePath` as the
    /// path-from-root-to-`parentId` followed by the new turn. Off-path
    /// siblings stay in `turns` and remain reachable via `switchBranch`.
    ///
    /// No-op when `parentId` doesn't exist in `turns` — defensive guard for
    /// the AppState wrapper, where the UI nominally only fires on existing
    /// turns but state can race.
    ///
    /// summarizedThrough is clamped to the new path's length on the same
    /// rationale as `switchBranch` — see §3.2.D / V2_PHASE7_FULL_BRANCHING.md.
    mutating func fork(parentId: UUID, newTurn: Turn) {
        guard turns.contains(where: { $0.id == parentId }) else { return }

        // Walk parents from `parentId` up to root.
        var pathToRoot: [UUID] = []
        var cur: UUID? = parentId
        var safety = turns.count + 1
        while let id = cur {
            pathToRoot.append(id)
            safety -= 1
            if safety < 0 { return }
            cur = turns.first(where: { $0.id == id })?.parentId
        }
        let pathFromRoot = Array(pathToRoot.reversed())

        // Update each ancestor's activeChildId to point at its successor on
        // the new fork's path. Matches switchBranch's bookkeeping so a later
        // load lands here without further drill.
        for i in 0..<(pathFromRoot.count - 1) {
            let p = pathFromRoot[i]
            let child = pathFromRoot[i + 1]
            if let idx = turns.firstIndex(where: { $0.id == p }) {
                turns[idx].activeChildId = child
            }
        }

        var t = newTurn
        t.parentId = parentId
        if let idx = turns.firstIndex(where: { $0.id == parentId }) {
            turns[idx].activeChildId = t.id
        }
        turns.append(t)
        activePath = pathFromRoot + [t.id]
        if summarizedThrough > activePath.count {
            summarizedThrough = activePath.count
        }
    }

    /// Phase 7 §3.4 — every turn whose id appears in no other turn's
    /// parentId. Each leaf identifies the tail of one branch; the
    /// Branches inspector pane uses this list to render a row per
    /// branch. Order is unspecified — callers sort as needed (the
    /// Branches pane sorts active-first then by leaf ts descending).
    var leaves: [Turn] {
        guard !turns.isEmpty else { return [] }
        let parented = Set(turns.compactMap(\.parentId))
        return turns.filter { !parented.contains($0.id) }
    }

    /// Phase 7 §3.4 — lowest common ancestor between `leafId`'s
    /// path-to-root and `path`. Used to render "forked at TN" subtitles
    /// in the Branches pane (where TN is the divergence point's position
    /// on the active path). Returns the leaf itself when the leaf is on
    /// `path` (no divergence needed); returns nil if `leafId` isn't in
    /// `turns`.
    func divergencePoint(of leafId: UUID, against path: [UUID]) -> UUID? {
        guard turn(id: leafId) != nil else { return nil }
        let pathSet = Set(path)
        var cur: UUID? = leafId
        var safety = turns.count + 1
        while let id = cur {
            if pathSet.contains(id) { return id }
            safety -= 1
            if safety < 0 { return nil }
            cur = turn(id: id)?.parentId
        }
        return nil
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
