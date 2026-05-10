import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.c follow-up — review-sheet tab strip groups proposals
/// by Card Creator tab. Only sections that own at least one CardField
/// belong; Lorebook / Advanced are excluded because they own no AI-
/// generated fields.
func phase9fProposalReviewSectionTests() -> TestSuite {
    let s = TestSuite("Phase9fProposalReviewSection")

    s.test("every CardField resolves to a section (no crashes / no defaults)") {
        for f in CardField.allCases {
            _ = ProposalReviewSection.section(for: f)
        }
    }

    s.test("section ordering matches Card Creator tab order") {
        let expected: [ProposalReviewSection] = [
            .identity, .details, .persona, .intimacy, .greetings, .examples, .system,
        ]
        try expectEqual(ProposalReviewSection.allCases, expected, "section order")
    }

    s.test("Identity section owns the 7 identity-tab fields") {
        try assertMembership(.identity, [
            .name, .nickname, .detailsSex, .detailsAge, .detailsPronouns,
            .detailsSpecies, .detailsOrientation,
        ])
    }

    s.test("Details section owns detailsAppearance + detailsMood") {
        try assertMembership(.details, [.detailsAppearance, .detailsMood])
    }

    s.test("Persona section owns description / personality / scenario") {
        try assertMembership(.persona, [.description, .personality, .scenario])
    }

    s.test("Intimacy section owns the 8 intimacy fields") {
        try assertMembership(.intimacy, [
            .intimacyBuild, .intimacyAnatomy, .intimacyMarkings,
            .intimacySensitivities, .intimacyScent, .intimacyTurnOns,
            .intimacyKinks, .intimacyLimits,
        ])
    }

    s.test("Greetings section owns firstMessage / alternateGreetings / groupOnlyGreetings") {
        try assertMembership(.greetings, [
            .firstMessage, .alternateGreetings, .groupOnlyGreetings,
        ])
    }

    s.test("Examples section owns messageExample") {
        try assertMembership(.examples, [.messageExample])
    }

    s.test("System section owns systemPrompt / PHI / depthPrompt / creatorNotes") {
        try assertMembership(.system, [
            .systemPrompt, .postHistoryInstructions, .depthPrompt, .creatorNotes,
        ])
    }

    s.test("union of every section's fields covers every CardField exactly once") {
        var seen: [CardField: ProposalReviewSection] = [:]
        for s in ProposalReviewSection.allCases {
            for f in s.fields {
                if let prior = seen[f] {
                    throw TestFailure(
                        message: "\(f.rawValue) appears in both \(prior) and \(s)",
                        file: #file, line: #line
                    )
                }
                seen[f] = s
            }
        }
        try expectEqual(seen.count, CardField.allCases.count, "field coverage count")
    }

    s.test("displayName matches the Card Creator tab label") {
        let expected: [(ProposalReviewSection, String)] = [
            (.identity, "Identity"),
            (.details, "Details"),
            (.persona, "Persona"),
            (.intimacy, "Intimacy"),
            (.greetings, "Greetings"),
            (.examples, "Examples"),
            (.system, "System"),
        ]
        for (sec, label) in expected {
            try expectEqual(sec.displayName, label, "displayName for \(sec)")
        }
    }

    return s
}

@MainActor
private func assertMembership(
    _ section: ProposalReviewSection,
    _ expected: Set<CardField>
) throws {
    let actual = Set(section.fields)
    try expectEqual(actual, expected, "\(section) membership")
    for f in expected {
        try expectEqual(
            ProposalReviewSection.section(for: f),
            section,
            "\(f.rawValue) section lookup"
        )
    }
}
