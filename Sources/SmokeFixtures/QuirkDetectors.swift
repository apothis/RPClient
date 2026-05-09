import Foundation
@testable import RPClientCore

// Phase 10 §10.0.b+ — rule-based "weirdness" detectors. Each smoke
// calls the relevant `detectXxx(...)` per-fixture; the result is a
// list of ModelObservation entries that get appended to the
// per-exact-model log.
//
// Posture is precision-biased — same trade-off as
// `CardGenRefusalDetector`. A false positive shows up in the log as
// a real-looking quirk that turns out to be benign; the cost is
// triage time. A false negative ships a real quirk into production
// unflagged, where it surfaces as a chat-path bug. We bias toward
// flagging.
enum QuirkDetectors {

    /// Fraction of `expectedLengthChars` below which a non-empty
    /// response is reported as `shortReply`. Threshold matches
    /// `CardGenRefusalDetector.lengthRatioThreshold` so the two
    /// detectors agree on what "implausibly short" means.
    static let shortReplyRatio = 0.25

    /// Inspect a chat-smoke response and emit applicable observations.
    ///
    /// - `smoke`: typically "ChatSmoke" — recorded onto each observation.
    /// - `fixture`: fixture name (or `"real:<id>"` for --chat).
    /// - `response`: full assistant output post-streaming.
    /// - `expectedLengthChars`: rough target for "what a healthy reply
    ///   would look like" — currently the same 400 used by CardGen.
    /// - `promptEndsOnAssistant`: was the last verbatim turn an
    ///   assistant turn? When true, a short reply usually traces back
    ///   to the doubled-prefill issue (we generate a fresh assistant
    ///   block right after an existing one) — the remediation hint
    ///   surfaces this.
    /// - `castNamesOtherThanActive`: cohabitant display names in a
    ///   multi-cast chat, used to detect role confusion (response
    ///   prefixed with another cast member's name when the group
    ///   nudge said the active speaker should reply). Empty for solo
    ///   chats — the check is then a no-op.
    static func detectChat(
        smoke: String,
        fixture: String,
        response: String,
        expectedLengthChars: Int,
        promptEndsOnAssistant: Bool,
        castNamesOtherThanActive: [String]
    ) -> [ModelObservation] {
        var out: [ModelObservation] = []
        let now = Date()

        if response.isEmpty {
            out.append(ModelObservation(
                smoke: smoke, fixture: fixture, timestamp: now,
                kind: ObservationKind.noTokens,
                details: "stream returned no tokens",
                remediationHint: "check server reachability + that the prompt fits within max_context_length."
            ))
            // Nothing else to detect on an empty response.
            return out
        }

        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)

        // Length anomaly. Bias: only flag when expectedLengthChars > 0
        // (callers that don't have a sensible expectation pass 0 to opt out).
        if expectedLengthChars > 0 {
            let ratio = Double(trimmed.count) / Double(expectedLengthChars)
            if ratio < shortReplyRatio {
                let hint: String
                if promptEndsOnAssistant {
                    // continuation:true LOOKS like the right fix but
                    // empirically isn't on Qwen3.6 — it leaves the
                    // assistant turn semantically open and the model
                    // emits end-of-turn immediately on closed-feeling
                    // prose. The right fix is fixture-shape: end on
                    // a user turn that drives a substantive response.
                    hint = "Fixture ends on a non-empty assistant turn → the template emits one assistant block to close it and a second prefill block for generation. The model interprets the second block as 'next reply' and writes one — which is fine when the closing prose invites a continuation, but produces a one-liner when it doesn't (Mira's 'pace up' or a closing 'see you tomorrow'). Fix at the fixture level: end on a user turn that asks for a substantive next beat. (Note: continuation:true is NOT the fix — empirically it makes things worse on Qwen3.6 because the model treats the open turn as already done.)"
                } else {
                    hint = "Model emitted end-of-turn very early on a user-trailing prompt. Check sampler defaults (temperature too low / rep_pen too high), system-prompt tone (a system prompt ending in 'Stay concise' will produce one-liners), or whether the user turn itself is closing (e.g. 'see you tomorrow') rather than driving."
                }
                out.append(ModelObservation(
                    smoke: smoke, fixture: fixture, timestamp: now,
                    kind: ObservationKind.shortReply,
                    details: "\(trimmed.count) chars / ~\(expectedLengthChars) expected (ratio \(String(format: "%.2f", ratio)))",
                    remediationHint: hint
                ))
            }
        }

        // Refusal. Reuses CardGenRefusalDetector so the chat path and
        // card-gen path agree on what "refusal-shaped" means.
        let refusal = CardGenRefusalDetector.detect(
            candidate: trimmed,
            expectedLengthChars: expectedLengthChars
        )
        if refusal.isRefusal {
            out.append(ModelObservation(
                smoke: smoke, fixture: fixture, timestamp: now,
                kind: ObservationKind.refusal,
                details: "matched pattern: \(refusal.pattern?.rawValue ?? "?")",
                remediationHint: "If the model is meant to be permissive on this content axis, check whether the bundled NSFW-license phrase is present in the chat's system prompt; if so, this model's refusal posture is `aligned`. The chat path can soften refusal copy on `permissive` models per the §10.a ServerCapabilities.refusalPosture field."
            ))
        }

        // Thinking-trace leak in a finished output. Means either the
        // template didn't pre-fill the empty think block (so the
        // model emitted one) or KoboldCPP didn't strip it out of
        // the stream. Distinct from in-stream thinking which the
        // ThinkBlockFilter handles.
        if containsUnstrippedThinkBlock(trimmed) {
            out.append(ModelObservation(
                smoke: smoke, fixture: fixture, timestamp: now,
                kind: ObservationKind.thinkingTraceLeak,
                details: "finished response contains <think>…</think>",
                remediationHint: "Set capabilities.thinkingPrefill = .needed for this model so QwenTemplate emits the empty pre-fill. If the prefill was already emitted and the trace still leaked, the model is generating a SECOND think block after the empty one — flag for sampler/template review."
            ))
        }

        // Role confusion: response begins with another cast member's
        // display name (case-insensitive prefix match). Multi-cast
        // chats only — empty `castNamesOtherThanActive` no-ops.
        if !castNamesOtherThanActive.isEmpty {
            let lead = trimmed.prefix(80).lowercased()
            for name in castNamesOtherThanActive {
                let needle = name.lowercased() + ":"
                if lead.hasPrefix(needle) {
                    out.append(ModelObservation(
                        smoke: smoke, fixture: fixture, timestamp: now,
                        kind: ObservationKind.roleConfusionInGroup,
                        details: "response leads with '\(name):' (cohabitant), not the active speaker",
                        remediationHint: "Group-nudge alone isn't load-bearing on this model. Consider strengthening with a stop-sequence that includes other cast member name prefixes, or add an `[\(name) is silent for this turn]` directive when the user explicitly picks a speaker."
                    ))
                    break
                }
            }
        }
        return out
    }

    /// Detect `<think>...</think>` substring (case-insensitive). The
    /// finished-output equivalent of `ThinkBlockFilter`'s in-stream
    /// stripping. Used to flag cases where the runtime didn't filter
    /// the trace before completing the stream.
    static func containsUnstrippedThinkBlock(_ text: String) -> Bool {
        guard let re = try? NSRegularExpression(pattern: "(?is)<think>.*?</think>", options: []) else {
            return false
        }
        let range = NSRange(text.startIndex..., in: text)
        return re.firstMatch(in: text, options: [], range: range) != nil
    }
}
