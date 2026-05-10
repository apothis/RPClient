import Foundation

/// Minimal STORE-only ZIP reader (Phase 6 §7.1k1). Just enough to crack
/// open PyTorch `.pt` voice files — these are ZIP archives where every
/// entry is uncompressed (compression method 0). We do not implement
/// DEFLATE because we don't need it for our use case; the reader throws
/// `unsupportedCompression` if asked to read a non-STORE entry.
///
/// CRC-32 is parsed but not validated — Kokoro voices are content-hashed
/// at the SHA-256 level on download, which is a stronger integrity check
/// than per-entry CRC anyway.
public struct MinimalZipReader {
    public enum Error: Swift.Error, Equatable {
        case eocdNotFound
        case unsupportedCompression(method: UInt16, name: String)
        case truncated
        case malformed(String)
    }

    public struct Entry: Equatable {
        public let name: String
        public let lfhOffset: UInt32
        public let compressedSize: UInt32
        public let uncompressedSize: UInt32
        public let method: UInt16
    }

    private let data: Data
    public let entries: [Entry]

    public init(data: Data) throws {
        self.data = data
        let eocd = try Self.findEOCD(in: data)
        let cdEntryCount = Self.readUInt16LE(data, at: eocd + 10)
        let cdSize = Self.readUInt32LE(data, at: eocd + 12)
        let cdOffset = Self.readUInt32LE(data, at: eocd + 16)
        guard Int(cdOffset) + Int(cdSize) <= data.count else {
            throw Error.malformed("central directory exceeds buffer")
        }
        var parsed: [Entry] = []
        var cursor = Int(cdOffset)
        let cdEnd = Int(cdOffset) + Int(cdSize)
        while parsed.count < Int(cdEntryCount), cursor < cdEnd {
            let signature = Self.readUInt32LE(data, at: cursor)
            guard signature == 0x02014b50 else {
                throw Error.malformed("expected CDH signature at \(cursor), got \(String(signature, radix: 16))")
            }
            let method = Self.readUInt16LE(data, at: cursor + 10)
            let compressed = Self.readUInt32LE(data, at: cursor + 20)
            let uncompressed = Self.readUInt32LE(data, at: cursor + 24)
            let nameLen = Int(Self.readUInt16LE(data, at: cursor + 28))
            let extraLen = Int(Self.readUInt16LE(data, at: cursor + 30))
            let commentLen = Int(Self.readUInt16LE(data, at: cursor + 32))
            let lfhOffset = Self.readUInt32LE(data, at: cursor + 42)
            let nameStart = cursor + 46
            let nameEnd = nameStart + nameLen
            guard nameEnd <= data.count else { throw Error.truncated }
            let name = String(decoding: data[nameStart..<nameEnd], as: UTF8.self)
            parsed.append(Entry(
                name: name,
                lfhOffset: lfhOffset,
                compressedSize: compressed,
                uncompressedSize: uncompressed,
                method: method
            ))
            cursor = nameEnd + extraLen + commentLen
        }
        self.entries = parsed
    }

    /// Read the bytes of `entry`. STORE-only — DEFLATE throws.
    public func read(_ entry: Entry) throws -> Data {
        guard entry.method == 0 else {
            throw Error.unsupportedCompression(method: entry.method, name: entry.name)
        }
        let lfhStart = Int(entry.lfhOffset)
        guard lfhStart + 30 <= data.count else { throw Error.truncated }
        let signature = Self.readUInt32LE(data, at: lfhStart)
        guard signature == 0x04034b50 else {
            throw Error.malformed("expected LFH signature at \(lfhStart)")
        }
        let nameLen = Int(Self.readUInt16LE(data, at: lfhStart + 26))
        let extraLen = Int(Self.readUInt16LE(data, at: lfhStart + 28))
        let dataStart = lfhStart + 30 + nameLen + extraLen
        let dataEnd = dataStart + Int(entry.compressedSize)
        guard dataEnd <= data.count else { throw Error.truncated }
        return data.subdata(in: dataStart..<dataEnd)
    }

    /// Convenience: find the entry by exact-match name and read it.
    /// Returns nil when no entry has that name.
    public func read(named name: String) throws -> Data? {
        guard let entry = entries.first(where: { $0.name == name }) else {
            return nil
        }
        return try read(entry)
    }

    // MARK: - Parsing helpers

    /// Locate the End of Central Directory record by scanning backward from
    /// the end of the buffer. The record is at most 65557 bytes from EOF
    /// (22-byte fixed header + up to 65535 bytes of comment).
    private static func findEOCD(in data: Data) throws -> Int {
        let signature: UInt32 = 0x06054b50
        let minStart = max(0, data.count - 65557)
        guard data.count >= 22 else { throw Error.eocdNotFound }
        // Scan backward for the signature, validating that the comment
        // length is consistent with the buffer size.
        var i = data.count - 22
        while i >= minStart {
            if readUInt32LE(data, at: i) == signature {
                let commentLen = Int(readUInt16LE(data, at: i + 20))
                if i + 22 + commentLen == data.count {
                    return i
                }
            }
            i -= 1
        }
        throw Error.eocdNotFound
    }

    private static func readUInt16LE(_ data: Data, at offset: Int) -> UInt16 {
        let b0 = UInt16(data[data.startIndex + offset])
        let b1 = UInt16(data[data.startIndex + offset + 1])
        return b0 | (b1 << 8)
    }

    private static func readUInt32LE(_ data: Data, at offset: Int) -> UInt32 {
        let b0 = UInt32(data[data.startIndex + offset])
        let b1 = UInt32(data[data.startIndex + offset + 1])
        let b2 = UInt32(data[data.startIndex + offset + 2])
        let b3 = UInt32(data[data.startIndex + offset + 3])
        return b0 | (b1 << 8) | (b2 << 16) | (b3 << 24)
    }
}
