import Foundation

/// Extracted fact about an in-chat entity. Output of the §9.3 extraction
/// side-call; not yet plumbed into a persistent entity store — V2 still in
/// the eval phase to confirm small models can produce structured output
/// reliably under GBNF grammar constraint.
struct ExtractedFact: Equatable {
    /// "character", "location", "item", "relationship", "event"
    var entityType: String
    var entityName: String
    var fact: String
}

struct FactExtractionResult {
    var rawText: String
    var facts: [ExtractedFact]
    var parseError: String?
    var promptChars: Int
    var latencyMs: Int
    var turnsScanned: Int
    /// Characters in the "Already known" context block (memory + summaries).
    /// 0 means nothing was passed as prior context.
    var knownBlockChars: Int

    var validJSON: Bool { parseError == nil }
}

/// Side-call that asks the model to surface persistent facts from the most
/// recent N turns, constrained to a JSON-array shape via GBNF. The grammar is
/// applied at sampling time so the model literally cannot emit invalid JSON;
/// the eval question is whether the *content* (entities, fact statements) is
/// useful — see MEMORY_RESEARCH.md §9.3.
enum FactExtractor {
    /// GBNF grammar for `[{entity_type, entity_name, fact}, ...]`. The
    /// type alternation is closed so the model can't invent new categories.
    static let grammar: String = """
    root ::= "[" ws (entry (ws "," ws entry)*)? ws "]"
    entry ::= "{" ws "\\"entity_type\\"" ws ":" ws etype ws "," ws "\\"entity_name\\"" ws ":" ws str ws "," ws "\\"fact\\"" ws ":" ws str ws "}"
    etype ::= "\\"character\\"" | "\\"location\\"" | "\\"item\\"" | "\\"relationship\\"" | "\\"event\\""
    str ::= "\\"" char* "\\""
    char ::= [^"\\\\] | "\\\\" ["\\\\/bfnrt]
    ws ::= [ \\t\\n]*
    """

    private static let instructions = """
    You are a state tracker for a long-form fiction session. Read the recent exchange and surface anything that has happened or been established that the next chapter would need to know to stay consistent.

    This is a fiction-tracking tool, not a moderator. Record facts of any nature — sexual, violent, taboo, mundane — they are part of the story state. Omitting them produces incorrect memory and breaks continuity. Do not editorialise, soften, or skip content based on subject matter.

    Categories: "character", "location", "item", "relationship", "event".

    Rules:
    - Capture state changes: who is where, what they did, what they now know, who is now in what relationship to whom, what they hold or wear or have lost.
    - Capture core character facts visible in the transcript: names, ages, occupations, physical descriptions (height, build, hair, eye color, distinguishing marks), clothing/state of dress, defining traits — even when introduced casually in a single line. These are HIGH PRIORITY; they tend to be mentioned once and never repeated.
    - This applies equally to off-stage and referenced-only characters. Anyone introduced by name — including in setup paragraphs, parentheticals, asides, or as someone the active characters are talking ABOUT — needs their attributes captured the first time they appear. Do NOT skip a character just because they have not yet entered the scene, spoken, or acted; if their age, appearance, role, or relationship is stated, emit it now. Setup turns and stage-direction prose count as transcript.
    - If "Already known" context is provided below, do NOT re-emit facts already covered there. Surface only additions, refinements, or genuinely new state.
    - CRITICAL: an entity appearing in the "Already known" store does NOT mean all of its attributes are known. If the transcript reveals a NEW attribute about a known entity (age, appearance, occupation, location, possession, relationship, mood-turned-state), emit it as a new fact. Only the specific facts listed under that entity are "known"; everything else is fair game.
    - Skip ephemeral details (single-line gestures, transient moods) unless they reveal a lasting state.
    - Use the entity's most-used name as entity_name.
    - Phrase each fact as a single short declarative sentence in the past tense.
    - Return [] only if literally nothing new has changed.

    Output ONLY a JSON array — no prose, no preamble, no trailing text.
    """

