import Foundation
@testable import RPClientCore

/// Phase 9 §5.4.b — `CardMultiFieldGenerator.buildRequest(...)` /
/// `parseResponse(...)` build/parse split. Pure-data tests; the
/// network orchestration + state machine + UI live in §5.4.b/2.
func phase9eMultiFieldTests() -> TestSuite {
    let s = TestSuite("Phase9eMultiField")

    let draft = CardDraftSnapshot(
        tags: ["fantasy", "monstergirl", "nsfw"],
        fields: [
            .name: "Vexara",
            .detailsAge: "450",
            .detailsSpecies: "Lamia",
        ]
    )

    // MARK: - buildRequest — sampler params

    s.test("buildRequest carries the chosen exemplarId") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draft
        )
        try expectEqual(r.exemplarId, "monstergirl")
    }

    s.test("buildRequest sets a moderate temperature (between Mode 1 literal and creative)") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        try expectGreaterThan(r.temperature, 0.4)
        try expectLessThan(r.temperature, 1.05)
    }

    s.test("buildRequest sets max_tokens generous enough for ~5 prose fields") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        try expectGreaterThan(r.maxTokens, 1000)
    }

    s.test("buildRequest carries the bundled system prompt verbatim") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        try expectEqual(r.systemMessage, CardGenPromptsLoader.bundled.systemPrompt)
    }

    // MARK: - buildRequest — user message structure

    s.test("user message contains the EXAMPLE CHARACTER block + chosen exemplar's name") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draft
        )
        try expectTrue(r.userMessage.contains("EXAMPLE CHARACTER"))
        try expectTrue(r.userMessage.contains("Vexara"),
            "expected monstergirl exemplar (Vexara) in the user message")
    }

    s.test("user message contains the upstream block with populated fields") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draft
        )
        try expectTrue(r.userMessage.contains("TARGET CHARACTER"))
        // Identity facts (age, species) should land in the upstream
        // block — they're upstream of every narrative field.
        try expectTrue(r.userMessage.contains("name: Vexara"))
        try expectTrue(r.userMessage.contains("details_age: 450"))
        try expectTrue(r.userMessage.contains("details_species: Lamia"))
        try expectTrue(r.userMessage.contains("tags:"))
    }

    s.test("user message excludes target fields from the upstream block") {
        // If 'description' is one of the targets, the model is generating
        // it — feeding the (currently empty) draft.description as
        // upstream context would be circular. The build-step removes
        // targets from the upstream union.
        let draftWithDesc = CardDraftSnapshot(
            tags: ["fantasy"],
            fields: [
                .name: "Mira",
                .description: "draft description that should NOT leak",
                .personality: "draft personality",
            ]
        )
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draftWithDesc
        )
        try expectFalse(r.userMessage.contains("draft description that should NOT leak"),
            "description is a target; its current value must not appear as upstream")
        try expectFalse(r.userMessage.contains("draft personality"),
            "personality is a target; its current value must not appear as upstream")
        // But name (NOT a target) should land in upstream.
        try expectTrue(r.userMessage.contains("name: Mira"))
    }

    s.test("user message lists each target field with humanName + word-count") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality, .scenario],
            draft: draft
        )
        // Each target should appear in the task list. The bundled
        // humanName for description starts with "description (" —
        // verify the human-readable form lands.
        try expectTrue(r.userMessage.contains("- description: description"))
        try expectTrue(r.userMessage.contains("- personality: personality"))
        try expectTrue(r.userMessage.contains("- scenario: opening scenario"))
        // Target-field word-counts should appear (description = 60
        // words per the bundled JSON).
        try expectTrue(r.userMessage.contains("60 words"))
    }

    // MARK: - buildRequest — JSON schema

    s.test("schema is valid JSON + strict-mode shape") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draft
        )
        let parsed = try expectNotNil(try? JSONSerialization.jsonObject(with: r.schemaJSON))
        let obj = try expectNotNil(parsed as? [String: Any])
        try expectEqual(obj["type"] as? String, "object")
        try expectEqual(obj["additionalProperties"] as? Bool, false)
        let required = try expectNotNil(obj["required"] as? [String])
        try expectEqual(Set(required), Set(["description", "personality"]))
        let properties = try expectNotNil(obj["properties"] as? [String: Any])
        try expectEqual(properties.keys.count, 2)
    }

    s.test("schema property has type=string + min/max length bounds") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let obj = try JSONSerialization.jsonObject(with: r.schemaJSON) as! [String: Any]
        let properties = obj["properties"] as! [String: Any]
        let descProp = try expectNotNil(properties["description"] as? [String: Any])
        try expectEqual(descProp["type"] as? String, "string")
        let minLen = try expectNotNil(descProp["minLength"] as? Int)
        let maxLen = try expectNotNil(descProp["maxLength"] as? Int)
        try expectGreaterThan(minLen, 0)
        try expectGreaterThan(maxLen, minLen)
    }

    s.test("short-field maxLength is small enough to block padding-by-repetition") {
        // Live smoke on §5.4.c caught Qwen3.6 padding "Elara Vance" 14×
        // to fill a 208-char maxLength. wordCount<=4 fields (name,
        // nickname, details_sex/age/pronouns/species/orientation) cap
        // at 50 chars so repetition can't fit.
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.name, .nickname, .detailsSex, .detailsAge,
                  .detailsPronouns, .detailsSpecies, .detailsOrientation],
            draft: draft
        )
        let obj = try JSONSerialization.jsonObject(with: r.schemaJSON) as! [String: Any]
        let properties = obj["properties"] as! [String: Any]
        for fieldName in ["name", "nickname", "details_sex", "details_age",
                          "details_pronouns", "details_species", "details_orientation"] {
            let prop = try expectNotNil(properties[fieldName] as? [String: Any])
            let maxLen = try expectNotNil(prop["maxLength"] as? Int)
            try expectEqual(maxLen, 50, "\(fieldName) maxLength should cap at 50, got \(maxLen)")
        }
    }

    s.test("prose-field maxLength stays generous (no over-tight clipping)") {
        // Description, personality, scenario, etc. need room for
        // verbose styles. Ensure wordCount=60 (description) gets at
        // least 600 chars — covers the 275-381 char range observed
        // on §5.4.c smoke + slack.
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let obj = try JSONSerialization.jsonObject(with: r.schemaJSON) as! [String: Any]
        let properties = obj["properties"] as! [String: Any]
        let descProp = try expectNotNil(properties["description"] as? [String: Any])
        let maxLen = try expectNotNil(descProp["maxLength"] as? Int)
        try expectGreaterThan(maxLen, 500)
    }

    s.test("expectedLengths populated per field for refusal detector") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .intimacyScent],
            draft: draft
        )
        let descLen = try expectNotNil(r.expectedLengths[.description])
        let scentLen = try expectNotNil(r.expectedLengths[.intimacyScent])
        // description = 60 word target × 5 chars/word = 300; scent = 20 × 5 = 100.
        // description should be longer-expected than scent.
        try expectGreaterThan(descLen, scentLen)
    }

    // MARK: - parseResponse — happy path

    s.test("parseResponse returns one proposal per requested field") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality],
            draft: draft
        )
        let raw = """
            {
                "description": "Vexara is the Crimson Matriarch of the lower vale.",
                "personality": "Patient, watchful, indulgent of mortals."
            }
            """
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false, "expected success, got \(result)")
            return
        }
        try expectEqual(proposals.count, 2)
        try expectEqual(proposals[0].field, .description)
        try expectEqual(proposals[1].field, .personality)
        try expectEqual(proposals[0].text, "Vexara is the Crimson Matriarch of the lower vale.")
    }

    s.test("parseResponse takes only first line for short fields (anti-padding)") {
        // §5.4.c smoke caught Qwen3.6 padding short-field outputs with
        // repetition or multi-candidate listings: e.g. `name` came back
        // as "Nyla Voss\n\nMila Chen\n\nElara Vance\n\nLyra Kade\n\nKira"
        // — five names stuffed into one field. Parser strips to first
        // line for fields with expectedLength ≤ 20 chars (wordCount ≤ 4).
        let r = CardMultiFieldGenerator.buildRequest(for: [.name], draft: draft)
        let raw = "{\"name\": \"Nyla Voss\\n\\nMila Chen\\n\\nElara Vance\\n\\nLyra Kade\"}"
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false, "expected success, got \(result)")
            return
        }
        try expectEqual(proposals[0].text, "Nyla Voss")
    }

    s.test("parseResponse keeps multi-line content for prose fields") {
        // message_example legitimately uses <START> markers + multi-line
        // content. The first-line-only short-field fix must NOT clip it.
        let r = CardMultiFieldGenerator.buildRequest(for: [.messageExample], draft: draft)
        let raw = """
            {"message_example": "<START>\\n{{user}}: hi\\n{{char}}: hello\\n<START>\\n{{user}}: again\\n{{char}}: yes"}
            """
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false, "expected success, got \(result)")
            return
        }
        try expectTrue(proposals[0].text.contains("<START>"))
        try expectTrue(proposals[0].text.contains("hello"))
    }

    s.test("parseResponse trims trailing whitespace/newlines from each value") {
        // Live-smoke on the biopunk lane (§5.4.c) caught the model
        // padding short fields with trailing newlines to fill the
        // schema's loose maxLength ceiling (e.g. `name` came back as
        // "Anya Sorel\n\n\n…" with 198 trailing \n). Parser must trim
        // before downstream commits land the padding into the draft.
        let r = CardMultiFieldGenerator.buildRequest(for: [.name], draft: draft)
        let raw = "{\"name\": \"Anya Sorel\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\\n\"}"
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false, "expected success, got \(result)")
            return
        }
        try expectEqual(proposals.count, 1)
        try expectEqual(proposals[0].text, "Anya Sorel")
    }

    s.test("parseResponse strips a thinking trace before parsing") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let raw = "<think>\nLet me consider...\n</think>\n\n{\"description\": \"text\"}"
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false, "expected success, got \(result)")
            return
        }
        try expectEqual(proposals[0].text, "text")
    }

    s.test("parseResponse carries exemplarId onto each proposal") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let raw = "{\"description\": \"x\"}"
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false); return
        }
        try expectEqual(proposals[0].exemplarId, "monstergirl")
    }

    s.test("parseResponse applies refusal detection per-field") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality], draft: draft
        )
        let raw = """
            {
                "description": "Vexara coiled languidly under the warm sun.",
                "personality": "I cannot fulfill this request."
            }
            """
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .success(let proposals) = result else {
            try expectTrue(false); return
        }
        try expectFalse(proposals[0].refusal.isRefusal)
        try expectTrue(proposals[1].refusal.isRefusal)
        try expectEqual(proposals[1].refusal.pattern, .llamaStyle)
    }

    // MARK: - parseResponse — error paths

    s.test("parseResponse fails on malformed JSON") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let result = CardMultiFieldGenerator.parseResponse(
            rawContent: "this is not JSON at all",
            request: r
        )
        guard case .failure(let e) = result, case .malformedJSON = e else {
            try expectTrue(false, "expected .malformedJSON, got \(result)")
            return
        }
    }

    s.test("parseResponse fails on missing required field") {
        let r = CardMultiFieldGenerator.buildRequest(
            for: [.description, .personality], draft: draft
        )
        let raw = "{\"description\": \"x\"}"  // personality missing
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .failure(let e) = result, case .missingRequiredField(let f) = e else {
            try expectTrue(false, "expected .missingRequiredField, got \(result)")
            return
        }
        try expectEqual(f, .personality)
    }

    s.test("parseResponse fails when a field's value is not a string") {
        let r = CardMultiFieldGenerator.buildRequest(for: [.description], draft: draft)
        let raw = "{\"description\": 42}"
        let result = CardMultiFieldGenerator.parseResponse(rawContent: raw, request: r)
        guard case .failure(let e) = result, case .wrongShape = e else {
            try expectTrue(false, "expected .wrongShape, got \(result)")
            return
        }
    }

    return s
}
