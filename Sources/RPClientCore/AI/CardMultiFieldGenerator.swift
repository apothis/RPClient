import Foundation

/// Phase 9 §5.4.b — multi-field fill backend ("Fill missing fields"
/// per V2_PHASE9_CARD_CREATOR §4.7). Per
/// `V2_PHASE9_AI_ASSIST_RESEARCH.md` §3.4 + Probe 11 (~5s for 5
/// prose fields with cross-field coherence), the transport is a
/// single-call `response_format: json_schema` strict-mode request to
/// `/v1/chat/completions`. Sequential per-field is the fallback for
/// servers that don't honor structured output; capability is probed
/// once per session.
///
/// Build / parse split mirrors `CardGenSideCall` for the same testing
/// reasons — the pure-data transformations stay unit-testable; the
/// network orchestration lives in `CardMultiFieldOrchestrator`.

public struct CardFieldProposal: Sendable, Equatable {
    public let field: CardField
    public let text: String
    public let refusal: RefusalDetection
    public let exemplarId: String

    public init(
        field: CardField,
        text: String,
        refusal: RefusalDetection,
        exemplarId: String
    ) {
        self.field = field
        self.text = text
        self.refusal = refusal
        self.exemplarId = exemplarId
    }
}

struct CardMultiFieldRequest: Sendable {
    let fields: [CardField]
    /// System message — bundled NSFW license + output-contract +
    /// {{user}}/{{char}} convention from CardGenPrompts.json.
    let systemMessage: String
    /// User message — exemplar block + upstream block + per-field
    /// task list.
    let userMessage: String
    /// JSON schema for `response_format: json_schema`. Strict mode;
    /// every target field is required + min/max-length-bounded.
    /// Stored as `Data` (already-serialised JSON) so the call site
    /// can splice it into the request body without re-serialising.
    let schemaJSON: Data
    let schemaName: String
    let temperature: Double
    let maxTokens: Int
    let exemplarId: String
    /// Per-target expected length, fed to the refusal detector's
    /// length-ratio heuristic during parseResponse.
    let expectedLengths: [CardField: Int]
}

public enum CardMultiFieldParseError: Error, Equatable, CustomStringConvertible {
    case malformedJSON(String)
    case wrongShape(String)
    case missingRequiredField(CardField)

    public var description: String {
        switch self {
        case .malformedJSON(let raw):
            return "response is not valid JSON: \(raw.prefix(120))"
        case .wrongShape(let detail):
            return "response shape is wrong: \(detail)"
        case .missingRequiredField(let f):
            return "response missing required field: \(f.rawValue)"
        }
    }
}

enum CardMultiFieldGenerator {

    /// Build a request that will populate every `field` in one
    /// chat-completions call. Empty `fields` returns a request with
    /// an empty schema — caller should guard before firing.
    static func buildRequest(
        for fields: [CardField],
        draft: CardDraftSnapshot,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled
    ) -> CardMultiFieldRequest {
        let exemplar = CardGenExemplars.select(forTags: draft.tags)
        let exemplarBlock = CardFieldGenerator.renderExemplarBlock(exemplar: exemplar)

        // Union of upstreams across all targets, with the targets
        // themselves removed (the model is generating those — don't
        // feed the empty current values back in as upstream signals).
        var unionUpstreams: Set<CardFieldUpstream> = []
        let targetSet = Set(fields)
        for target in fields {
            for upstream in CardFieldDependencies.upstreams(for: target) {
                if case .field(let f) = upstream, targetSet.contains(f) { continue }
                unionUpstreams.insert(upstream)
            }
        }
        let upstreamBlock = CardFieldGenerator.renderUpstreams(unionUpstreams, draft: draft)

        // Per-target task list with humanName + word-count target.
        // Sorted by CardField.allCases order so the prompt prefix is
        // byte-stable across calls (KV-cache reuse).
        let targetsList = fields
            .sorted { lhsRaw, rhsRaw in
                let lhsIdx = CardField.allCases.firstIndex(of: lhsRaw) ?? Int.max
                let rhsIdx = CardField.allCases.firstIndex(of: rhsRaw) ?? Int.max
                return lhsIdx < rhsIdx
            }
            .map { field -> String in
                let entry = registry.fields[field.rawValue]
                let human = entry?.humanName ?? field.rawValue
                let words = entry?.wordCount ?? 30
                return "  - \(field.rawValue): \(human) (~\(words) words)"
            }
            .joined(separator: "\n")

        // Compose the user message. Format is intentionally similar
        // to the Mode 1 single-call prompt so KV-cache reuse works
        // when the same prefix is sent.
        let userMessage = [
            "EXAMPLE CHARACTER (anchor format and register):\n\(exemplarBlock)",
            upstreamBlock.isEmpty ? nil : "TARGET CHARACTER (current draft):\n\(upstreamBlock)",
            "Populate every field below in the JSON response. Each value should match the example's register and the target character's upstream details.\n\(targetsList)",
        ]
        .compactMap { $0 }
        .joined(separator: "\n\n")

        let (schemaData, expectedLengths) = buildSchema(for: fields, registry: registry)

        return CardMultiFieldRequest(
            fields: fields,
            systemMessage: registry.systemPrompt,
            userMessage: userMessage,
            schemaJSON: schemaData,
            schemaName: "card_multi_field",
            // Temperature lands between Mode 1's literal (0.4) and
            // creative (1.05). Multi-field is one shot per slot — too
            // hot and coherence drops; too cold and every field reads
            // as the same voice.
            temperature: 0.7,
            maxTokens: 2400,
            exemplarId: exemplar.id,
            expectedLengths: expectedLengths
        )
    }

