import Foundation
@testable import RPClientCore

/// Phase 8 §4.2a — SpeakerPicker selection logic + storage additions.
///
/// Pure tests on the picker (no AppState, no LLM): builds in-memory chats
/// with explicit cast + turn sequences and checks who gets picked next.
/// Round-robin, pooled, and manual ship in §4.2; director returns nil
/// (deferred to §4.4) so the caller falls back to round-robin.
///
/// Also covers the storage additions that ride along: `Chat.pendingSpeakerId`
/// (consumed by manual mode) and `SceneSummary.summariesBySpeaker` (read by
/// PromptBuilder's lazy scene fill in §4.2b — this stage just adds the
/// field with a defaulting decoder).
func speakerPickerTests() -> TestSuite {
    let s = TestSuite("SpeakerPicker")

    let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        return e
    }()
    let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // Helper: build a multi-cast chat with the given turn shapes.
    // Each tuple is (role, speakerId-or-nil). Wires parents into a spine
    // and populates activePath to match storage so SpeakerPicker can read
    // the active history.
    func buildChat(cast: [UUID], turns shapes: [(TurnRole, UUID?)], pending: UUID? = nil, mode: SpeakerSelectionMode = .roundRobin) -> Chat {
        var c = Chat(title: "test")
        c.cast = cast
        c.speakerSelection = mode
        c.pendingSpeakerId = pending
        var built: [Turn] = []
        for (i, shape) in shapes.enumerated() {
            var t = Turn(role: shape.0, text: "t\(i)")
            t.speakerId = shape.1
            t.parentId = i > 0 ? built[i - 1].id : nil
            built.append(t)
        }
        c.turns = built
        c.activePath = built.map(\.id)
        return c
    }

    // MARK: - Round-robin

    s.test("roundRobin with no prior assistant turns picks cast[0]") {
        let a = UUID(), b = UUID(), cc = UUID()
        let chat = buildChat(cast: [a, b, cc], turns: [(.user, nil)])
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("roundRobin advances after each assistant turn") {
        let a = UUID(), b = UUID(), cc = UUID()
        // user → A's reply → user2 → next should be B
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, a),
            (.user, nil),
        ])
        try expectEqual(SpeakerPicker.next(in: chat), b)
    }

    s.test("roundRobin wraps from cast.last back to cast[0]") {
        let a = UUID(), b = UUID(), cc = UUID()
        // last assistant was C; next should wrap to A.
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, cc),
        ])
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("roundRobin treats unknown speakerId as no-prior — picks cast[0]") {
        let a = UUID(), b = UUID()
        let stranger = UUID()
        // Off-cast speakerId can't anchor the round-robin pointer; fall
        // back to cast[0] rather than crashing or skipping forward.
        let chat = buildChat(cast: [a, b], turns: [
            (.user, nil),
            (.assistant, stranger),
        ])
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("roundRobin returns nil on empty cast (free-form chat)") {
        let chat = buildChat(cast: [], turns: [(.user, nil)])
        try expectNil(SpeakerPicker.next(in: chat))
    }

    s.test("roundRobin on a solo cast always picks the only member") {
        let a = UUID()
        let chat = buildChat(cast: [a], turns: [
            (.user, nil),
            (.assistant, a),
            (.user, nil),
        ])
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("roundRobin uses the most recent assistant turn (skips trailing user)") {
        let a = UUID(), b = UUID(), cc = UUID()
        // Multiple user turns since the last assistant; the pointer is
        // anchored on the last assistant turn (B), not on user turns.
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, a),
            (.user, nil),
            (.assistant, b),
            (.user, nil),
            (.user, nil),
        ])
        try expectEqual(SpeakerPicker.next(in: chat), cc)
    }

    // MARK: - Pooled

    s.test("pooled with no one having spoken since last user picks cast[0]") {
        let a = UUID(), b = UUID(), cc = UUID()
        let chat = buildChat(cast: [a, b, cc], turns: [(.user, nil)], mode: .pooled)
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("pooled picks the first cast member who hasn't spoken in this round") {
        let a = UUID(), b = UUID(), cc = UUID()
        // A spoke after the user; pool = {B, C}; pick B (first in cast order).
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, a),
        ], mode: .pooled)
        try expectEqual(SpeakerPicker.next(in: chat), b)
    }

    s.test("pooled skips members already in this round, even out-of-order") {
        let a = UUID(), b = UUID(), cc = UUID()
        // B spoke first this round (manual override last turn), then A.
        // Pool = {C}; pick C.
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, b),
            (.assistant, a),
        ], mode: .pooled)
        try expectEqual(SpeakerPicker.next(in: chat), cc)
    }

    s.test("pooled resets after a user turn — next round starts fresh") {
        let a = UUID(), b = UUID(), cc = UUID()
        // Round 1 complete (A, B, C all spoke). New user turn arrives.
        // Pool resets to {A, B, C}; pick A again.
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, a),
            (.assistant, b),
            (.assistant, cc),
            (.user, nil),
        ], mode: .pooled)
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("pooled only looks back to the most recent user turn") {
        let a = UUID(), b = UUID(), cc = UUID()
        // History: …, user, A, B, C, user, A.
        // Most recent user turn is at position 4 (0-indexed). Spoken
        // since then: {A}. Pool = {B, C}; pick B.
        let chat = buildChat(cast: [a, b, cc], turns: [
            (.user, nil),
            (.assistant, a),
            (.assistant, b),
            (.assistant, cc),
            (.user, nil),
            (.assistant, a),
        ], mode: .pooled)
        try expectEqual(SpeakerPicker.next(in: chat), b)
    }

    s.test("pooled returns nil on empty cast") {
        let chat = buildChat(cast: [], turns: [(.user, nil)], mode: .pooled)
        try expectNil(SpeakerPicker.next(in: chat))
    }

    // MARK: - Manual

    s.test("manual returns pendingSpeakerId when set") {
        let a = UUID(), b = UUID()
        // Round-robin would pick A (no prior assistant); manual overrides.
        let chat = buildChat(cast: [a, b], turns: [(.user, nil)], pending: b, mode: .manual)
        try expectEqual(SpeakerPicker.next(in: chat), b)
    }

    s.test("manual falls back to round-robin when pendingSpeakerId is nil") {
        let a = UUID(), b = UUID()
        // No pending; expect round-robin behaviour (cast[0]).
        let chat = buildChat(cast: [a, b], turns: [(.user, nil)], pending: nil, mode: .manual)
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    s.test("manual ignores pendingSpeakerId pointing outside cast") {
        let a = UUID(), b = UUID()
        let stranger = UUID()
        // Defensive: pendingSpeakerId from stale UI state shouldn't break
        // selection. Treat as nil and round-robin instead.
        let chat = buildChat(cast: [a, b], turns: [(.user, nil)], pending: stranger, mode: .manual)
        try expectEqual(SpeakerPicker.next(in: chat), a)
    }

    // MARK: - Director (deferred to §4.4)

    s.test("director returns nil from the synchronous picker — caller falls back to round-robin") {
        let a = UUID(), b = UUID()
        let chat = buildChat(cast: [a, b], turns: [(.user, nil)], mode: .director)
        // Synchronous picker can't make the LLM side-call. Returns nil so
        // the caller (AppState send path) knows to fall back to round-robin
        // until §4.4 lands the async DirectorPicker.
        try expectNil(SpeakerPicker.next(in: chat))
    }

    // MARK: - consumePendingSpeaker

    s.test("consumePendingSpeaker returns + clears the value") {
        var chat = buildChat(cast: [UUID()], turns: [], pending: UUID())
        let original = chat.pendingSpeakerId
        let consumed = chat.consumePendingSpeaker()
        try expectEqual(consumed, original)
        try expectNil(chat.pendingSpeakerId)
    }

    s.test("consumePendingSpeaker on a chat with no pending value returns nil and is a no-op") {
        var chat = buildChat(cast: [UUID()], turns: [])
        try expectNil(chat.consumePendingSpeaker())
        try expectNil(chat.pendingSpeakerId)
    }

    // MARK: - Storage round-trip

    s.test("Chat.pendingSpeakerId encodes + decodes round-trip") {
        var chat = Chat(title: "x")
        let pid = UUID()
        chat.pendingSpeakerId = pid
        let data = try encoder.encode(chat)
        let again = try decoder.decode(Chat.self, from: data)
        try expectEqual(again.pendingSpeakerId, pid)
    }

    s.test("Chat.pendingSpeakerId defaults to nil on legacy decode") {
        let now = ISO8601DateFormatter().string(from: Date())
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "title": "Legacy",
            "created": "\(now)",
            "modified": "\(now)",
            "templateId": "gemma",
            "samplerPresetId": "balanced",
            "turns": []
        }
        """
        let chat = try decoder.decode(Chat.self, from: Data(json.utf8))
        try expectNil(chat.pendingSpeakerId)
    }

    // MARK: - SceneSummary.summariesBySpeaker

    s.test("SceneSummary.summariesBySpeaker round-trips when populated") {
        let speakerA = UUID()
        let speakerB = UUID()
        var scene = SceneSummary(text: "narrator view")
        scene.summariesBySpeaker = [
            speakerA: "what A remembers",
            speakerB: "what B remembers",
        ]
        let data = try encoder.encode(scene)
        let again = try decoder.decode(SceneSummary.self, from: data)
        try expectEqual(again.summariesBySpeaker?[speakerA], "what A remembers")
        try expectEqual(again.summariesBySpeaker?[speakerB], "what B remembers")
    }

    s.test("SceneSummary.summariesBySpeaker decodes nil when absent in JSON (legacy)") {
        // Legacy SceneSummary written before §4.2a — no summariesBySpeaker key.
        let json = """
        {
            "text": "narrator view"
        }
        """
        let scene = try decoder.decode(SceneSummary.self, from: Data(json.utf8))
        try expectNil(scene.summariesBySpeaker)
        try expectEqual(scene.text, "narrator view")
    }

    return s
}
