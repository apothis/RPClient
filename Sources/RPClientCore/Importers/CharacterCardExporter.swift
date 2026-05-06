import Foundation

/// Exporter for SillyTavern character cards. Inverse of
/// `CharacterCardImporter`. Phase 9 §5.2d.
///
/// Two formats:
///   • `.v2` (`chara_card_v2`) — the dominant ecosystem shape. Drops v3-only
///     fields (nickname, groupOnlyGreetings, source, creatorNotesMultilingual,
///     creationDate, modificationDate, assets) with no warning text on each
///     field — the lossy step is the format choice itself.
///   • `.v3` (`chara_card_v3`) — full fidelity. Pulls
///     `extensions["rpclient/assets_passthrough"]` out into `data.assets[]`
///     and strips the passthrough key (the live array is authoritative).
///     PNG container additionally writes a v2-shaped `chara` chunk
///     alongside `ccv3` so v2-readers can backfill — the v3 spec
///     recommends this for compat.
///
/// Two containers:
///   • `.json` — raw JSON envelope, UTF-8.
///   • `.png(avatar:)` — base64-encodes the JSON and embeds it as a tEXt
///     chunk on the supplied avatar PNG. Avatar bytes must already be a
///     valid PNG (callers route user-supplied images through
///     `Storage.normalizeAvatarData` first); we don't transcode.
enum CharacterCardExporter {

    enum Format {
        case v2
        case v3
    }

    enum Container {
        case json
        case png(avatar: Data)
    }

    enum ExportError: Error, Equatable {
        case notAPNG
        case pngWriteFailed
    }

    static func export(
        _ character: Character,
        as format: Format,
        container: Container
    ) throws -> Data {
        let envelope = makeEnvelope(character, format: format)
        let json = try encodeEnvelope(envelope)
        switch container {
        case .json:
            return json
        case .png(let avatar):
            return try embedInPNG(json: json, format: format, avatar: avatar)
        }
    }

    // MARK: - Envelope assembly

    /// Build the on-wire envelope as a `[String: JSONValue]` dictionary.
    /// Using JSONValue throughout (rather than a Codable struct) so the
    /// `extensions` blob lands verbatim without an extra round-trip.
    private static func makeEnvelope(_ c: Character, format: Format) -> [String: JSONValue] {
        var data: [String: JSONValue] = [:]
        data["name"] = .string(c.name)
        data["description"] = .string(c.description)
        data["personality"] = .string(c.personality)
        data["scenario"] = .string(c.scenario)
        data["first_mes"] = .string(c.firstMessage)
        data["mes_example"] = .string(c.messageExample)
        data["alternate_greetings"] = .array(c.alternateGreetings.map { .string($0) })
        data["tags"] = .array(c.tags.map { .string($0) })
        if let s = c.systemPrompt { data["system_prompt"] = .string(s) }
        if let p = c.postHistoryInstructions { data["post_history_instructions"] = .string(p) }
        if let n = c.creatorNotes { data["creator_notes"] = .string(n) }
        if let cr = c.creator { data["creator"] = .string(cr) }
        if let v = c.characterVersion { data["character_version"] = .string(v) }
        if !c.charBook.isEmpty {
            data["character_book"] = .object([
                "entries": .array(c.charBook.map(encodeBookEntry)),
            ])
        }

        var ext = c.extensions ?? [:]

        if format == .v3 {
            if let nn = c.nickname { data["nickname"] = .string(nn) }
            if !c.groupOnlyGreetings.isEmpty {
                data["group_only_greetings"] = .array(c.groupOnlyGreetings.map { .string($0) })
            }
            if !c.source.isEmpty {
                data["source"] = .array(c.source.map { .string($0) })
            }
            if let ml = c.creatorNotesMultilingual {
                data["creator_notes_multilingual"] = .object(ml.mapValues { .string($0) })
            }
            if let cd = c.creationDate {
                data["creation_date"] = .double(cd.timeIntervalSince1970)
            }
            if let md = c.modificationDate {
                data["modification_date"] = .double(md.timeIntervalSince1970)
            }
            // V3: assets[] live as a top-level data field; pull them out of
            // the passthrough slot and strip that key from extensions to
            // avoid double-writing.
            if let passthrough = ext["rpclient/assets_passthrough"],
               case .array(let arr) = passthrough,
               !arr.isEmpty {
                data["assets"] = .array(arr)
                ext.removeValue(forKey: "rpclient/assets_passthrough")
            }
        }

        if !ext.isEmpty {
            data["extensions"] = .object(ext)
        }

        let specName = (format == .v2) ? "chara_card_v2" : "chara_card_v3"
        let specVersion = (format == .v2) ? "2.0" : "3.0"
        return [
            "spec": .string(specName),
            "spec_version": .string(specVersion),
            "data": .object(data),
        ]
    }

    /// Reverse of importer's `mapCharBook`. Round-trip-stable for the fields
    /// the spec covers; RPClient-internal flags (`tokenCap`, `matchScope`)
    /// are dropped — they have no spec home and would confuse other readers.
    private static func encodeBookEntry(_ e: WorldInfoEntry) -> JSONValue {
        var obj: [String: JSONValue] = [:]
        obj["keys"] = .array(e.keys.map { .string($0) })
        obj["content"] = .string(e.content)
        obj["enabled"] = .bool(e.enabled)
        obj["constant"] = .bool(e.injectionMode == .always)
        if !e.secondaryKeys.isEmpty {
            obj["secondary_keys"] = .array(e.secondaryKeys.map { .string($0) })
            // V2/V3 selective semantics: secondary_keys only fires AND-gate
            // when selective is true. Importer reads them unconditionally;
            // exporter writes selective=true when secondary_keys non-empty
            // so other readers behave the way ours does.
            obj["selective"] = .bool(true)
        }
        // Importer treats insertion_order as the priority source; round-trip
        // back to the same field.
        obj["insertion_order"] = .int(Int64(e.priority))
        if !e.name.isEmpty {
            obj["comment"] = .string(e.name)
        }
        return .object(obj)
    }

    // MARK: - JSON encoding

    private static func encodeEnvelope(_ envelope: [String: JSONValue]) throws -> Data {
        // Compact JSON — the embedded payload should be small. Tests rely
        // on JSONSerialization being able to read this back.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(envelope)
    }

    // MARK: - PNG embedding

    private static func embedInPNG(json: Data, format: Format, avatar: Data) throws -> Data {
        // Validate the avatar is actually a PNG before we go any further.
        // Do this by trying to read its tEXt chunks (which throws on a
        // non-PNG). Empty existing chunks are fine.
        do {
            _ = try PNGTextChunks.readTextChunks(from: avatar)
        } catch PNGTextChunks.ParseError.notAPNG {
            throw ExportError.notAPNG
        }
        let b64 = json.base64EncodedString()

        switch format {
        case .v2:
            guard let out = PNGTextChunks.injectTextChunk(into: avatar, keyword: "chara", text: b64) else {
                throw ExportError.pngWriteFailed
            }
            return out
        case .v3:
            // V3 spec recommendation: write `ccv3` for v3-readers and a
            // backfilled `chara` for v2-readers. Same payload — readers
            // pick the chunk they understand.
            guard let withCcv3 = PNGTextChunks.injectTextChunk(into: avatar, keyword: "ccv3", text: b64) else {
                throw ExportError.pngWriteFailed
            }
            guard let withBoth = PNGTextChunks.injectTextChunk(into: withCcv3, keyword: "chara", text: b64) else {
                throw ExportError.pngWriteFailed
            }
            return withBoth
        }
    }
}
