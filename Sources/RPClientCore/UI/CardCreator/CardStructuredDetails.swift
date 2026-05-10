import Foundation

/// Phase 9 §3.9 / §5.3c.2 — RPClient-structured Details + Intimacy data
/// shapes. These ride alongside the spec-standard card fields:
///
///   • Source of truth on disk: `Character.extensions["rpclient/details"]`
///     and `Character.extensions["rpclient/intimacy"]` as JSONValue
///     objects. Round-trip through other v2/v3 readers as opaque blobs.
///   • Mirrored into `Character.description` as fenced text blocks
///     (`[character_details]…[/character_details]` and
///     `[character_intimacy]…[/character_intimacy]`) on save so the
///     prompt builder sees the structured info without engine work.
///   • On load: editor reads from extensions first; if absent, parses
///     the fence out of description.

struct CardDetails: Equatable {
    var sex: String
    var age: String
    var pronouns: String
    var species: String
    var orientation: String
    var appearance: String
    var mood: String

    init(sex: String = "", age: String = "", pronouns: String = "", species: String = "",
         orientation: String = "", appearance: String = "", mood: String = "") {
        self.sex = sex
        self.age = age
        self.pronouns = pronouns
        self.species = species
        self.orientation = orientation
        self.appearance = appearance
        self.mood = mood
    }

    var isEmpty: Bool {
        sex.isEmpty && age.isEmpty && pronouns.isEmpty && species.isEmpty
            && orientation.isEmpty && appearance.isEmpty && mood.isEmpty
    }

    /// Ordered key/value pairs for fence rendering. Order is fixed so
    /// round-tripped descriptions are byte-stable across saves. `sex`
    /// leads — it's the top-of-page chooser and conceptually anchors
    /// the rest. Existing on-disk cards without `sex` round-trip
    /// cleanly because empty values are skipped during fence render.
    var orderedFields: [(String, String)] {
        [("sex", sex), ("age", age), ("pronouns", pronouns), ("species", species),
         ("orientation", orientation), ("appearance", appearance), ("mood", mood)]
    }

    func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        for (k, v) in orderedFields where !v.isEmpty {
            obj[k] = .string(v)
        }
        return .object(obj)
    }

    static func fromJSONValue(_ v: JSONValue) -> CardDetails? {
        guard case .object(let obj) = v else { return nil }
        return CardDetails(
            sex: stringOrEmpty(obj["sex"]),
            age: stringOrEmpty(obj["age"]),
            pronouns: stringOrEmpty(obj["pronouns"]),
            species: stringOrEmpty(obj["species"]),
            orientation: stringOrEmpty(obj["orientation"]),
            appearance: stringOrEmpty(obj["appearance"]),
            mood: stringOrEmpty(obj["mood"])
        )
    }

    static func extractFrom(_ character: Character) -> CardDetails? {
        guard let value = character.extensions?["rpclient/details"] else { return nil }
        return fromJSONValue(value)
    }

    func applyTo(_ character: inout Character) {
        var ext = character.extensions ?? [:]
        if isEmpty {
            ext.removeValue(forKey: "rpclient/details")
        } else {
            ext["rpclient/details"] = toJSONValue()
        }
        character.extensions = ext.isEmpty ? nil : ext
    }
}

struct CardIntimacy: Equatable {
    var build: String
    var anatomy: String
    var markings: String
    var sensitivities: String
    var scent: String
    var turnOns: String
    var kinks: String
    var limits: String

    init(build: String = "", anatomy: String = "", markings: String = "",
         sensitivities: String = "", scent: String = "",
         turnOns: String = "", kinks: String = "", limits: String = "") {
        self.build = build
        self.anatomy = anatomy
        self.markings = markings
        self.sensitivities = sensitivities
        self.scent = scent
        self.turnOns = turnOns
        self.kinks = kinks
        self.limits = limits
    }

    var isEmpty: Bool {
        build.isEmpty && anatomy.isEmpty && markings.isEmpty
            && sensitivities.isEmpty && scent.isEmpty
            && turnOns.isEmpty && kinks.isEmpty && limits.isEmpty
    }

    /// Snake-case keys for the fence (turn_ons not turnOns).
    var orderedFields: [(String, String)] {
        [("build", build), ("anatomy", anatomy), ("markings", markings),
         ("sensitivities", sensitivities), ("scent", scent),
         ("turn_ons", turnOns), ("kinks", kinks), ("limits", limits)]
    }

