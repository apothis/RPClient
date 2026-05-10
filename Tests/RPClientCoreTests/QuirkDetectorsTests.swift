import Foundation
@testable import RPClientCore
@testable import SmokeFixtures

// Phase 10 §10.0.b+ — tests for the rule-based quirk detectors that
// each smoke calls after a fixture completes. These convert raw
// model output into ModelObservation entries for the per-model log.
//
// Detectors must be:
//   1. Cheap (run after every fixture; budget ≪ generation time).
//   2. Precision-biased (false positive = noise in the log; false
//      negative = real bug ships unflagged. Same trade-off as
//      CardGenRefusalDetector.)
//   3. Stateless (no shared mutation; one detector call per fixture).
func quirkDetectorsTests() -> TestSuite {
    let s = TestSuite("QuirkDetectors")

    s.test("noTokens fires on empty response") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "x",
            response: "", expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: []
        )
        try expectTrue(out.contains(where: { $0.kind == ObservationKind.noTokens }))
    }

    s.test("shortReply fires when response far below expected") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "x",
            response: "ok.", expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: []
        )
        try expectTrue(out.contains(where: { $0.kind == ObservationKind.shortReply }))
    }

    s.test("shortReply does NOT fire on plausible-length response") {
        let response = String(repeating: "a", count: 300)
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "x",
            response: response, expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: []
        )
        try expectFalse(out.contains(where: { $0.kind == ObservationKind.shortReply }))
    }

    s.test("shortReply on assistant-trailing prompt suggests continuation fix") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "sfw-long",
            response: "ok.", expectedLengthChars: 400,
            promptEndsOnAssistant: true,
            castNamesOtherThanActive: []
        )
        let hit = try expectNotNil(out.first(where: { $0.kind == ObservationKind.shortReply }))
        let hint = try expectNotNil(hit.remediationHint)
        try expectTrue(hint.lowercased().contains("continuation"), "hint should mention continuation fix")
    }

    s.test("refusal fires on stock refusal phrase") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "x",
            response: "I cannot fulfill this request.",
            expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: []
        )
        try expectTrue(out.contains(where: { $0.kind == ObservationKind.refusal }))
    }

    s.test("thinkingTraceLeak fires on un-stripped think tag") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "x",
            response: "<think>let me consider</think>\n\nok then.",
            expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: []
        )
        try expectTrue(out.contains(where: { $0.kind == ObservationKind.thinkingTraceLeak }))
    }

    s.test("roleConfusion fires when response begins with another cast member's name") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "group-chat",
            response: "Rae Lindhart: *She leans back into Cass.* Ready.",
            expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: ["Rae Lindhart", "Alex Rivers"]
        )
        try expectTrue(out.contains(where: { $0.kind == ObservationKind.roleConfusionInGroup }))
    }

    s.test("roleConfusion does NOT fire when response starts with prose") {
        let out = QuirkDetectors.detectChat(
            smoke: "ChatSmoke", fixture: "group-chat",
            response: "*She leans back.* Ready.",
            expectedLengthChars: 400,
            promptEndsOnAssistant: false,
            castNamesOtherThanActive: ["Rae Lindhart", "Alex Rivers"]
        )
        try expectFalse(out.contains(where: { $0.kind == ObservationKind.roleConfusionInGroup }))
    }

    return s
}
