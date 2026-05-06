import Foundation

enum TurnRole: String, Codable {
    case user
    case assistant
}

/// One alternative continuation of an assistant turn. Plural variants form
/// a "swipe" set: the user can page through them with ◀ / ▶ in the UI, and
/// the active one is mirrored to `Turn.text` so legacy readers (PromptBuilder,
/// retrieval, downgraded saves) keep working without knowing about variants.
struct TurnVariant: Codable, Identifiable, Equatable {
    let id: UUID
    var text: String
    var edited: Bool
    var ts: Date
    /// Sampler preset ID captured at generation time. Optional because legacy
    /// variants synthesised from `Turn.text` during decode have no record of
    /// it.
    var samplerPresetId: String?
    /// Stable hash of the turns above this one at generation time — see
    /// `Chat.makeContextFingerprint`. Compared against the live fingerprint
    /// to detect when an upstream edit / reorder / variant-swap on an
    /// earlier turn has invalidated the context this variant was generated
    /// against. `nil` on legacy variants (synthesised from `Turn.text` at
    /// decode time) and on hand-edited entries with no recorded provenance —
    /// treated as not-stale because we genuinely can't tell.
    var contextFingerprint: String?

    init(
        id: UUID = UUID(),
        text: String,
        edited: Bool = false,
        ts: Date = Date(),
        samplerPresetId: String? = nil,
        contextFingerprint: String? = nil
    ) {
        self.id = id
        self.text = text
        self.edited = edited
        self.ts = ts
        self.samplerPresetId = samplerPresetId
        self.contextFingerprint = contextFingerprint
    }
}

struct Turn: Codable, Identifiable, Equatable {
    let id: UUID
    var role: TurnRole
    /// Mirrored from `variants[activeVariant].text` on assistant turns and
    /// kept as the sole store on user turns. Mutating helpers on `Turn`
    /// (`appendToActiveVariant`, `setActiveVariantText`, `setActiveIndex`)
    /// keep the mirror in sync; assistant turns should not be mutated by
    /// writing to `text` directly once they have variants.
    var text: String
    var edited: Bool
    var ts: Date

    /// Alternative continuations for an assistant turn. Empty on user turns
    /// and on assistant turns that have not produced any reply yet (e.g. the
    /// freshly-appended placeholder before the first stream token lands).
    var variants: [TurnVariant]
    /// Index into `variants`. 0 when `variants` is empty.
    var activeVariant: Int

    /// Phase 7 §3.1 — parent turn in the chat's tree. nil on the root turn
    /// only. Pre-Phase-7 chats decode with this nil; `Chat.init(from:)`
    /// fills in spine-tree parents during the migration pass.
    var parentId: UUID?
    /// Phase 7 §3.1 — the most-recently-active child of this turn, used by
    /// `Chat.switchBranch(to:)` to drill to the right leaf when descending.
    /// nil = no preference yet, descend via earliest child by `ts`.
    var activeChildId: UUID?
    /// Phase 8 §4.1 — the cast member who spoke this turn. Nil for user
    /// turns (always) and for assistant turns in solo / free-form chats
    /// (where there is at most one possible speaker). Required to resolve
    /// to a member of `Chat.cast` on multi-cast chats; enforced at decode
    /// time by `Chat.validateGroupChat`.
    var speakerId: UUID?

