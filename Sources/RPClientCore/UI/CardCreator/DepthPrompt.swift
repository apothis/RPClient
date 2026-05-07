import Foundation

/// Phase 9 §3.4 / §5.3b — first-class data shape for the community
/// `extensions["depth_prompt"]` convention. Not in either the v2 or v3
/// formal spec text, but widespread on chub.ai-shape NSFW cards. Standards-
/// track equivalent is the v3 lorebook `@@depth N` decorator; the inline
/// extension is what's actually deployed in the wild.
///
/// On-disk shape (community convention):
/// ```
/// "extensions": {
///   "depth_prompt": {
///     "prompt": "[OOC: explicit content allowed]",
///     "depth": 4,
///     "role": "system"
///   }
/// }
/// ```
///
/// RPClient round-trips this through `Character.extensions`, exposes it
/// as a first-class control in the creator's System tab, and (eventually
/// — engine integration is out of §5.2 scope) injects it during prompt
/// assembly.
struct DepthPrompt: Equatable {

    enum Role: String, Equatable {
        case system
        case user
    }

    var prompt: String
    var depth: Int
    var role: Role

    init(prompt: String, depth: Int, role: Role) {
        self.prompt = prompt
        self.depth = depth
        self.role = role
    }

    // MARK: - JSONValue conversion

    func toJSONValue() -> JSONValue {
        .object([
            "prompt": .string(prompt),
            "depth": .int(Int64(depth)),
            "role": .string(role.rawValue),
        ])
    }

    /// Decode a `DepthPrompt` from the JSONValue stored under
    /// `extensions["depth_prompt"]`. Tolerant — depth-as-double is
    /// accepted (some clients write 4.0); missing role defaults to
    /// `.system` (the convention default). Returns nil for unrecognized
    /// shapes (non-object, missing prompt) so the caller can decide
    /// whether to surface an error or silently skip.
    static func fromJSONValue(_ v: JSONValue) -> DepthPrompt? {
        guard case .object(let obj) = v else { return nil }

        // prompt is required.
        guard case .string(let prompt) = obj["prompt"] ?? .null else {
            return nil
        }

        // depth defaults to 4 (community default) if absent or unparseable.
        let depth: Int = {
            switch obj["depth"] {
            case .int(let n): return Int(n)
            case .double(let d): return Int(d)
            default: return 4
            }
        }()

        // role defaults to .system.
        let role: Role = {
            if case .string(let s) = obj["role"] ?? .null {
                return Role(rawValue: s) ?? .system
            }
            return .system
        }()

        return DepthPrompt(prompt: prompt, depth: depth, role: role)
    }

    // MARK: - Character integration

    /// Pull the depth_prompt out of `character.extensions` if present.
    static func extractFrom(_ character: Character) -> DepthPrompt? {
        guard let value = character.extensions?["depth_prompt"] else { return nil }
        return fromJSONValue(value)
    }

    /// Write this depth_prompt into `character.extensions["depth_prompt"]`,
    /// creating the extensions dict if needed. Other extension keys are
    /// preserved verbatim.
    func applyTo(_ character: inout Character) {
        var ext = character.extensions ?? [:]
        ext["depth_prompt"] = toJSONValue()
        character.extensions = ext
    }

    /// Remove the depth_prompt from `character.extensions`, preserving any
    /// other extension keys. If the resulting dict is empty, the
    /// extensions blob is set to nil so the on-disk representation matches
    /// the importer/exporter `encodeIfPresent` contract (no empty dicts on
    /// disk).
    static func removeFrom(_ character: inout Character) {
        guard var ext = character.extensions else { return }
        ext.removeValue(forKey: "depth_prompt")
        character.extensions = ext.isEmpty ? nil : ext
    }
}
