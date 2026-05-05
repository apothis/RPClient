import Foundation
@testable import RPClientCore

/// Tests for `MinimalZipReader` — STORE-only ZIP parser used to crack open
/// PyTorch `.pt` voice files (Phase 6 §7.1k1). Pure parser; no network or
/// filesystem deps.
func minimalZipReaderTests() -> TestSuite {
    let s = TestSuite("MinimalZipReader")

    // MARK: - Single-entry round-trip

    s.test("reads a single STORE entry from a hand-built ZIP") {
        let payload = Data("hello world".utf8)
        let zip = ZipBuilder()
            .add(name: "greeting.txt", data: payload)
            .build()
        let reader = try MinimalZipReader(data: zip)
        try expectEqual(reader.entries.count, 1)
        try expectEqual(reader.entries[0].name, "greeting.txt")
        try expectEqual(reader.entries[0].uncompressedSize, UInt32(payload.count))
        let read = try expectNotNil(reader.read(named: "greeting.txt"))
        try expectEqual(read, payload)
    }

    // MARK: - Multiple entries

    s.test("reads multiple STORE entries with correct payloads") {
        let a = Data("alpha".utf8)
        let b = Data(repeating: 0x42, count: 1024)
        let c = Data("\u{01}\u{02}\u{03}".utf8)
        let zip = ZipBuilder()
            .add(name: "a.txt", data: a)
            .add(name: "dir/b.bin", data: b)
            .add(name: "c", data: c)
            .build()
        let reader = try MinimalZipReader(data: zip)
        try expectEqual(reader.entries.count, 3)
        try expectEqual(try expectNotNil(reader.read(named: "a.txt")), a)
        try expectEqual(try expectNotNil(reader.read(named: "dir/b.bin")), b)
        try expectEqual(try expectNotNil(reader.read(named: "c")), c)
    }

    // MARK: - Missing entry

    s.test("read(named:) returns nil for an entry not in the ZIP") {
        let zip = ZipBuilder().add(name: "only.txt", data: Data()).build()
        let reader = try MinimalZipReader(data: zip)
        try expectNil(reader.read(named: "missing.txt"))
    }

    // MARK: - EOCD with trailing comment

    s.test("parses EOCD when a non-empty comment trails it") {
        let zip = ZipBuilder()
            .add(name: "x.txt", data: Data("ok".utf8))
            .build(eocdComment: Data("a trailing comment".utf8))
        let reader = try MinimalZipReader(data: zip)
        try expectEqual(reader.entries.count, 1)
        try expectEqual(try expectNotNil(reader.read(named: "x.txt")), Data("ok".utf8))
    }

    // MARK: - Error cases

    s.test("init throws eocdNotFound on garbage input") {
        let garbage = Data(repeating: 0xAA, count: 256)
        do {
            _ = try MinimalZipReader(data: garbage)
            try expect(false, "expected throw")
        } catch let e as MinimalZipReader.Error {
            switch e {
            case .eocdNotFound: break
            default: try expect(false, "wrong error: \(e)")
            }
        }
    }

    s.test("read throws unsupportedCompression on a DEFLATE entry") {
        // Fake DEFLATE entry: same payload but compression method byte = 8.
        let zip = ZipBuilder()
            .add(name: "compressed.bin", data: Data("payload".utf8), method: 8)
            .build()
        let reader = try MinimalZipReader(data: zip)
        try expectEqual(reader.entries.count, 1)
        do {
            _ = try reader.read(reader.entries[0])
            try expect(false, "expected throw")
        } catch let e as MinimalZipReader.Error {
            switch e {
            case .unsupportedCompression: break
            default: try expect(false, "wrong error: \(e)")
            }
        }
    }

    return s
}

// MARK: - ZipBuilder (test helper)

/// Builds STORE-method ZIP archives byte-by-byte. Limited to what tests
/// need: no compression, no encryption, no Zip64. CRC-32 is set to 0
/// because `MinimalZipReader` ignores it.
fileprivate struct ZipBuilder {
    private struct Entry {
        let name: String
        let data: Data
        let method: UInt16
    }
    private var entries: [Entry] = []

    func add(name: String, data: Data, method: UInt16 = 0) -> ZipBuilder {
        var copy = self
        copy.entries.append(Entry(name: name, data: data, method: method))
        return copy
    }

    func build(eocdComment: Data = Data()) -> Data {
        var buf = Data()
        var lfhOffsets: [UInt32] = []

        // Local file headers + data
        for e in entries {
            lfhOffsets.append(UInt32(buf.count))
            buf.append(uint32: 0x04034b50)        // LFH signature
            buf.append(uint16: 0x0014)            // version needed = 2.0
            buf.append(uint16: 0x0000)            // general purpose flags
            buf.append(uint16: e.method)          // compression method
            buf.append(uint16: 0x0000)            // mod time
            buf.append(uint16: 0x0000)            // mod date
            buf.append(uint32: 0x00000000)        // crc-32 (ignored)
            buf.append(uint32: UInt32(e.data.count))  // compressed size
            buf.append(uint32: UInt32(e.data.count))  // uncompressed size
            let nameBytes = Data(e.name.utf8)
            buf.append(uint16: UInt16(nameBytes.count))
            buf.append(uint16: 0x0000)            // extra length
            buf.append(nameBytes)
            buf.append(e.data)
        }

        // Central directory
        let cdOffset = UInt32(buf.count)
        for (i, e) in entries.enumerated() {
            buf.append(uint32: 0x02014b50)        // CDH signature
            buf.append(uint16: 0x0014)            // version made by
            buf.append(uint16: 0x0014)            // version needed
            buf.append(uint16: 0x0000)            // flags
            buf.append(uint16: e.method)          // method
            buf.append(uint16: 0x0000)            // mod time
            buf.append(uint16: 0x0000)            // mod date
            buf.append(uint32: 0x00000000)        // crc-32
            buf.append(uint32: UInt32(e.data.count))  // compressed size
            buf.append(uint32: UInt32(e.data.count))  // uncompressed size
            let nameBytes = Data(e.name.utf8)
            buf.append(uint16: UInt16(nameBytes.count))
            buf.append(uint16: 0x0000)            // extra length
            buf.append(uint16: 0x0000)            // comment length
            buf.append(uint16: 0x0000)            // disk number
            buf.append(uint16: 0x0000)            // internal attrs
            buf.append(uint32: 0x00000000)        // external attrs
            buf.append(uint32: lfhOffsets[i])     // LFH offset
            buf.append(nameBytes)
        }
        let cdSize = UInt32(buf.count) - cdOffset

        // End of central directory
        buf.append(uint32: 0x06054b50)            // EOCD signature
        buf.append(uint16: 0x0000)                // disk number
        buf.append(uint16: 0x0000)                // disk where CD starts
        buf.append(uint16: UInt16(entries.count)) // CDs on this disk
        buf.append(uint16: UInt16(entries.count)) // total CDs
        buf.append(uint32: cdSize)                // CD size
        buf.append(uint32: cdOffset)              // CD offset
        buf.append(uint16: UInt16(eocdComment.count))
        buf.append(eocdComment)
        return buf
    }
}

fileprivate extension Data {
    mutating func append(uint16 value: UInt16) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
    mutating func append(uint32 value: UInt32) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}