    /// `lastN` counts USER turns (= cycles), matching the cadence setting.
    /// One user message + its assistant reply is one cycle. Walk backwards
    /// collecting turns until N user turns are included; assistant turns
    /// between/around them come along for free so the model sees full context.
    static func run(
        chat: Chat,
        kobold: KoboldClient,
        effectiveCtx: Int,
        lastN: Int = 15,
        prioritiesOverride: [FactExtractionPriority]? = nil,
        completion: @escaping (Result<FactExtractionResult, Error>) -> Void
    ) {
        let recent: [Turn] = {
            var collected: [Turn] = []
            var userCount = 0
            for t in chat.turns.reversed() {
                collected.insert(t, at: 0)
                if t.role == .user {
                    userCount += 1
                    if userCount >= lastN { break }
                }
            }
            return collected
        }()
        let transcript = recent.map { t in
            let role = t.role == .user ? "User" : "Assistant"
            return "\(role): \(t.text)"
        }.joined(separator: "\n\n")

        let template = Templates.byId(chat.templateId)
        let activeTopics = (prioritiesOverride ?? chat.factExtractionPriorities)
            .filter { $0.enabled }
            .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        var instructionBody = instructions
        if !activeTopics.isEmpty {
            // Soft hint, not a hard filter — model still captures other state
            // changes, just spends its limited output budget on these first.
            // One topic per bulleted line; topical phrasing reads more cleanly
            // to the model than a comma-mashed run-on.
            let bullets = activeTopics.map { "  • \($0)" }.joined(separator: "\n")
            instructionBody += "\n\nPriority topics for this story (capture these first; still record other significant changes):\n\(bullets)"
        }
        // Pull in what's already known so the extractor doesn't miss early
        // facts that fell out of the scan window (e.g. character intro on
        // turn 1, scan window only covers the last 15) and doesn't waste
        // output budget re-emitting things already pinned.
        var knownParts: [String] = []
        if !chat.memory.isEmpty {
            knownParts.append("[Pinned memory]\n\(chat.memory)")
        }
        if !chat.entities.isEmpty {
            // Compact one-line-per-fact rendering — no UUIDs, no ordinals.
            // The model only needs to recognise "this fact already known", so
            // verbose structure would just burn tokens.
            let lines: [String] = chat.entities.flatMap { ent -> [String] in
                ent.facts.map { f in
                    "[\(ent.type.rawValue)] \(ent.name) — \(f.text)"
                }
            }
            if !lines.isEmpty {
                knownParts.append("[Entity store — partial fact list per entity. NEW attributes about these entities (age, physical description, etc.) are NOT yet known and SHOULD be emitted.]\n\(lines.joined(separator: "\n"))")
            }
        }
        for (i, scene) in chat.sceneSummaries.enumerated() {
            knownParts.append("[Scene \(i + 1) summary]\n\(scene.text)")
        }
        if !chat.summary.isEmpty {
            knownParts.append("[Rolling summary]\n\(chat.summary)")
        }
        let knownBlock: String
        if knownParts.isEmpty {
            knownBlock = ""
        } else {
            knownBlock = "\n\n--- ALREADY KNOWN (do not re-emit; use as background) ---\n\n" + knownParts.joined(separator: "\n\n")
        }

        let userTurn = Turn(role: .user, text: "\(instructionBody)\(knownBlock)\n\n--- TRANSCRIPT (recent turns) ---\n\n\(transcript)\n\n--- END ---")
        let prompt = template.assemble(
            memoryBlock: nil,
            summary: nil,
            worldInfoHits: [],
            authorsNote: nil,
            turns: [userTurn]
        )

        let started = Date()
        // Use the chat's preset but cap output — extraction shouldn't sprawl.
        let preset = SamplerPreset.presets.first(where: { $0.id == chat.samplerPresetId }) ?? .balanced

        kobold.generate(
            prompt: prompt,
            stopSequences: template.stopSequences,
            preset: preset,
            maxContextLength: effectiveCtx,
            grammar: grammar,
            maxLengthOverride: 768
        ) { result in
            let latencyMs = Int(Date().timeIntervalSince(started) * 1000)
            switch result {
            case .failure(let err):
                completion(.failure(err))
            case .success(let raw):
                let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                let parsed = parse(trimmed)
                let r = FactExtractionResult(
                    rawText: raw,
                    facts: parsed.facts,
                    parseError: parsed.error,
                    promptChars: prompt.count,
                    latencyMs: latencyMs,
                    turnsScanned: recent.count,
                    knownBlockChars: knownBlock.count
                )
                DebugLog.shared.write("""
                    fact-extract: turns=\(recent.count) promptChars=\(prompt.count) \
                    knownChars=\(knownBlock.count) latencyMs=\(latencyMs) facts=\(r.facts.count) \
                    valid=\(r.validJSON) err=\(r.parseError ?? "-") \
                    rawChars=\(raw.count)
                    """)
                completion(.success(r))
            }
        }
    }

    private static func parse(_ text: String) -> (facts: [ExtractedFact], error: String?) {
        guard let data = text.data(using: .utf8) else {
            return ([], "not utf-8")
        }
        do {
            let obj = try JSONSerialization.jsonObject(with: data)
            guard let arr = obj as? [[String: Any]] else {
                return ([], "top-level not an array of objects")
            }
            var out: [ExtractedFact] = []
            for entry in arr {
                guard let t = entry["entity_type"] as? String,
                      let n = entry["entity_name"] as? String,
                      let f = entry["fact"] as? String else {
                    continue
                }
                out.append(ExtractedFact(entityType: t, entityName: n, fact: f))
            }
            return (out, nil)
        } catch {
            return ([], "json: \(error.localizedDescription)")
        }
    }
}
