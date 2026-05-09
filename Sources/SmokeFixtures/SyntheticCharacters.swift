import Foundation
@testable import RPClientCore

// Phase 10 §10.0.a — synthetic Character fixtures for the model-
// interaction smoke harnesses. One Character per `CardGenExemplars`
// archetype so the smokes that need an upstream card (ChatSmoke,
// SummariserSmoke, BlurberSmoke) don't reinvent biographical detail
// per binary. UUIDs are hard-coded so cross-binary fixture references
// (chat.characterId / chat.cast pointing at SyntheticCharacters.X.id)
// stay stable across runs and the smokes' KV-cache prefixes don't
// flap. See V2_PHASE10_SMOKE_HARNESS_PLAN.md §1 / §10.0.a.
//
// These mirror the data already in `CardGenExemplars` (UI-side bundle
// for the AI-assist few-shot block); we shape it as `Character`
// objects here because the chat path consumes Character, not raw
// `CardGenExemplar` strings.
enum SyntheticCharacters {

    /// Stable UUID space. Hard-coded so a fixture chat's `characterId`
    /// resolves to the same character every run. Smokes that print
    /// model output cross-reference these in `--verbose` output, so
    /// drift here is visible in the smoke transcripts too.
    private enum IDs {
        static let mira         = UUID(uuidString: "10000000-0000-4000-8000-000000000001")!
        static let monstergirl  = UUID(uuidString: "10000000-0000-4000-8000-000000000002")!
        static let modern       = UUID(uuidString: "10000000-0000-4000-8000-000000000003")!
        static let spacer       = UUID(uuidString: "10000000-0000-4000-8000-000000000004")!
        static let biopunk      = UUID(uuidString: "10000000-0000-4000-8000-000000000005")!
        static let companion    = UUID(uuidString: "10000000-0000-4000-8000-000000000006")!
        static let domestic     = UUID(uuidString: "10000000-0000-4000-8000-000000000007")!
    }

    /// Frozen creation date so encode-decode round-trips don't drift on
    /// the seconds boundary. (ISO8601 strategy truncates to whole
    /// seconds; using `Date()` would silently fail equality tests
    /// depending on when the fixture was instantiated.)
    private static let frozenDate = Date(timeIntervalSince1970: 1_730_000_000)

    static let mira: Character = makeCharacter(
        id: IDs.mira,
        from: CardGenExemplars.mira,
        creatorNotes: "Safe baseline anchor — fantasy ranger; SFW-leading-NSFW. Use for refusal-baseline + cohabitant-brief checks."
    )

    static let monstergirl: Character = makeCharacter(
        id: IDs.monstergirl,
        from: CardGenExemplars.monstergirl,
        creatorNotes: "Non-human anatomy anchor. Lamia. Tag: monstergirl. NSFW explicit."
    )

    static let modern: Character = makeCharacter(
        id: IDs.modern,
        from: CardGenExemplars.modern,
        creatorNotes: "Contemporary, no-fantasy. Trans-masc journalist. Probes pronoun/identity handling."
    )

    static let spacer: Character = makeCharacter(
        id: IDs.spacer,
        from: CardGenExemplars.spacer,
        creatorNotes: "Hard sci-fi medic. Quiet register; tests cohabitant-brief truncation on dense profession prose."
    )

    static let biopunk: Character = makeCharacter(
        id: IDs.biopunk,
        from: CardGenExemplars.biopunk,
        creatorNotes: "Soft sci-fi / biopunk researcher. Lyrical register; tests model's voice-mimic on uncommon vocabulary."
    )

    static let companion: Character = makeCharacter(
        id: IDs.companion,
        from: CardGenExemplars.companion,
        creatorNotes: "Adult-entertainment professional anchor. NSFW-from-first-word; tests no-warmup explicit content."
    )

    static let domestic: Character = makeCharacter(
        id: IDs.domestic,
        from: CardGenExemplars.domestic,
        creatorNotes: "Domestic-intimate / girlfriend register. Shared apartment frame; tests sustained-relationship voice."
    )

    static let all: [(name: String, character: Character)] = [
        ("mira", mira),
        ("monstergirl", monstergirl),
        ("modern", modern),
        ("spacer", spacer),
        ("biopunk", biopunk),
        ("companion", companion),
        ("domestic", domestic),
    ]

    static func byName(_ name: String) -> Character? {
        all.first(where: { $0.name == name.lowercased() })?.character
    }

    // MARK: - Building

    /// Assemble a `Character` from a `CardGenExemplar`. The exemplar's
    /// `intimacy_*` keys land in `extensions["rpclient"]["intimacy"]` so
    /// round-tripping a fixture through Storage preserves the structured
    /// kink/build/sensitivity payload (fact-extractor + memory smokes
    /// pull from this).
    private static func makeCharacter(
        id: UUID,
        from ex: CardGenExemplar,
        creatorNotes: String
    ) -> Character {
        var intimacy: [String: JSONValue] = [:]
        for (k, v) in ex.fields where k.hasPrefix("intimacy_") {
            // Strip the `intimacy_` prefix so the nested object reads
            // {"build": "...", "kinks": "..."} rather than carrying the
            // legacy flat-namespace prefix into the JSON.
            let trimmed = String(k.dropFirst("intimacy_".count))
            intimacy[trimmed] = .string(v)
        }
        var details: [String: JSONValue] = [:]
        for (k, v) in ex.fields where k.hasPrefix("details_") {
            let trimmed = String(k.dropFirst("details_".count))
            details[trimmed] = .string(v)
        }
        let extensions: [String: JSONValue] = [
            "rpclient": .object([
                "intimacy": .object(intimacy),
                "details": .object(details),
            ]),
        ]
        return Character(
            id: id,
            name: ex.fields["name"] ?? ex.id,
            description: ex.fields["description"] ?? "",
            personality: ex.fields["personality"] ?? "",
            scenario: ex.fields["scenario"] ?? "",
            firstMessage: ex.fields["firstMessage"] ?? "",
            alternateGreetings: [],
            systemPrompt: ex.fields["systemPrompt"],
            postHistoryInstructions: nil,
            tags: Array(ex.tags).sorted(),
            creator: "SmokeFixtures",
            characterVersion: "1",
            charBook: [],
            created: frozenDate,
            messageExample: ex.fields["messageExample"] ?? "",
            creatorNotes: creatorNotes,
            extensions: extensions,
            nickname: nil,
            groupOnlyGreetings: [],
            source: ["smoke-fixture://card-gen-exemplars/\(ex.id)"],
            creatorNotesMultilingual: nil,
            creationDate: frozenDate,
            modificationDate: frozenDate
        )
    }
}
