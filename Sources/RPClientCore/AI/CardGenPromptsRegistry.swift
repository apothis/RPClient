import Foundation

/// Phase 9 §5.4.a — bundled prompt template registry. Per
/// `V2_PHASE9_AI_ASSIST_RESEARCH.md` §11, the JSON schema is loaded at
/// app start and validated against this Codable type. JSON lives at
/// `Sources/RPClientCore/AI/Bundled/CardGenPrompts.json` and ships
/// inside `Bundle.module`.
///
/// Schema is intentionally lean: a single system prompt block (NSFW
/// license + output contract), per-style defaults (temperature +
/// max-tokens + an instruction template with `{humanName}` and
/// `{wordCount}` placeholders), and per-field metadata. Per-field
/// candidate-style overrides are supported but not required — most
/// fields just inherit the defaults with their own word-count target.
public struct CardGenPromptsRegistry: Codable, Sendable, Equatable {
    public let version: Int
    public let systemPrompt: String
    public let candidateDefaults: [String: CandidatePrompt]
    public let fields: [String: FieldPrompt]
}

public struct FieldPrompt: Codable, Sendable, Equatable {
    public let humanName: String
    public let wordCount: Int
    public let candidates: [String: CandidatePrompt]?
}

public struct CandidatePrompt: Codable, Sendable, Equatable {
    public let temperature: Double
    public let maxTokens: Int
    public let instruction: String
}

public enum CardGenPromptsLoader {
    public enum LoaderError: Error, CustomStringConvertible {
        case bundledResourceMissing
        case bundledResourceUnreadable(underlying: Error)
        case parseFailed(underlying: Error)

        public var description: String {
            switch self {
            case .bundledResourceMissing:
                return "CardGenPrompts.json not found in Bundle.module"
            case .bundledResourceUnreadable(let e):
                return "CardGenPrompts.json present but unreadable: \(e)"
            case .parseFailed(let e):
                return "CardGenPrompts.json malformed: \(e)"
            }
        }
    }

    /// Memoised — the registry is bundled and read-only, so loading
    /// once per session is the correct caching policy. The closure
    /// runs lazily; first access triggers the bundle read.
    public static let bundled: CardGenPromptsRegistry = {
        do {
            return try loadBundled()
        } catch {
            // Bundled resource being missing is a build-config bug,
            // not a runtime case the app can recover from. The
            // resource is shipped at compile-time. Surfacing as a
            // crash here makes the misconfiguration loud during
            // development; the test guard below catches it before
            // any release lands. (Same posture as `HelpIndex` — see
            // its loader for precedent.)
            fatalError("CardGenPromptsLoader: \(error)")
        }
    }()

    static func loadBundled() throws -> CardGenPromptsRegistry {
        guard let url = Bundle.module.url(forResource: "CardGenPrompts", withExtension: "json") else {
            throw LoaderError.bundledResourceMissing
        }
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw LoaderError.bundledResourceUnreadable(underlying: error)
        }
        return try parse(data)
    }

    public static func parse(_ data: Data) throws -> CardGenPromptsRegistry {
        do {
            return try JSONDecoder().decode(CardGenPromptsRegistry.self, from: data)
        } catch {
            throw LoaderError.parseFailed(underlying: error)
        }
    }
}
