import Foundation
import CoreGraphics
@testable import RPClientCore

/// V2_UI_OVERHAUL §4.8.6 / §4.g.3 — composer pill row width-
/// responsive collapse. Pure-data helpers that decide layout mode
/// from a width and split pill widths greedily into rows.
func phase11PillFlowTests() -> TestSuite {
    let s = TestSuite("Phase11PillFlow")

    // MARK: - Mode classification

    s.test("mode at width 1200 is inline (well above 900)") {
        try expectEqual(PillFlow.mode(forWidth: 1200), .inline)
    }

    s.test("mode at width 900 is inline (lower bound inclusive)") {
        try expectEqual(PillFlow.mode(forWidth: 900), .inline)
    }

    s.test("mode at width 899 is wrap (just below inline)") {
        try expectEqual(PillFlow.mode(forWidth: 899), .wrap)
    }

    s.test("mode at width 800 is wrap (mid-band)") {
        try expectEqual(PillFlow.mode(forWidth: 800), .wrap)
    }

    s.test("mode at width 700 is wrap (lower bound inclusive)") {
        try expectEqual(PillFlow.mode(forWidth: 700), .wrap)
    }

    s.test("mode at width 699 is collapsed (just below wrap)") {
        try expectEqual(PillFlow.mode(forWidth: 699), .collapsed)
    }

    s.test("mode at width 400 is collapsed (well below 700)") {
        try expectEqual(PillFlow.mode(forWidth: 400), .collapsed)
    }

    // MARK: - Greedy split

    s.test("empty widths yields empty rows + empty overflow") {
        let r = PillFlow.split(widths: [], available: 500, spacing: 8, maxRows: 2)
        try expectEqual(r.rows.count, 0)
        try expectEqual(r.overflow.count, 0)
    }

    s.test("all pills fit in one row when total width < available") {
        // 3 pills × 100pt + 2 gaps × 8pt = 316pt
        let r = PillFlow.split(widths: [100, 100, 100], available: 500, spacing: 8, maxRows: 2)
        try expectEqual(r.rows.count, 1)
        try expectEqual(r.rows[0], [0, 1, 2])
        try expectEqual(r.overflow.count, 0)
    }

    s.test("pills that overflow available width spill into row 2") {
        // 4 pills × 100pt; available 250 fits 2 + spacing (208) but not 3 (316).
        let r = PillFlow.split(widths: [100, 100, 100, 100], available: 250, spacing: 8, maxRows: 2)
        try expectEqual(r.rows.count, 2)
        try expectEqual(r.rows[0], [0, 1])
        try expectEqual(r.rows[1], [2, 3])
        try expectEqual(r.overflow.count, 0)
    }

    s.test("pills beyond maxRows capacity land in overflow") {
        // available 100 fits only 1 pill per row (each 80pt + 8pt spacing > 100).
        // 5 pills, maxRows=2 → rows take indices 0 and 1, rest (2,3,4) overflow.
        let r = PillFlow.split(widths: [80, 80, 80, 80, 80], available: 100, spacing: 8, maxRows: 2)
        try expectEqual(r.rows.count, 2)
        try expectEqual(r.rows[0], [0])
        try expectEqual(r.rows[1], [1])
        try expectEqual(r.overflow, [2, 3, 4])
    }

    s.test("a single pill wider than available still lands on its row") {
        // 200pt pill into 100pt slot — must not silently drop.
        let r = PillFlow.split(widths: [200], available: 100, spacing: 8, maxRows: 2)
        try expectEqual(r.rows.count, 1)
        try expectEqual(r.rows[0], [0])
        try expectEqual(r.overflow.count, 0)
    }

    s.test("maxRows of 1 with too many pills → overflow after row 1") {
        let r = PillFlow.split(widths: [100, 100, 100], available: 250, spacing: 8, maxRows: 1)
        try expectEqual(r.rows.count, 1)
        try expectEqual(r.rows[0], [0, 1])
        try expectEqual(r.overflow, [2])
    }

    s.test("spacing is honoured between pills on same row") {
        // 2 pills × 100pt = 200pt. With spacing 60: 100 + 60 + 100 = 260 > 250.
        // Without spacing: 200 ≤ 250 — would fit. So spacing must matter.
        let r = PillFlow.split(widths: [100, 100], available: 250, spacing: 60, maxRows: 2)
        try expectEqual(r.rows.count, 2)
        try expectEqual(r.rows[0], [0])
        try expectEqual(r.rows[1], [1])
    }

    return s
}
