import Foundation

/// Phase 9 §5.4.c — pure-data review surface for the Mode 3 diff sheet.
/// Holds one `Row` per `CardFieldProposal`, tracking accept/reject
/// status, an explicit lock flag (so re-roll-all-unlocked can skip
/// fields the author wants preserved), and a per-field history stack
/// (last 3 candidates) so the author can compare and revert.
///
/// Lifted directly from research §6.2 (Inktomi93-pattern). The model
/// is `@MainActor` because the AppKit sheet binds to it; it carries no
/// presentation logic itself — the sheet observes `onChange` and
/// re-renders.

@MainActor
final class ProposalReviewModel {

    enum Status: Equatable {
        case proposed
        case accepted
        case rejected
    }

    struct Row: Equatable {
        let field: CardField
        var history: [String]
        var status: Status
        var locked: Bool
        let exemplarId: String
        let refusal: RefusalDetection

        var current: String { history.first ?? "" }
    }

    /// Per V2_PHASE9_AI_ASSIST_RESEARCH.md §6.2 — last 3 rolls per
    /// field. Older entries fall off the bottom on re-roll.
    static let historyDepth = 3

    private(set) var rows: [Row]
    var onChange: (() -> Void)?

    init(initial proposals: [CardFieldProposal]) {
        self.rows = proposals.map { p in
            Row(
                field: p.field,
                history: [p.text],
                status: .proposed,
                locked: false,
                exemplarId: p.exemplarId,
                refusal: p.refusal
            )
        }
    }

    // MARK: - Per-field actions

    func accept(_ field: CardField) {
        mutateRow(field) { row in
            row.status = .accepted
            row.locked = true
        }
    }

    func reject(_ field: CardField) {
        mutateRow(field) { row in
            row.status = .rejected
            row.locked = false
        }
    }

    func toggleLock(_ field: CardField) {
        mutateRow(field) { row in
            row.locked.toggle()
        }
    }

    /// Push a freshly-rolled candidate onto the field's history stack.
    /// Caps at `historyDepth`; resets status to `.proposed` since the
    /// previously-accepted value is no longer the current one.
    func pushCandidate(_ field: CardField, text: String) {
        mutateRow(field) { row in
            var hist = row.history
            hist.insert(text, at: 0)
            if hist.count > Self.historyDepth {
                hist = Array(hist.prefix(Self.historyDepth))
            }
            row.history = hist
            row.status = .proposed
        }
    }

    /// Promote `history[index]` to `history[0]`, preserving the
    /// relative order of the rest. No-op for out-of-range index.
    func revertTo(_ field: CardField, historyIndex index: Int) {
        mutateRow(field) { row in
            guard index >= 0, index < row.history.count, index != 0 else { return }
            let chosen = row.history.remove(at: index)
            row.history.insert(chosen, at: 0)
        }
    }

    // MARK: - Bulk actions

    func acceptAll() {
        for i in rows.indices {
            rows[i].status = .accepted
            rows[i].locked = true
        }
        onChange?()
    }

    func rejectAll() {
        for i in rows.indices {
            rows[i].status = .rejected
            rows[i].locked = false
        }
        onChange?()
    }

    // MARK: - Selectors

    /// Fields whose row is currently unlocked — the targets of a
    /// "Re-roll all unlocked" bulk action.
    var unlockedFields: [CardField] {
        rows.filter { !$0.locked }.map(\.field)
    }

    /// Proposals to commit on the author's final "Accept all" press.
    /// Each proposal carries the row's `current` value (which may have
    /// been replaced by a re-rolled candidate since the original).
    var acceptedProposals: [CardFieldProposal] {
        rows.compactMap { row in
            guard row.status == .accepted else { return nil }
            return CardFieldProposal(
                field: row.field,
                text: row.current,
                refusal: row.refusal,
                exemplarId: row.exemplarId
            )
        }
    }

    // MARK: - Internals

    private func mutateRow(_ field: CardField, _ mutate: (inout Row) -> Void) {
        guard let idx = rows.firstIndex(where: { $0.field == field }) else { return }
        mutate(&rows[idx])
        onChange?()
    }
}
