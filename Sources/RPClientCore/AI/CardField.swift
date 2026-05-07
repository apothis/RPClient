import Foundation

/// Phase 9 §5.4.a — every card field that AI-assist can generate.
/// Raw values follow the snake_case convention used as keys in
/// `CardGenExemplars.fields`, `CardGenPrompts.json`, and the JSON-schema
/// shape for Mode 2/3 multi-field output. Drift between any of those
/// would silently break the prompt builder; the
/// `Phase9dCardFieldGraphTests` raw-value test guards against it.
public enum CardField: String, CaseIterable, Hashable, Sendable, Codable {
    // Identity (top-level)
    case name
    case nickname

    // Persona
    case description
    case personality
    case scenario

    // Voice
    case firstMessage = "first_message"
    case messageExample = "message_example"
    case alternateGreetings = "alternate_greetings"
    case groupOnlyGreetings = "group_only_greetings"

    // System / Notes
    case systemPrompt = "system_prompt"
    case postHistoryInstructions = "post_history_instructions"
    case depthPrompt = "depth_prompt"
    case creatorNotes = "creator_notes"

    // §3.9 Details
    case detailsAge = "details_age"
    case detailsPronouns = "details_pronouns"
    case detailsSpecies = "details_species"
    case detailsOrientation = "details_orientation"
    case detailsAppearance = "details_appearance"
    case detailsMood = "details_mood"

    // §3.9 Intimacy
    case intimacyBuild = "intimacy_build"
    case intimacyAnatomy = "intimacy_anatomy"
    case intimacyMarkings = "intimacy_markings"
    case intimacySensitivities = "intimacy_sensitivities"
    case intimacyScent = "intimacy_scent"
    case intimacyTurnOns = "intimacy_turn_ons"
    case intimacyKinks = "intimacy_kinks"
    case intimacyLimits = "intimacy_limits"
}

/// Upstream input for a generation prompt. Either another card field
/// (whose current value gets injected into the prompt context) or
/// `tags` — which is special because tags aren't a single value but
/// the card's full tag list, and almost every narrative-shaped field
/// has tags as an upstream signal.
public enum CardFieldUpstream: Hashable, Sendable {
    case field(CardField)
    case tags
}

/// The dependency graph from `V2_PHASE9_AI_ASSIST_RESEARCH.md` §4.2 +
/// `V2_PHASE9_CARD_CREATOR.md` §4.2. Direction of read: `node →
/// upstream-list`. A change to any listed upstream marks this field's
/// suggestion strip stale (§4.1) and means that field's current value
/// gets injected into the prompt's upstream-fields block (§3.2).
///
/// The graph is acyclic — each field can only depend on fields that
/// come before it in the natural authoring order. Tests enforce this.
public enum CardFieldDependencies {
    /// The four short Identity-tab facts (age / pronouns / species /
    /// orientation). Treated as a universal upstream bundle for the
    /// narrative fields below — the prompt builder skips empty values
    /// per `CardDraftSnapshotBuilder`, so cards that haven't filled
    /// these in just don't see them in the upstream block.
    private static let identityFacts: [CardFieldUpstream] = [
        .field(.detailsAge),
        .field(.detailsPronouns),
        .field(.detailsSpecies),
        .field(.detailsOrientation),
    ]

    public static func upstreams(for field: CardField) -> [CardFieldUpstream] {
        switch field {

        // MARK: - Cold-start fields (no upstream — author-set or bundled-default)

        case .intimacyLimits:
            // Hard nos are author intent, not derived. Generate produces
            // a generic starting list that the author edits.
            return []
        case .detailsAge, .detailsPronouns:
            // Usually author-set up front; AI-assist doesn't try to infer.
            return []

        // MARK: - Tags-only upstream

        case .name:
            // Cold-start: tags + bundled creative-license phrase.
            return [.tags]
        case .detailsSpecies:
            // Species is a tag-shaped concept; tags carry the signal.
            return [.tags]

        // MARK: - Identity / Persona

        case .nickname:
            return [.field(.name)]
        case .description:
            return [.field(.name), .tags] + identityFacts
        case .personality:
            return [.field(.name), .field(.description), .tags] + identityFacts
        case .scenario:
            return [.field(.name), .field(.description), .field(.personality), .tags] + identityFacts

        // MARK: - Voice

        case .firstMessage:
            return [
                .field(.name), .field(.description), .field(.personality),
                .field(.scenario), .tags,
            ] + identityFacts
        case .messageExample:
            return [
                .field(.name), .field(.description), .field(.personality),
                .tags,
            ] + identityFacts
        case .alternateGreetings:
            return [
                .field(.firstMessage), .field(.scenario), .field(.personality),
                .tags,
            ] + identityFacts
        case .groupOnlyGreetings:
            return [
                .field(.firstMessage), .field(.name), .field(.description),
                .tags,
            ] + identityFacts

        // MARK: - System / Notes

        case .systemPrompt:
            return [.field(.name), .field(.description), .field(.personality), .tags] + identityFacts
        case .postHistoryInstructions:
            return [.field(.systemPrompt), .field(.scenario)]
        case .depthPrompt:
            return [.field(.scenario), .field(.systemPrompt)]
        case .creatorNotes:
            return [
                .field(.name), .field(.description), .field(.personality),
                .field(.scenario), .tags,
            ] + identityFacts

        // MARK: - §3.9 Details

        case .detailsOrientation:
            return [.tags, .field(.detailsSpecies)]
        case .detailsAppearance:
            return [.field(.name), .tags, .field(.detailsSpecies), .field(.detailsAge)]
        case .detailsMood:
            return [.field(.name), .field(.personality), .tags]

        // MARK: - §3.9 Intimacy

        case .intimacyBuild:
            return [.field(.detailsSpecies), .field(.detailsAge), .tags]
        case .intimacyAnatomy:
            return [
                .field(.detailsSpecies), .field(.detailsAge),
                .field(.intimacyBuild), .tags,
            ]
        case .intimacyMarkings:
            return [.field(.intimacyBuild), .tags]
        case .intimacySensitivities:
            return [.field(.intimacyAnatomy), .tags]
        case .intimacyScent:
            return [.field(.detailsSpecies), .field(.intimacyBuild), .tags]
        case .intimacyTurnOns:
            return [.field(.personality), .tags, .field(.intimacyAnatomy)]
        case .intimacyKinks:
            return [.tags, .field(.intimacyTurnOns)]
        }
    }
}
