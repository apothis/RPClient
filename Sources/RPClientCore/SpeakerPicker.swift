import Foundation

/// Phase 8 §4.2a — synchronous next-speaker resolver. Given a chat with a
/// non-empty `cast`, picks who speaks next per `chat.speakerSelection`,
/// honouring `pendingSpeakerId` overrides. Returns `nil` for chats that
/// can't resolve a speaker synchronously:
///
/// - empty cast (free-form / pre-Phase-8 chat — caller falls back to the
///   legacy `chat.characterId` path),
/// - `.director` mode (deferred to §4.4 — needs an async LLM side-call,
///   the caller should fall back to round-robin until then).
///
/// All modes ignore an out-of-cast `pendingSpeakerId` defensively (stale
/// UI state shouldn't break selection).
enum SpeakerPicker {
    /// The next speaker for a fresh assistant generation on this chat.
    /// Pure: depends only on `chat.cast`, `chat.speakerSelection`,
    /// `chat.pendingSpeakerId`, and the active turn list. Doesn't mutate;
    /// the caller is responsible for `chat.consumePendingSpeaker()` after
    /// using the override.
    static func next(in chat: Chat) -> UUID? {
        guard !chat.cast.isEmpty else { return nil }
        let castSet = Set(chat.cast)

        // Override path — applies to any mode. Manual is the primary user
        // of this slot, but other modes accept one-off picks too.
        if let pid = chat.pendingSpeakerId, castSet.contains(pid) {
            return pid
        }

        switch chat.speakerSelection {
        case .roundRobin, .manual:
            return roundRobinPick(cast: chat.cast, history: chat.activeTurns)
        case .pooled:
            return pooledPick(cast: chat.cast, history: chat.activeTurns)
        case .director:
            // §4.4 — async router LLM call. Sync picker can't make the
            // request, so signal "no sync answer" and the caller falls
            // back (round-robin in production via the AppState wrapper).
            return nil
        }
    }

    /// Cycle through `cast` in declaration order, anchored on the most
    /// recent assistant turn whose `speakerId` resolves to a cast member.
    /// No-prior, unknown speaker, or off-cast speaker → start at `cast[0]`.
    private static func roundRobinPick(cast: [UUID], history: [Turn]) -> UUID {
        guard let lastSpeakerIdx = lastAssistantSpeakerIndex(cast: cast, history: history) else {
            return cast[0]
        }
        return cast[(lastSpeakerIdx + 1) % cast.count]
    }

    /// Pick the first cast member who hasn't spoken in the current round
    /// (since the most recent user turn). When the round is full, fall
    /// back to round-robin so the next user turn restarts the pool.
    private static func pooledPick(cast: [UUID], history: [Turn]) -> UUID {
        let spoken = speakerIdsSinceLastUserTurn(cast: cast, history: history)
        for member in cast where !spoken.contains(member) {
            return member
        }
        // Pool exhausted mid-round (shouldn't normally happen between user
        // turns, but defensive). Fall through to round-robin from where we
        // left off.
        return roundRobinPick(cast: cast, history: history)
    }

    /// Index in `cast` of the most recent assistant turn's speaker.
    /// Walks backward through history; nil if no assistant turn has a
    /// resolvable speaker. Off-cast or nil `speakerId` is skipped, not
    /// treated as "anchor here," so a stray off-cast turn doesn't pin
    /// the round-robin pointer to an undefined slot.
    private static func lastAssistantSpeakerIndex(cast: [UUID], history: [Turn]) -> Int? {
        for t in history.reversed() where t.role == .assistant {
            if let sid = t.speakerId, let idx = cast.firstIndex(of: sid) {
                return idx
            }
        }
        return nil
    }

    /// Set of cast-member speakerIds that have spoken since the most
    /// recent user turn. Empty when the last turn is a user turn (round
    /// has just started) or when there have been no assistant turns yet.
    private static func speakerIdsSinceLastUserTurn(cast: [UUID], history: [Turn]) -> Set<UUID> {
        var spoken: Set<UUID> = []
        let castSet = Set(cast)
        for t in history.reversed() {
            if t.role == .user { break }
            if let sid = t.speakerId, castSet.contains(sid) {
                spoken.insert(sid)
            }
        }
        return spoken
    }
}
