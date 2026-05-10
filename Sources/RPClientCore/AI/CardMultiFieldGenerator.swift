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
    ///
    /// `authorDirection` is the §5.4.c Mode 3 seed input: a free-form
    /// one-liner describing the character ("an aging archivist who
    /// keeps to themselves in a port town"). When non-empty it lands
    /// at the top of the user message as an AUTHOR DIRECTION block so
    /// every pass anchors on the same concept.
    static func buildRequest(
        for fields: [CardField],
        draft: CardDraftSnapshot,
        registry: CardGenPromptsRegistry = CardGenPromptsLoader.bundled,
        authorDirection: String? = nil
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
        let trimmedDirection = authorDirection?.trimmingCharacters(in: .whitespacesAndNewlines)
        let directionBlock = (trimmedDirection?.isEmpty == false)
            ? "AUTHOR DIRECTION (load-bearing — match it exactly):\n\"\(trimmedDirection!)\"\n\nIf the direction names a specific character (e.g. \"Gemma is a 19-year-old courtesan…\"), the `name` field MUST use that exact name. Do NOT invent a substitute. Other concrete facts (age, occupation, setting) stated in the direction are also load-bearing — preserve them in their respective fields."
            : nil
        // Exemplar's name — surfaced explicitly in the rules so the
        // model has a clear "do NOT copy this" anchor. Caught on §5.4.c
        // smoke where the companion/domestic lanes copied "Rae Lindhart"
        // / "Cass Wheeler" verbatim because the hint described the
        // same archetype as the exemplar.
        let exemplarName = exemplar.fields["name"] ?? exemplar.id
        let userMessage = [
            directionBlock,
            "EXAMPLE CHARACTER (a DIFFERENT character — study format and register; do NOT copy names, descriptions, or any other content verbatim):\n\(exemplarBlock)",
            upstreamBlock.isEmpty ? nil : "TARGET CHARACTER (current draft):\n\(upstreamBlock)",
            // Explicit anti-leak instructions — caught on §5.4.c live
            // smoke (biopunk lane) where the model emitted the exemplar
            // block's "key: value" lines as the JSON value of the first
            // field, including all other fields' content stuffed in.
            // The companion/domestic lanes also copied the exemplar's
            // name and description verbatim when the hint described
            // the same archetype.
            "Populate every field below in the JSON response. Rules:\n  - Generate a NEW character. The example character is named \"\(exemplarName)\"; the TARGET character must have a different name (UNLESS the AUTHOR DIRECTION specifies a name — then use the direction's name verbatim, even if it happens to match the example).\n  - Each JSON value contains ONLY that field's content — no field-name prefix, no other fields' content, no `key: value` lines copied from the example.\n  - Match the example's REGISTER (voice, level of detail, NSFW posture) but invent fresh content. Reword every sentence; do not paraphrase the example.\n  - REPLACE every concrete detail from the example with a freshly-invented one. This includes proper nouns (ship names, station names, neighborhoods, agencies), specific numbers/schedules ('two nights a week', 'three years', 'four hundred and fifty years'), specific habits ('two espresso shots before any meeting', 'pottery class'), and specific phrases. NO sequence of more than four consecutive words may appear verbatim from the example. Borrow the SHAPE ('orbital hospital ship NAME-N', 'has worked at AGENCY for SOME years'), not the specifics.\n  - The AUTHOR DIRECTION is load-bearing. Names, ages, occupations, and settings stated in it MUST appear in the corresponding fields verbatim — do not invent substitutes.\n\nFields to populate:\n\(targetsList)",
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
            guard let raw = raw as? String else {
                return .failure(.wrongShape("\(field.rawValue) is not a string"))
            }
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let expectedLen = request.expectedLengths[field] ?? 0
            // Models occasionally pad short-field outputs to hit the
            // schema's maxLength ceiling — observed on §5.4.c biopunk
            // (`name` = "Anya Sorel\n\n\n…" with 198 newlines) and
            // companion (`name` = "Nyla Voss\n\nMila Chen\n\nElara
            // Vance\n\n…" listing five candidates). Two-stage clean:
            // first strip leading/trailing whitespace, then for short
            // fields (wordCount ≤ 4 ⇒ expectedLen ≤ 20) take only the
            // first non-empty line. Prose fields keep their full text
            // (legitimate multi-line content like message_example).
            let str: String
            if expectedLen <= 20, let firstLine = trimmed.split(separator: "\n").first {
                str = String(firstLine).trimmingCharacters(in: .whitespacesAndNewlines)
            } else {
                str = trimmed
            }
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

    /// Plaintext fallback when the model ignores the json_schema and
    /// returns newline-separated values (live failure mode caught with
    /// Qwen3.6: response was `Gemma\nGem\nFemale\n19\nshe/her\nHuman\n
    /// bisexual` for the 7 Identity-pass targets). Used by the autopilot
    /// orchestrator after JSON parsing has been retried twice without
    /// success — better to recover with a degraded parse than abort the
    /// entire run.
    ///
    /// Strategy: strip a thinking trace, split on newlines, drop blank
    /// lines, strip a leading `fieldname:` prefix per line if present,
    /// then map line N → request.fields[N]. Fails if there are fewer
    /// non-empty lines than requested fields.
    static func parseResponseAsPlaintext(
        rawContent: String,
        request: CardMultiFieldRequest
    ) -> Result<[CardFieldProposal], CardMultiFieldParseError> {
        let cleaned = Markdown.stripThinking(rawContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = cleaned
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.count >= request.fields.count else {
            return .failure(.malformedJSON(
                "plaintext fallback: \(lines.count) non-empty lines < \(request.fields.count) requested fields"
            ))
        }

        var proposals: [CardFieldProposal] = []
        for (i, field) in request.fields.enumerated() {
            var line = lines[i]
            // Strip a leading `field: ` prefix if the model decided to
            // add one. Match against the rawValue exactly (case-sensitive,
            // followed by optional whitespace and a colon).
            let prefix = "\(field.rawValue):"
            if line.lowercased().hasPrefix(prefix.lowercased()) {
                line = String(line.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let expectedLen = request.expectedLengths[field] ?? 0
            let refusal = CardGenRefusalDetector.detect(
                candidate: line,
                expectedLengthChars: expectedLen
            )
            proposals.append(CardFieldProposal(
                field: field,
                text: line,
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
            // minLength: prose fields keep an 8-char floor so blank /
            // refusal-shaped output gets rejected by the schema, but
            // short Identity facts (wordCount <= 4) drop to 1.
            // §5.4.c live smoke caught the 8-char floor forcing
            // padding — `details_sex` came back as "Female: she/her"
            // (15c) and `nickname` duplicated `name` to fill the
            // bound. The bare values ("Female", "Gem", "22", "Elf")
            // are legitimate single-word answers the schema must
            // accept without coercing the model into adding context.
            let minLen: Int
            if wordCount <= 4 {
                // 2-char floor: bare values like "22" (age), "Elf"
                // (species), "Gem" (nickname) still pass; single-char
                // garbage ("," observed live) gets rejected.
                minLen = 2
            } else {
                minLen = max(8, wordCount / 2)
            }
            // maxLength tightened on §5.4.c smoke: the previous formula
            // (max(minLen + 200, wordCount * 8)) gave wordCount=2 fields
            // a 208-char ceiling, and Qwen3.6 padded short answers
            // ("Elara Vance" repeated 14× separated by \n\n) to fill
            // the bound. Bracket short fields against repetition; keep
            // generous slack for prose.
            let maxLen: Int
            if wordCount <= 4 {
                // Names, single-word identity facts (sex, age, pronouns,
                // species, orientation). 50 chars covers "Vexara, Crimson
                // Matriarch of the Vale" and the model can't pad-by-
                // repetition into anything resembling that.
                maxLen = 50
            } else {
                // Prose / list-shaped fields. wordCount × 10 covers
                // verbose styles; 100-char floor keeps borderline-short
                // fields (depth_prompt at wordCount=15) from clipping.
                maxLen = max(minLen + 100, wordCount * 10)
            }
            var prop: [String: Any] = [
                "type": "string",
                "minLength": minLen,
                "maxLength": maxLen,
            ]
            // Per-field schema overrides for shapes minLength/maxLength
            // alone can't enforce.
            if field == .detailsAge {
                // Age can legitimately be a single character ("8") or a
                // short descriptor ("mid-30s", "ancient", "immortal").
                // Live smoke caught both failure modes — minLength=8
                // forced padding, minLength=2 let "," through. Pattern
                // accepts: bare integer (1+ digits) OR a token starting
                // with a letter then 0-30 chars of letters/digits/space/
                // hyphen/apostrophe.
                prop["minLength"] = 1
                prop["pattern"] = "^([0-9]+|[A-Za-z][A-Za-z0-9 \\-']{0,30})$"
            }
            properties[field.rawValue] = prop
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
