import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.a — `CardField` enum + `CardFieldDependencies` upstream
/// graph. The graph drives two things: (1) the §4.1 stale-badge logic
/// (an upstream change marks this field's strip stale) and (2) the
/// §4.2 prompt builder's upstream-fields block (which fields' current
/// values land in the prompt context for a given target field's
/// generation).
///
/// Source of truth: `V2_PHASE9_AI_ASSIST_RESEARCH.md` §4.2 (which is
/// itself a copy of `V2_PHASE9_CARD_CREATOR.md` §4.2, the original
/// design-doc graph).
func phase9dCardFieldGraphTests() -> TestSuite {
    let s = TestSuite("Phase9dCardFieldGraph")

    // MARK: - Coverage

    s.test("every CardField has a defined upstream entry") {
        // The dep graph is exhaustive — no field should fall through to
        // a default. Catches the mistake of adding a new CardField case
        // and forgetting to wire its upstreams.
        for field in CardField.allCases {
            // Pure call — must not crash, must return a defined result.
            _ = CardFieldDependencies.upstreams(for: field)
        }
    }

    s.test("CardField raw values follow the research-doc snake_case convention") {
        // Used as keys in CardGenExemplars.fields, in CardGenPrompts.json,
        // and in the prompt body. Drift between any of those three
        // would break the prompt builder silently.
        try expectEqual(CardField.firstMessage.rawValue, "first_message")
        try expectEqual(CardField.messageExample.rawValue, "message_example")
        try expectEqual(CardField.detailsAge.rawValue, "details_age")
        try expectEqual(CardField.intimacyTurnOns.rawValue, "intimacy_turn_ons")
        try expectEqual(CardField.systemPrompt.rawValue, "system_prompt")
    }

    // MARK: - Cold-start fields (no upstream, including no tags-upstream)

    s.test("intimacy_limits has no upstream — explicit author intent only") {
        // Per §4.2: 'limits' deliberately gets a bundled-defaults
        // treatment; AI-assist doesn't try to infer limits from other
        // fields (including tags) because the cost of a wrong
        // inference is high.
        let upstreams = CardFieldDependencies.upstreams(for: .intimacyLimits)
        try expectEqual(upstreams.count, 0)
    }

    s.test("details_age has tags upstream — usually author-set, but tags help") {
        let upstreams = CardFieldDependencies.upstreams(for: .detailsAge)
        try expectTrue(upstreams.contains(.tags))
    }

    s.test("details_pronouns has tags upstream — male/female/nonbinary etc are direct signals") {
        let upstreams = CardFieldDependencies.upstreams(for: .detailsPronouns)
        try expectTrue(upstreams.contains(.tags))
    }

    s.test("tags is upstream of every field except intimacy_limits") {
        // Tags carry strong genre / tone / kink signals; almost every
        // generated field benefits. The only deliberate exception is
        // intimacy_limits per the cold-start design above.
        let exceptions: Set<CardField> = [.intimacyLimits]
        for field in CardField.allCases where !exceptions.contains(field) {
            let upstreams = CardFieldDependencies.upstreams(for: field)
            try expectTrue(upstreams.contains(.tags),
                "\(field.rawValue) should have .tags as upstream")
        }
    }

    // MARK: - Tags-only upstream

    s.test("details_species depends on tags only (no field upstreams)") {
        let upstreams = CardFieldDependencies.upstreams(for: .detailsSpecies)
        try expectTrue(upstreams.contains(.tags), "details_species must have tags as upstream")
        let fieldUpstreams = upstreams.compactMap { u -> CardField? in
            if case .field(let f) = u { return f } else { return nil }
        }
        try expectEqual(fieldUpstreams.count, 0)
    }

    s.test("name depends on tags only (cold-start: tags or empty)") {
        let upstreams = CardFieldDependencies.upstreams(for: .name)
        try expectTrue(upstreams.contains(.tags))
        let fieldUpstreams = upstreams.compactMap { u -> CardField? in
            if case .field(let f) = u { return f } else { return nil }
        }
        try expectEqual(fieldUpstreams.count, 0)
    }

    // MARK: - Field+tags upstream — narrative fields

    s.test("description depends on [name] + tags + identity facts") {
        let upstreams = CardFieldDependencies.upstreams(for: .description)
        try expectTrue(upstreams.contains(.tags))
        try expectTrue(upstreams.contains(.field(.name)))
        // The Identity-tab facts are universal upstreams for narrative
        // fields — a 28-year-old's description should differ from a
        // 450-year-old's even with identical name + tags.
        try expectTrue(upstreams.contains(.field(.detailsAge)))
        try expectTrue(upstreams.contains(.field(.detailsPronouns)))
        try expectTrue(upstreams.contains(.field(.detailsSpecies)))
        try expectTrue(upstreams.contains(.field(.detailsOrientation)))
    }

    s.test("identity facts (age/pronouns/species/orientation) are upstream of every narrative field") {
        // Catches future regressions if anyone removes the
        // identityFacts bundle from a case.
        let narrativeFields: [CardField] = [
            .description, .personality, .scenario,
            .firstMessage, .messageExample,
            .alternateGreetings, .groupOnlyGreetings,
            .systemPrompt, .creatorNotes,
        ]
        for field in narrativeFields {
            let upstreams = CardFieldDependencies.upstreams(for: field)
            try expectTrue(upstreams.contains(.field(.detailsAge)),
                "\(field.rawValue) should have detailsAge upstream")
            try expectTrue(upstreams.contains(.field(.detailsSpecies)),
                "\(field.rawValue) should have detailsSpecies upstream")
        }
    }

    s.test("personality depends on [name, description] + tags") {
        let upstreams = CardFieldDependencies.upstreams(for: .personality)
        try expectTrue(upstreams.contains(.tags))
        try expectTrue(upstreams.contains(.field(.name)))
        try expectTrue(upstreams.contains(.field(.description)))
    }

    s.test("scenario depends on [name, description, personality] + tags") {
        let upstreams = CardFieldDependencies.upstreams(for: .scenario)
        try expectTrue(upstreams.contains(.field(.name)))
        try expectTrue(upstreams.contains(.field(.description)))
        try expectTrue(upstreams.contains(.field(.personality)))
        try expectTrue(upstreams.contains(.tags))
    }

    s.test("first_message depends on [name, description, personality, scenario] + tags") {
        let upstreams = CardFieldDependencies.upstreams(for: .firstMessage)
        try expectTrue(upstreams.contains(.field(.name)))
        try expectTrue(upstreams.contains(.field(.description)))
        try expectTrue(upstreams.contains(.field(.personality)))
        try expectTrue(upstreams.contains(.field(.scenario)))
        try expectTrue(upstreams.contains(.tags))
    }

    // MARK: - Structured intimacy graph

    s.test("intimacy_anatomy depends on [details_species, details_age, intimacy_build] + tags") {
        let upstreams = CardFieldDependencies.upstreams(for: .intimacyAnatomy)
        try expectTrue(upstreams.contains(.field(.detailsSpecies)))
        try expectTrue(upstreams.contains(.field(.detailsAge)))
        try expectTrue(upstreams.contains(.field(.intimacyBuild)))
        try expectTrue(upstreams.contains(.tags))
    }

    s.test("intimacy_kinks depends on [intimacy_turn_ons] + tags") {
        let upstreams = CardFieldDependencies.upstreams(for: .intimacyKinks)
        try expectTrue(upstreams.contains(.field(.intimacyTurnOns)))
        try expectTrue(upstreams.contains(.tags))
    }

    // MARK: - System / notes graph

    s.test("post_history_instructions depends on [system_prompt, scenario]") {
        let upstreams = CardFieldDependencies.upstreams(for: .postHistoryInstructions)
        try expectTrue(upstreams.contains(.field(.systemPrompt)))
        try expectTrue(upstreams.contains(.field(.scenario)))
    }

    s.test("depth_prompt depends on [scenario, system_prompt]") {
        let upstreams = CardFieldDependencies.upstreams(for: .depthPrompt)
        try expectTrue(upstreams.contains(.field(.scenario)))
        try expectTrue(upstreams.contains(.field(.systemPrompt)))
    }

    s.test("nickname depends on [name]") {
        let upstreams = CardFieldDependencies.upstreams(for: .nickname)
        try expectTrue(upstreams.contains(.field(.name)))
    }

    // MARK: - No self-cycles

    s.test("no field is its own upstream") {
        for field in CardField.allCases {
            let upstreams = CardFieldDependencies.upstreams(for: field)
            for u in upstreams {
                if case .field(let f) = u {
                    try expectFalse(f == field, "\(field) lists itself as upstream")
                }
            }
        }
    }

    // MARK: - Acyclic

    s.test("dependency graph is acyclic") {
        // Topological sort should succeed; if any field's upstream
        // chain eventually loops back, we'd get an error.
        var visited: Set<CardField> = []
        var stack: Set<CardField> = []

        func visit(_ field: CardField) throws {
            if stack.contains(field) {
                throw TestFailure(
                    message: "cycle through \(field)",
                    file: #file, line: #line
                )
            }
            if visited.contains(field) { return }
            stack.insert(field)
            for upstream in CardFieldDependencies.upstreams(for: field) {
                if case .field(let f) = upstream {
                    try visit(f)
                }
            }
            stack.remove(field)
            visited.insert(field)
        }

        for field in CardField.allCases {
            try visit(field)
        }
    }

    return s
}
