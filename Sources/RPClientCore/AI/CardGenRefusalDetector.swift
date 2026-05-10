import Foundation

/// Phase 9 §5.4.a — refusal detector for AI-assist generation per
/// `V2_PHASE9_AI_ASSIST_RESEARCH.md` §8.3 (regex set across model
/// families) + §8.4 (uncensored-model softening).
///
/// Posture per research §8.1: precision-biased. A flagged candidate
/// still shows in the §4.1 strip with a yellow chip; the author can
/// hit Use anyway. A false positive costs one click; a false negative
/// ships a refusal into a card field. The asymmetry justifies the
/// bias toward false-positives.
public struct RefusalDetection: Equatable, Sendable {
    public let isRefusal: Bool
    public let pattern: RefusalPattern?

    public init(isRefusal: Bool, pattern: RefusalPattern?) {
        self.isRefusal = isRefusal
        self.pattern = pattern
    }
}

public enum RefusalPattern: String, Equatable, Sendable {
    case qwenStyle
    case llamaStyle
    case mistralStyle
    case genericApology
    case sanitizationMarker
    case lengthRatioApology
}

public enum CardGenRefusalDetector {

    // MARK: - Detection rules (first-match-wins, in priority order)

    /// Per research §8.3, ordered by specificity so the most-informative
    /// pattern attribution lands when a candidate matches multiple.
    private static let rules: [(pattern: RefusalPattern, regex: NSRegularExpression)] = {
        // Force-unwrap is OK on bundled compile-time-correct patterns;
        // a regex compile failure is a programming error caught by tests.
        func make(_ p: String) -> NSRegularExpression {
            try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
        }
        return [
            (
                .llamaStyle,
                make(#"^I\s+(cannot|can't)\s+fulfill\s+(this|your)\s+request"#)
            ),
            (
                .mistralStyle,
                make(#"^I('m|\s+am)\s+(uncomfortable|not\s+comfortable|not\s+going\s+to)"#)
            ),
            (
                .qwenStyle,
                make(#"^(As\s+(an?\s+)?(AI|language\s+model)|I\s+(cannot|can't)\s+(help|generate|provide))"#)
            ),
            (
                .genericApology,
                make(#"^(I('m|\s+am)\s+(sorry|unable|not\s+able)|I\s+can(not|'t)|I\s+(must|should|won't))"#)
            ),
            (
                .sanitizationMarker,
                // Anywhere in the candidate, not just the lead.
                make(#"\[(Content\s+removed|Sanitized|I\s+cannot\s+generate)[^\]]*\]"#)
            ),
        ]
    }()

    private static let apologyWords: Set<String> = [
        "sorry", "unable", "cannot", "can't", "inappropriate", "uncomfortable",
    ]

    private static let lengthRatioThreshold: Double = 0.25

    // MARK: - Public API

    public static func detect(candidate: String, expectedLengthChars: Int) -> RefusalDetection {
        if candidate.isEmpty {
            return RefusalDetection(isRefusal: false, pattern: nil)
        }

        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)

        // Ordered regex match — sanitization marker scans the whole body;
        // others anchor at the start so we trim leading whitespace first.
        for rule in rules {
            let scanRange = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
            if rule.regex.firstMatch(in: trimmed, options: [], range: scanRange) != nil {
                return RefusalDetection(isRefusal: true, pattern: rule.pattern)
            }
        }

        // Length-ratio + apology-word: catches short refusals that don't
        // start with a stock phrase.
        if expectedLengthChars > 0 {
            let ratio = Double(trimmed.count) / Double(expectedLengthChars)
            if ratio < lengthRatioThreshold {
                let lower = trimmed.lowercased()
                for word in apologyWords {
                    if lower.contains(word) {
                        return RefusalDetection(isRefusal: true, pattern: .lengthRatioApology)
                    }
                }
            }
        }

        return RefusalDetection(isRefusal: false, pattern: nil)
    }

    /// Per research §8.4 — known-uncensored / known-permissive model
    /// substring set. When a server hosts one of these, refusal-
    /// detection's user-facing copy softens toward "likely false
    /// positive — Use anyway?" rather than "switch the server".
    ///
    /// Substring set is conservative; new model lines drop in monthly
    /// and we'd rather miss a permissive model and surface the
    /// stronger copy than soften incorrectly on a safety-trained
    /// model that happens to contain one of these strings by
    /// coincidence.
    private static let uncensoredMarkers: [String] = [
        "uncensored", "abliterated", "dolphin", "noromaid",
        "airoboros", "lewd", "rocinante", "magnum-",
    ]

    public static func isLikelyUncensored(modelName: String) -> Bool {
        if modelName.isEmpty { return false }
        let lower = modelName.lowercased()
        return uncensoredMarkers.contains { lower.contains($0) }
    }
}
