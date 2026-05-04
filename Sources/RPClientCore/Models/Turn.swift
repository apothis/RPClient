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

    init(
        id: UUID = UUID(),
        text: String,
        edited: Bool = false,
        ts: Date = Date(),
        samplerPresetId: String? = nil
    ) {
        self.id = id
        self.text = text
        self.edited = edited
        self.ts = ts
        self.samplerPresetId = samplerPresetId
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
        case id, role, text, edited, ts, variants, activeVariant
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
    mutating func addEmptyVariant(samplerPresetId: String? = nil) {
        variants.append(TurnVariant(text: "", samplerPresetId: samplerPresetId))
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
