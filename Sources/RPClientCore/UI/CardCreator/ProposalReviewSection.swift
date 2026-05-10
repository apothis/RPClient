import Foundation

/// Phase 9 §5.4.c follow-up — groups CardFields by the Card Creator
/// tab they live on, so the proposal-review sheet can offer the same
/// tab strip the editor uses. Lorebook and Advanced are excluded
/// because no AI-generated CardField lives there.
public enum ProposalReviewSection: String, CaseIterable, Hashable, Sendable {
    case identity
    case details
    case persona
    case intimacy
    case greetings
    case examples
    case system

    public var displayName: String {
        switch self {
        case .identity: return "Identity"
        case .details: return "Details"
        case .persona: return "Persona"
        case .intimacy: return "Intimacy"
        case .greetings: return "Greetings"
        case .examples: return "Examples"
        case .system: return "System"
        }
    }

    /// Authoritative membership list for this section. Order within
    /// each section matches the natural authoring order in the editor.
    public var fields: [CardField] {
        switch self {
        case .identity:
            return [
                .name, .nickname, .detailsSex, .detailsAge,
                .detailsPronouns, .detailsSpecies, .detailsOrientation,
            ]
        case .details:
            return [.detailsAppearance, .detailsMood]
        case .persona:
            return [.description, .personality, .scenario]
        case .intimacy:
            return [
                .intimacyBuild, .intimacyAnatomy, .intimacyMarkings,
                .intimacySensitivities, .intimacyScent, .intimacyTurnOns,
                .intimacyKinks, .intimacyLimits,
            ]
        case .greetings:
            return [.firstMessage, .alternateGreetings, .groupOnlyGreetings]
        case .examples:
            return [.messageExample]
        case .system:
            return [
                .systemPrompt, .postHistoryInstructions,
                .depthPrompt, .creatorNotes,
            ]
        }
    }

    public static func section(for field: CardField) -> ProposalReviewSection {
        for s in ProposalReviewSection.allCases where s.fields.contains(field) {
            return s
        }
        // Unreachable: the partitioning test guarantees every CardField
        // lives in exactly one section. A fatalError here makes drift
        // loud immediately if someone adds a CardField without updating
        // membership.
        fatalError("ProposalReviewSection: no section for CardField.\(field.rawValue) — update membership.")
    }
}
