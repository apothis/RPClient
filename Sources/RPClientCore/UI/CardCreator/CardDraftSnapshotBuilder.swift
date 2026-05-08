import Foundation

/// Phase 9 §5.4.a — bridge between `CharacterDraft` (mutable AppKit
/// working copy) and `CardDraftSnapshot` (frozen pure-data input to
/// the prompt builder + suggestions controller). The mapping is
/// straightforward: each `CardField` enum case picks the value out of
/// the draft's `Character` + structured details/intimacy.
///
/// Lives next to the draft, not next to the snapshot, because the
/// mapping is RPClient-shape-specific — `CardDraftSnapshot` is an
/// AI-layer type that doesn't know about `Character` / `CardDetails` /
/// `CardIntimacy`.
enum CardDraftSnapshotBuilder {

    static func snapshot(of draft: CharacterDraft) -> CardDraftSnapshot {
        let c = draft.character
        // extractFrom returns nil when neither extensions nor description-
        // fence carry the structured block; treat that as "no values"
        // rather than error.
        let details = CardDetails.extractFrom(c)
            ?? CardDetails()
        let intimacy = CardIntimacy.extractFrom(c)
            ?? CardIntimacy(build: "", anatomy: "", markings: "", sensitivities: "", scent: "", turnOns: "", kinks: "", limits: "")

        var fields: [CardField: String] = [:]

        // Top-level Character fields.
        write(&fields, .name, c.name)
        write(&fields, .nickname, c.nickname)
        write(&fields, .description, c.description)
        write(&fields, .personality, c.personality)
        write(&fields, .scenario, c.scenario)
        write(&fields, .firstMessage, c.firstMessage)
        write(&fields, .messageExample, c.messageExample)
        // Greetings + system / notes — list-shaped fields collapse to
        // the first entry for snapshot purposes (the strip's upstream
        // block doesn't need every greeting).
        write(&fields, .alternateGreetings, c.alternateGreetings.first)
        write(&fields, .groupOnlyGreetings, c.groupOnlyGreetings.first)
        write(&fields, .systemPrompt, c.systemPrompt)
        write(&fields, .postHistoryInstructions, c.postHistoryInstructions)
        write(&fields, .creatorNotes, c.creatorNotes)
        // depth_prompt lives inside extensions; pull from the structured
        // accessor when it lands. For now, leave nil so it doesn't
        // pollute the upstream block with default values.

        // §3.9 Details.
        write(&fields, .detailsSex, details.sex)
        write(&fields, .detailsAge, details.age)
        write(&fields, .detailsPronouns, details.pronouns)
        write(&fields, .detailsSpecies, details.species)
        write(&fields, .detailsOrientation, details.orientation)
        write(&fields, .detailsAppearance, details.appearance)
        write(&fields, .detailsMood, details.mood)

        // §3.9 Intimacy.
        write(&fields, .intimacyBuild, intimacy.build)
        write(&fields, .intimacyAnatomy, intimacy.anatomy)
        write(&fields, .intimacyMarkings, intimacy.markings)
        write(&fields, .intimacySensitivities, intimacy.sensitivities)
        write(&fields, .intimacyScent, intimacy.scent)
        write(&fields, .intimacyTurnOns, intimacy.turnOns)
        write(&fields, .intimacyKinks, intimacy.kinks)
        write(&fields, .intimacyLimits, intimacy.limits)

        return CardDraftSnapshot(tags: c.tags, fields: fields)
    }

    private static func write(_ fields: inout [CardField: String], _ key: CardField, _ value: String?) {
        guard let value, !value.isEmpty else { return }
        fields[key] = value
    }
}