    func toJSONValue() -> JSONValue {
        var obj: [String: JSONValue] = [:]
        for (k, v) in orderedFields where !v.isEmpty {
            obj[k] = .string(v)
        }
        return .object(obj)
    }

    static func fromJSONValue(_ v: JSONValue) -> CardIntimacy? {
        guard case .object(let obj) = v else { return nil }
        // Migration: pre-split shape carried `body` as a single field
        // covering build / anatomy / markings together. Read it into
        // `anatomy` (the closest match) when `anatomy` itself is absent
        // so legacy on-disk Characters still display their data.
        let anatomyDirect = stringOrEmpty(obj["anatomy"])
        let anatomyFinal = anatomyDirect.isEmpty
            ? stringOrEmpty(obj["body"])
            : anatomyDirect
        return CardIntimacy(
            build: stringOrEmpty(obj["build"]),
            anatomy: anatomyFinal,
            markings: stringOrEmpty(obj["markings"]),
            sensitivities: stringOrEmpty(obj["sensitivities"]),
            scent: stringOrEmpty(obj["scent"]),
            turnOns: stringOrEmpty(obj["turn_ons"]),
            kinks: stringOrEmpty(obj["kinks"]),
            limits: stringOrEmpty(obj["limits"])
        )
    }

    static func extractFrom(_ character: Character) -> CardIntimacy? {
        guard let value = character.extensions?["rpclient/intimacy"] else { return nil }
        return fromJSONValue(value)
    }

    func applyTo(_ character: inout Character) {
        var ext = character.extensions ?? [:]
        if isEmpty {
            ext.removeValue(forKey: "rpclient/intimacy")
        } else {
            ext["rpclient/intimacy"] = toJSONValue()
        }
        character.extensions = ext.isEmpty ? nil : ext
    }
}

private func stringOrEmpty(_ v: JSONValue?) -> String {
    if case .string(let s) = v { return s }
    return ""
}

// MARK: - Fence rendering / parsing

/// Helpers for the `[character_*]…[/character_*]` fenced text blocks
/// that mirror the structured fields into `Character.description`.
enum CardStructuredFence {

    static let detailsTag = "character_details"
    static let intimacyTag = "character_intimacy"

    static func render(_ details: CardDetails) -> String {
        renderFence(tag: detailsTag, fields: details.orderedFields)
    }

    static func render(_ intimacy: CardIntimacy) -> String {
        renderFence(tag: intimacyTag, fields: intimacy.orderedFields)
    }

    static func parseDetails(in text: String) -> CardDetails? {
        guard let dict = parseFence(tag: detailsTag, in: text) else { return nil }
        return CardDetails(
            sex: dict["sex"] ?? "",
            age: dict["age"] ?? "",
            pronouns: dict["pronouns"] ?? "",
            species: dict["species"] ?? "",
            orientation: dict["orientation"] ?? "",
            appearance: dict["appearance"] ?? "",
            mood: dict["mood"] ?? ""
        )
    }

    static func parseIntimacy(in text: String) -> CardIntimacy? {
        guard let dict = parseFence(tag: intimacyTag, in: text) else { return nil }
        // Same legacy-`body` migration as fromJSONValue (§5.3c.2 split):
        // a fence carrying `body: ...` (no `anatomy`) lands in `anatomy`.
        let anatomyFinal = (dict["anatomy"]?.isEmpty == false)
            ? dict["anatomy"] ?? ""
            : dict["body"] ?? ""
        return CardIntimacy(
            build: dict["build"] ?? "",
            anatomy: anatomyFinal,
            markings: dict["markings"] ?? "",
            sensitivities: dict["sensitivities"] ?? "",
            scent: dict["scent"] ?? "",
            turnOns: dict["turn_ons"] ?? "",
            kinks: dict["kinks"] ?? "",
            limits: dict["limits"] ?? ""
        )
    }