    init(
        id: UUID = UUID(),
        role: TurnRole,
        text: String,
        edited: Bool = false,
        ts: Date = Date()
    ) {
        self.id = id
        self.role = role
        self.text = text
        self.edited = edited
        self.ts = ts
        self.parentId = nil
        self.activeChildId = nil
        self.speakerId = nil
        // Assistant turns with seed text get a matching variant straight
        // away. Empty assistant placeholders start with `variants = []`;
        // the first stream token populates the seed variant via
        // `appendToActiveVariant`. User turns never fan out.
        if role == .assistant && !text.isEmpty {
            self.variants = [TurnVariant(text: text, edited: edited, ts: ts)]
            self.activeVariant = 0
        } else {
            self.variants = []
            self.activeVariant = 0
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, role, text, edited, ts, variants, activeVariant, parentId, activeChildId, speakerId
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        role = try c.decode(TurnRole.self, forKey: .role)
        text = try c.decode(String.self, forKey: .text)
        edited = try c.decodeIfPresent(Bool.self, forKey: .edited) ?? false
        ts = try c.decode(Date.self, forKey: .ts)
        let decodedVariants = try c.decodeIfPresent([TurnVariant].self, forKey: .variants) ?? []
        let decodedActive = try c.decodeIfPresent(Int.self, forKey: .activeVariant) ?? 0
        if decodedVariants.isEmpty && role == .assistant && !text.isEmpty {
            // Pre-V2 chat: synthesize one variant from the legacy `text`.
            variants = [TurnVariant(text: text, edited: edited, ts: ts)]
            activeVariant = 0
        } else {
            variants = decodedVariants
            // Clamp defensively — a hand-edited JSON could leave activeVariant
            // pointing past the array.
            if decodedVariants.isEmpty {
                activeVariant = 0
            } else {
                activeVariant = max(0, min(decodedActive, decodedVariants.count - 1))
            }
        }
        parentId = try c.decodeIfPresent(UUID.self, forKey: .parentId)
        activeChildId = try c.decodeIfPresent(UUID.self, forKey: .activeChildId)
        speakerId = try c.decodeIfPresent(UUID.self, forKey: .speakerId)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(role, forKey: .role)
        try c.encode(text, forKey: .text)
        try c.encode(edited, forKey: .edited)
        try c.encode(ts, forKey: .ts)
        try c.encode(variants, forKey: .variants)
        try c.encode(activeVariant, forKey: .activeVariant)
        try c.encodeIfPresent(parentId, forKey: .parentId)
        try c.encodeIfPresent(activeChildId, forKey: .activeChildId)
        try c.encodeIfPresent(speakerId, forKey: .speakerId)
    }

    // MARK: - Variant mutation

    /// Append `tok` to the active variant's text, mirroring to `text`. If the
    /// turn has no variants yet (mid-stream placeholder), seeds one. This is
    /// the path used during generation streaming.
    mutating func appendToActiveVariant(_ tok: String) {
        if variants.isEmpty {
            variants = [TurnVariant(text: tok, ts: ts)]
            activeVariant = 0
        } else {
            variants[activeVariant].text += tok
        }
        text = variants[activeVariant].text
    }

    /// Replace the active variant's text outright. Marks the variant and the
    /// turn as edited.
    mutating func setActiveVariantText(_ newText: String) {
        if variants.isEmpty {
            variants = [TurnVariant(text: newText, edited: true, ts: ts)]
            activeVariant = 0
        } else {
            variants[activeVariant].text = newText
            variants[activeVariant].edited = true
        }
        text = newText
        edited = true
    }

    /// Append an empty variant and make it active. Used when starting a swipe
    /// regen so the previous variant is preserved alongside the new one.
    /// `contextFingerprint`, if set, is the hash of the turns above this one
    /// at generation time — see `Chat.makeContextFingerprint`. Stamped now
    /// (rather than at first stream token) because the model hasn't been
    /// asked anything yet but the prefix it'll see is already settled.
    mutating func addEmptyVariant(
        samplerPresetId: String? = nil,
        contextFingerprint: String? = nil
    ) {
        variants.append(TurnVariant(
            text: "",
            samplerPresetId: samplerPresetId,
            contextFingerprint: contextFingerprint
        ))
        activeVariant = variants.count - 1
        text = ""
    }

    /// Switch the active variant by absolute index. No-op if out of range or
    /// `variants` is empty.
    mutating func setActiveIndex(_ index: Int) {
        guard !variants.isEmpty, variants.indices.contains(index) else { return }
        activeVariant = index
        text = variants[index].text
    }
}
