import Foundation

/// Minimal PNG chunk walker used by the character-card importer. The whole
/// reason this file exists is the SillyTavern v2 spec, which stashes a
/// base64-encoded JSON blob under a `tEXt` chunk keyed `chara`. We only need
/// to read those chunks (and produce them in tests) — full PNG decoding is
/// AppKit's job.
///
/// References: PNG Spec §11.2 (chunk layout), §11.3.4.3 (`tEXt` format),
/// SillyTavern card v2 spec.
enum PNGTextChunks {

    /// Eight-byte PNG file signature. Anything that doesn't open with this
    /// isn't a PNG and we don't even try to parse it.
    static let signature: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]

    struct TextChunk: Equatable {
        let keyword: String
        let text: String
    }

    enum ParseError: Error, Equatable {
        case notAPNG
        case truncated
        case oversizedChunk
    }

    /// Walk the PNG chunk list and return every `tEXt` chunk found, in file
    /// order. Stops cleanly at `IEND`. Does *not* validate per-chunk CRCs —
    /// AppKit will reject the image elsewhere if it's actually corrupt, and
    /// some real-world card PNGs ship with off-by-one CRCs that ST tolerates.
    static func readTextChunks(from data: Data) throws -> [TextChunk] {
        guard data.count >= signature.count else { throw ParseError.notAPNG }
        for i in 0..<signature.count where data[i] != signature[i] {
            throw ParseError.notAPNG
        }
        var cursor = signature.count
        var out: [TextChunk] = []
        while cursor + 8 <= data.count {
            let length = Int(readUInt32BE(data, at: cursor))
            cursor += 4
            // Cap the per-chunk size at the remaining file length — real
            // tEXt chunks are kilobytes, but a malformed length field could
            // claim gigabytes and ask us to read off the end.
            guard length >= 0, cursor + 4 + length + 4 <= data.count else {
                throw ParseError.truncated
            }
            let typeBytes = data[cursor..<(cursor + 4)]
            cursor += 4
            let type = String(decoding: typeBytes, as: UTF8.self)
            let payload = data[cursor..<(cursor + length)]
            cursor += length
            // Skip the CRC. We don't validate it (see comment above).
            cursor += 4

            switch type {
            case "tEXt":
                if let chunk = decodeTEXt(payload) {
                    out.append(chunk)
                }
            case "IEND":
                return out
            default:
                continue
            }
        }
        // Reached EOF without an IEND — return what we have rather than
        // hard-erroring. The chara chunk usually appears before IDAT/IEND.
        return out
    }

    /// Build a new PNG by injecting a `tEXt` chunk just before the trailing
    /// `IEND` chunk of `pngData`. Used by the test fixtures (and, eventually,
    /// by an export path) to round-trip cards. Returns nil if the input
    /// doesn't look like a PNG with a terminating IEND.
    static func injectTextChunk(into pngData: Data, keyword: String, text: String) -> Data? {
        guard pngData.count >= signature.count else { return nil }
        for i in 0..<signature.count where pngData[i] != signature[i] {
            return nil
        }
        // Find IEND. It's always the last 12 bytes of a well-formed PNG
        // (length=0, type=IEND, CRC), but rather than hardcoding the offset
        // we walk to be defensive.
        var cursor = signature.count
        var iendStart: Int?
        while cursor + 8 <= pngData.count {
            let length = Int(readUInt32BE(pngData, at: cursor))
            let typeStart = cursor + 4
            let typeBytes = pngData[typeStart..<(typeStart + 4)]
            let type = String(decoding: typeBytes, as: UTF8.self)
            let chunkEnd = cursor + 4 + 4 + length + 4
            if type == "IEND" {
                iendStart = cursor
                break
            }
            cursor = chunkEnd
        }
        guard let iend = iendStart else { return nil }

        let chunk = encodeTEXt(keyword: keyword, text: text)
        var out = Data()
        out.append(pngData[..<iend])
        out.append(chunk)
        out.append(pngData[iend...])
        return out
    }

    // MARK: - Encoding helpers (test + future export use)

    /// Build a single `tEXt` chunk: 4-byte length, "tEXt" type, keyword + 0x00
    /// + text payload, 4-byte CRC32 over (type + payload). Keyword is the
    /// only field with a length restriction in the spec (1-79 bytes); we
    /// trust the caller.
    static func encodeTEXt(keyword: String, text: String) -> Data {
        var payload = Data()
        payload.append(Data(keyword.utf8))
        payload.append(0x00)
        payload.append(Data(text.utf8))
        var chunk = Data()
        chunk.append(uint32BE(UInt32(payload.count)))
        let typeBytes = Data("tEXt".utf8)
        chunk.append(typeBytes)
        chunk.append(payload)
        var crcInput = Data()
        crcInput.append(typeBytes)
        crcInput.append(payload)
        chunk.append(uint32BE(crc32(crcInput)))
        return chunk
    }

    // MARK: - Internals

    private static func decodeTEXt(_ payload: Data) -> TextChunk? {
        guard let nullIdx = payload.firstIndex(of: 0x00) else { return nil }
        let keywordBytes = payload[payload.startIndex..<nullIdx]
        let textBytes = payload[(nullIdx + 1)...]
        // PNG tEXt is Latin-1, but card text is base64 (ASCII) so UTF-8
        // decoding is lossless in the cases we care about.
        let keyword = String(decoding: keywordBytes, as: UTF8.self)
        let text = String(decoding: textBytes, as: UTF8.self)
        return TextChunk(keyword: keyword, text: text)
    }

    private static func readUInt32BE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[offset])
        let b1 = UInt32(data[offset + 1])
        let b2 = UInt32(data[offset + 2])
        let b3 = UInt32(data[offset + 3])
        return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3
    }

    private static func uint32BE(_ v: UInt32) -> Data {
        var out = Data(count: 4)
        out[0] = UInt8((v >> 24) & 0xFF)
        out[1] = UInt8((v >> 16) & 0xFF)
        out[2] = UInt8((v >> 8) & 0xFF)
        out[3] = UInt8(v & 0xFF)
        return out
    }

    /// Standard PNG CRC32 (polynomial 0xEDB88320, init 0xFFFFFFFF, final
    /// XOR 0xFFFFFFFF). Built lazily on first use; the table is static so
    /// repeated calls share work.
    static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for byte in data {
            let idx = Int((c ^ UInt32(byte)) & 0xFF)
            c = crcTable[idx] ^ (c >> 8)
        }
        return c ^ 0xFFFFFFFF
    }

    private static let crcTable: [UInt32] = {
        var table = [UInt32](repeating: 0, count: 256)
        for i in 0..<256 {
            var c = UInt32(i)
            for _ in 0..<8 {
                if (c & 1) != 0 {
                    c = 0xEDB88320 ^ (c >> 1)
                } else {
                    c >>= 1
                }
            }
            table[i] = c
        }
        return table
    }()
}
