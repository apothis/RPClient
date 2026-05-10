import Foundation
import CoreGraphics

/// V2_UI_OVERHAUL §4.8.6 / §4.g.3 — pure-data helpers for the
/// composer pill row's width-responsive collapse. Exposed as `enum`
/// + `struct` of static methods so behaviour can be unit-tested in
/// TestKit without standing up an NSWindow. The InputBar / FlowPillRow
/// own the actual view re-arrangement and just delegate the geometry
/// decisions here.
enum PillLayoutMode: Equatable {
    /// All pills inline on a single horizontal row. ≥ 900pt.
    case inline
    /// Pills greedy-flow into up to two horizontal rows. 700–899pt.
    case wrap
    /// Single `…` overflow opener; pills move into a popover stack.
    /// < 700pt.
    case collapsed
}

enum PillFlow {
    /// V2_UI_OVERHAUL §4.8.6 thresholds. The width that's measured is
    /// the InputBar's bounds.width (≈ chat-pane width minus the input
    /// pill's own outer margins). Boundaries inclusive at the upper
    /// end of each band so 900pt stays inline, 700pt stays wrap.
    static func mode(forWidth width: CGFloat) -> PillLayoutMode {
        if width >= 900 { return .inline }
        if width >= 700 { return .wrap }
        return .collapsed
    }

    /// Greedy left-to-right flow split. Walks `widths` placing each
    /// into the current row if it fits; otherwise starts a new row.
    /// Stops adding rows once `maxRows` is reached and returns the
    /// remaining indices as `overflow` (caller puts them in a `…`
    /// popover or drops them, per the layout mode).
    ///
    /// A single pill wider than `available` lands on its row anyway
    /// (overflowing horizontally) — better visual fallback than
    /// silently dropping it, and InputBar's max-width rules will
    /// usually prevent the situation.
    static func split(
        widths: [CGFloat],
        available: CGFloat,
        spacing: CGFloat,
        maxRows: Int
    ) -> (rows: [[Int]], overflow: [Int]) {
        guard maxRows >= 1 else { return ([], Array(widths.indices)) }
        guard !widths.isEmpty else { return ([], []) }

        var rows: [[Int]] = [[]]
        var rowWidth: CGFloat = 0

        for (i, w) in widths.enumerated() {
            let isFirstInRow = rows[rows.count - 1].isEmpty
            let needed = isFirstInRow ? w : rowWidth + spacing + w
            if needed <= available || isFirstInRow {
                rows[rows.count - 1].append(i)
                rowWidth = needed
            } else {
                if rows.count >= maxRows {
                    let overflow = Array(i..<widths.count)
                    return (rows, overflow)
                }
                rows.append([i])
                rowWidth = w
            }
        }
        return (rows, [])
    }
}