    /// Replace existing `[character_*]` fences in `description` with the
    /// freshly-rendered blocks, or prepend if absent. Empty structs cause
    /// the corresponding fence to be removed.
    static func mergeIntoDescription(_ description: String,
                                      details: CardDetails?,
                                      intimacy: CardIntimacy?) -> String {
        // First, strip any existing fences.
        var working = stripFence(tag: detailsTag, in: description)
        working = stripFence(tag: intimacyTag, in: working)
        // Trim leading whitespace/newlines that the strip might leave behind.
        while working.first == "\n" { working = String(working.dropFirst()) }

        // Build the prepend block from non-empty structs.
        var blocks: [String] = []
        if let d = details, !d.isEmpty {
            blocks.append(render(d))
        }
        if let i = intimacy, !i.isEmpty {
            blocks.append(render(i))
        }

        if blocks.isEmpty {
            return working
        }
        let header = blocks.joined(separator: "\n\n")
        if working.isEmpty {
            return header
        }
        return header + "\n\n" + working
    }

    // MARK: - Internals

    private static func renderFence(tag: String, fields: [(String, String)]) -> String {
        let kept = fields.filter { !$0.1.isEmpty }
        guard !kept.isEmpty else { return "" }
        var lines: [String] = ["[\(tag)]"]
        for (key, value) in kept {
            if value.contains("\n") {
                lines.append("\(key):")
                for line in value.split(separator: "\n", omittingEmptySubsequences: false) {
                    lines.append("  \(line)")
                }
            } else {
                lines.append("\(key): \(value)")
            }
        }
        lines.append("[/\(tag)]")
        return lines.joined(separator: "\n")
    }

    private static func parseFence(tag: String, in text: String) -> [String: String]? {
        let openTag = "[\(tag)]"
        let closeTag = "[/\(tag)]"
        guard let openRange = text.range(of: openTag) else { return nil }
        let searchStart = openRange.upperBound
        guard let closeRange = text.range(of: closeTag, range: searchStart..<text.endIndex) else { return nil }
        var content = String(text[openRange.upperBound..<closeRange.lowerBound])
        // Trim leading/trailing newlines that the open/close tags
        // typically sit beside.
        while content.first == "\n" { content = String(content.dropFirst()) }
        while content.last == "\n" { content = String(content.dropLast()) }

        var result: [String: String] = [:]
        var currentKey: String?
        var currentValue: [String] = []

        func commit() {
            guard let k = currentKey else { return }
            let joined = currentValue.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result[k] = joined }
            currentKey = nil
            currentValue = []
        }

        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            // A continuation line is indented with 2+ spaces.
            if line.hasPrefix("  ") {
                if currentKey != nil {
                    currentValue.append(String(line.dropFirst(2)))
                }
                continue
            }
            // Try `key: value` shape.
            if let colonIdx = line.firstIndex(of: ":"),
               let parsedKey = parseKey(line[line.startIndex..<colonIdx]) {
                commit()
                currentKey = parsedKey
                let valuePart = line[line.index(after: colonIdx)...]
                let trimmed = valuePart.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty {
                    currentValue.append(trimmed)
                }
                continue
            }
            // Otherwise — blank or trailing prose; treat as part of current
            // value if we're in one (lets a stray trailing line be captured).
            if currentKey != nil {
                currentValue.append(line)
            }
        }
        commit()
        return result
    }

    private static func parseKey(_ prefix: Substring) -> String? {
        let trimmed = prefix.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // Identifier: lowercase letters, digits, underscores. Snake-case
        // matches the render form; reject anything else so prose lines
        // with stray colons don't get mis-parsed as keys.
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789_")
        let scalars = trimmed.unicodeScalars
        guard scalars.allSatisfy({ allowed.contains($0) }) else { return nil }
        return trimmed
    }

    private static func stripFence(tag: String, in text: String) -> String {
        let openTag = "[\(tag)]"
        let closeTag = "[/\(tag)]"
        guard let openRange = text.range(of: openTag) else { return text }
        let searchStart = openRange.upperBound
        guard let closeRange = text.range(of: closeTag, range: searchStart..<text.endIndex) else { return text }
        // Eat the trailing newline(s) right after the close tag so a
        // re-render doesn't accumulate blank lines in description.
        var endIdx = closeRange.upperBound
        while endIdx < text.endIndex, text[endIdx] == "\n" {
            endIdx = text.index(after: endIdx)
        }
        let before = String(text[..<openRange.lowerBound])
        let after = String(text[endIdx...])
        return before + after
    }
}
