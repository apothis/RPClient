import Foundation

/// Minimal Codable wrapper for arbitrary JSON used as a passthrough value.
/// Phase 9 §5.2 — character cards (`chara_card_v2`/`v3`) carry an
/// `extensions` blob that editors must preserve verbatim across round-trips,
/// even when keys are unknown to RPClient. Swift's `Codable` can't encode
/// `Any` directly, so this enum stands in.
///
/// Integer-vs-double distinction is preserved on encode (`42` stays `42`,
/// not `42.0`) so an importer that round-trips a card doesn't accidentally
/// rewrite numeric shape. On decode we try `Int64` before `Double` so
/// integer-shaped JSON literals come back as `.int`.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case int(Int64)
    case double(Double)
    case string(String)
    indirect case array([JSONValue])
    indirect case object([String: JSONValue])
}

extension JSONValue: Codable {
    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() {
            self = .null
            return
        }
        if let b = try? c.decode(Bool.self) {
            self = .bool(b)
            return
        }
        if let n = try? c.decode(Int64.self) {
            self = .int(n)
            return
        }
        if let n = try? c.decode(Double.self) {
            self = .double(n)
            return
        }
        if let s = try? c.decode(String.self) {
            self = .string(s)
            return
        }
        if let arr = try? c.decode([JSONValue].self) {
            self = .array(arr)
            return
        }
        if let obj = try? c.decode([String: JSONValue].self) {
            self = .object(obj)
            return
        }
        throw DecodingError.dataCorruptedError(
            in: c,
            debugDescription: "Value is not valid JSON"
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .null: try c.encodeNil()
        case .bool(let b): try c.encode(b)
        case .int(let n): try c.encode(n)
        case .double(let n): try c.encode(n)
        case .string(let s): try c.encode(s)
        case .array(let arr): try c.encode(arr)
        case .object(let obj): try c.encode(obj)
        }
    }
}