    /// Parse the raw `message.content` from the chat-completions
    /// response. Expects valid JSON conforming to the schema
    /// generated by `buildSchema`. Returns one proposal per requested
    /// field, with refusal detection applied per-field.
    static func parseResponse(
        rawContent: String,
        request: CardMultiFieldRequest
    ) -> Result<[CardFieldProposal], CardMultiFieldParseError> {
        let cleaned = Markdown.stripThinking(rawContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = cleaned.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data),
              let object = parsed as? [String: Any]
        else {
            return .failure(.malformedJSON(cleaned))
        }

        var proposals: [CardFieldProposal] = []
        for field in request.fields {
            guard let raw = object[field.rawValue] else {
                return .failure(.missingRequiredField(field))
            }
            guard let str = raw as? String else {
                return .failure(.wrongShape("\(field.rawValue) is not a string"))
            }
            let expectedLen = request.expectedLengths[field] ?? 0
            let refusal = CardGenRefusalDetector.detect(
                candidate: str,
                expectedLengthChars: expectedLen
            )
            proposals.append(CardFieldProposal(
                field: field,
                text: str,
                refusal: refusal,
                exemplarId: request.exemplarId
            ))
        }
        return .success(proposals)
    }

    // MARK: - Schema builder

    /// Build a strict-mode JSON schema for the requested field set.
    /// Each property is type=string with min/max length bounds derived
    /// from the per-field word-count target (per
    /// `V2_PHASE9_AI_ASSIST_RESEARCH.md` Probe 11 — strict-mode
    /// length bounds are honoured by Qwen3.6 + KoboldCPP).
    ///
    /// Returns the serialised schema (so the call site doesn't
    /// re-encode) and the per-field expected-length lookup that the
    /// refusal detector uses.
    private static func buildSchema(
        for fields: [CardField],
        registry: CardGenPromptsRegistry
    ) -> (Data, [CardField: Int]) {
        var properties: [String: Any] = [:]
        var expectedLengths: [CardField: Int] = [:]
        for field in fields {
            let wordCount = registry.fields[field.rawValue]?.wordCount ?? 30
            // Loose bounds — minLength generous (the model can land
            // shorter than the target without us treating it as broken),
            // maxLength generous (8x word count covers verbose styles).
            let minLen = max(8, wordCount / 2)
            let maxLen = max(minLen + 200, wordCount * 8)
            properties[field.rawValue] = [
                "type": "string",
                "minLength": minLen,
                "maxLength": maxLen,
            ] as [String: Any]
            // expectedLengthChars for refusal detector ≈ words × 5.
            expectedLengths[field] = wordCount * 5
        }
        // Stable key ordering for the required array — JSONSerialization
        // doesn't guarantee key order in objects, but the array itself
        // is byte-stable when its element order is.
        let required = fields.sorted { lhs, rhs in
            (CardField.allCases.firstIndex(of: lhs) ?? .max)
                < (CardField.allCases.firstIndex(of: rhs) ?? .max)
        }.map(\.rawValue)
        let schema: [String: Any] = [
            "type": "object",
            "additionalProperties": false,
            "required": required,
            "properties": properties,
        ]
        // Compact serialisation; the outer chat-completions request body
        // doesn't need pretty-printing.
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return (data, expectedLengths)
    }
}
