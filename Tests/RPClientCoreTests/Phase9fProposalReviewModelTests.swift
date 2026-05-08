import Foundation
@testable import RPClientCore

private func proposal(_ field: CardField, _ text: String = "value") -> CardFieldProposal {
    CardFieldProposal(
        field: field,
        text: text,
        refusal: RefusalDetection(isRefusal: false, pattern: nil),
        exemplarId: "mira"
    )
}

func phase9fProposalReviewModelTests() -> TestSuite {
    let s = TestSuite("Phase9fProposalReviewModel")

    // MARK: - Initialisation

    s.test("init seeds one row per proposal in input order") {
        let model = ProposalReviewModel(initial: [
            proposal(.name, "Vexara"),
            proposal(.description, "A lamia matriarch."),
        ])
        try expectEqual(model.rows.count, 2)
        try expectEqual(model.rows[0].field, .name)
        try expectEqual(model.rows[1].field, .description)
    }

    s.test("init populates each row's history with the initial proposal text") {
        let model = ProposalReviewModel(initial: [proposal(.name, "Vexara")])
        try expectEqual(model.rows[0].history, ["Vexara"])
        try expectEqual(model.rows[0].current, "Vexara")
    }

    s.test("init defaults every row to .proposed status and unlocked") {
        let model = ProposalReviewModel(initial: [
            proposal(.name, "Vexara"),
            proposal(.description, "x"),
        ])
        for row in model.rows {
            try expectEqual(row.status, .proposed)
            try expectEqual(row.locked, false)
        }
    }

    // MARK: - Per-field accept / reject

    s.test("accept(field) marks row .accepted and locks it") {
        let model = ProposalReviewModel(initial: [proposal(.name)])
        model.accept(.name)
        try expectEqual(model.rows[0].status, .accepted)
        try expectEqual(model.rows[0].locked, true)
    }

    s.test("reject(field) marks row .rejected and unlocks it") {
        let model = ProposalReviewModel(initial: [proposal(.name)])
        model.accept(.name)  // locks first
        model.reject(.name)
        try expectEqual(model.rows[0].status, .rejected)
        try expectEqual(model.rows[0].locked, false)
    }

    s.test("accept on a non-existent field is a no-op (no crash)") {
        let model = ProposalReviewModel(initial: [proposal(.name)])
        model.accept(.description)  // not in the proposals
        try expectEqual(model.rows[0].status, .proposed)
    }

    // MARK: - Lock toggle

    s.test("toggleLock(field) flips lock state independently of status") {
        let model = ProposalReviewModel(initial: [proposal(.name)])
        try expectEqual(model.rows[0].locked, false)
        model.toggleLock(.name)
        try expectEqual(model.rows[0].locked, true)
        try expectEqual(model.rows[0].status, .proposed)
        model.toggleLock(.name)
        try expectEqual(model.rows[0].locked, false)
    }

    // MARK: - Bulk actions

    s.test("acceptAll() marks every row .accepted and locked") {
        let model = ProposalReviewModel(initial: [
            proposal(.name),
            proposal(.description),
            proposal(.personality),
        ])
        model.acceptAll()
        for row in model.rows {
            try expectEqual(row.status, .accepted)
            try expectEqual(row.locked, true)
        }
    }

    s.test("rejectAll() marks every row .rejected and unlocked") {
        let model = ProposalReviewModel(initial: [
            proposal(.name),
            proposal(.description),
        ])
        model.acceptAll()
        model.rejectAll()
        for row in model.rows {
            try expectEqual(row.status, .rejected)
            try expectEqual(row.locked, false)
        }
    }

    // MARK: - History stack

    s.test("pushCandidate prepends new value, cap stays at 3") {
        let model = ProposalReviewModel(initial: [proposal(.name, "v1")])
        model.pushCandidate(.name, text: "v2")
        try expectEqual(model.rows[0].history, ["v2", "v1"])
        try expectEqual(model.rows[0].current, "v2")
        model.pushCandidate(.name, text: "v3")
        try expectEqual(model.rows[0].history, ["v3", "v2", "v1"])
        // 4th push drops the oldest entry (cap at 3).
        model.pushCandidate(.name, text: "v4")
        try expectEqual(model.rows[0].history, ["v4", "v3", "v2"])
        try expectEqual(model.rows[0].current, "v4")
    }

    s.test("pushCandidate moves status back to .proposed (a re-roll is a fresh proposal)") {
        let model = ProposalReviewModel(initial: [proposal(.name, "v1")])
        model.accept(.name)
        try expectEqual(model.rows[0].status, .accepted)
        model.pushCandidate(.name, text: "v2")
        try expectEqual(model.rows[0].status, .proposed)
    }

    s.test("revertTo(historyIndex:) promotes the chosen entry to current and reorders") {
        let model = ProposalReviewModel(initial: [proposal(.name, "v1")])
        model.pushCandidate(.name, text: "v2")
        model.pushCandidate(.name, text: "v3")
        try expectEqual(model.rows[0].history, ["v3", "v2", "v1"])
        // Revert to history[2] ("v1").
        model.revertTo(.name, historyIndex: 2)
        try expectEqual(model.rows[0].current, "v1")
        // Order: chosen entry first, others preserved relative order.
        try expectEqual(model.rows[0].history, ["v1", "v3", "v2"])
    }

    s.test("revertTo with out-of-range index is a no-op") {
        let model = ProposalReviewModel(initial: [proposal(.name, "v1")])
        model.revertTo(.name, historyIndex: 5)
        try expectEqual(model.rows[0].current, "v1")
    }

    // MARK: - Bulk re-roll target selection

    s.test("unlockedFields returns fields whose row is unlocked") {
        let model = ProposalReviewModel(initial: [
            proposal(.name),
            proposal(.description),
            proposal(.personality),
        ])
        model.accept(.name)         // locks
        model.toggleLock(.personality)  // explicit lock
        try expectEqual(model.unlockedFields, [.description])
    }

    // MARK: - Commit collection

    s.test("acceptedProposals returns one proposal per .accepted row with current text") {
        let model = ProposalReviewModel(initial: [
            proposal(.name, "Vexara"),
            proposal(.description, "A lamia matriarch."),
            proposal(.personality, "Patient and watchful."),
        ])
        model.accept(.name)
        model.accept(.description)
        model.pushCandidate(.description, text: "Updated description.")
        // pushCandidate flips back to .proposed; re-accept.
        model.accept(.description)
        // .personality stays .proposed → not included.
        let accepted = model.acceptedProposals
        try expectEqual(accepted.count, 2)
        let nameP = accepted.first(where: { $0.field == .name })
        let descP = accepted.first(where: { $0.field == .description })
        try expectEqual(nameP?.text, "Vexara")
        try expectEqual(descP?.text, "Updated description.")
    }

    s.test("acceptedProposals excludes rejected rows even if they have history") {
        let model = ProposalReviewModel(initial: [
            proposal(.name, "Vexara"),
            proposal(.description, "x"),
        ])
        model.accept(.name)
        model.reject(.description)
        try expectEqual(model.acceptedProposals.count, 1)
        try expectEqual(model.acceptedProposals[0].field, .name)
    }

    // MARK: - Change notifications

    s.test("onChange fires after each mutation") {
        let model = ProposalReviewModel(initial: [proposal(.name)])
        var ticks = 0
        model.onChange = { ticks += 1 }
        model.accept(.name)
        model.reject(.name)
        model.toggleLock(.name)
        model.pushCandidate(.name, text: "v2")
        model.acceptAll()
        model.rejectAll()
        try expectEqual(ticks, 6)
    }

    return s
}
