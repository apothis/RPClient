import Foundation
@testable import RPClientCore

/// Tests for the pure download types + SHA-256 file hasher used by the
/// Kokoro download manager (Phase 6 §7.1j1). The manager itself lives in
/// `RPClientVoice` and is smoke-tested; this layer is unit-testable.
func kokoroDownloadTypesTests() -> TestSuite {
    let s = TestSuite("KokoroDownloadTypes")

    // MARK: - Task identity

    s.test("baseModel task uses 'model' as its id") {
        let modelURL = KokoroVoiceCatalogue.modelDownloadURL
        let dest = URL(fileURLWithPath: "/tmp/kokoro/model.onnx")
        let task = KokoroDownloadTask(
            asset: .baseModel,
            sourceURL: modelURL,
            destinationURL: dest,
            expectedBytes: Int64(KokoroVoiceCatalogue.modelByteSize)
        )
        try expectEqual(task.id, "model")
    }

    s.test("voice task uses the voice id as its id") {
        let bella = KokoroVoiceCatalogue.voice(id: "af_bella")!
        let dest = URL(fileURLWithPath: "/tmp/kokoro/voices/af_bella.pt")
        let task = KokoroDownloadTask(
            asset: .voice(id: "af_bella"),
            sourceURL: bella.downloadURL,
            destinationURL: dest,
            expectedBytes: Int64(KokoroVoiceCatalogue.voiceByteSizeApprox)
        )
        try expectEqual(task.id, "af_bella")
    }

    // MARK: - State equality

    s.test("queued and queued are equal") {
        try expectEqual(KokoroDownloadState.queued, .queued)
    }

    s.test("running with same bytes is equal") {
        try expectEqual(
            KokoroDownloadState.running(bytesDownloaded: 1024, totalBytes: 4096),
            .running(bytesDownloaded: 1024, totalBytes: 4096)
        )
    }

    s.test("completed states with different sha are not equal") {
        let a = KokoroDownloadState.completed(sha256: "aaa", bytes: 100)
        let b = KokoroDownloadState.completed(sha256: "bbb", bytes: 100)
        try expect(a != b)
    }

    // MARK: - SHA-256 known vectors

    s.test("sha256 of empty data matches the canonical value") {
        let hex = Sha256.hex(of: Data())
        try expectEqual(
            hex,
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
        )
    }

    s.test("sha256 of 'abc' matches the canonical value") {
        let hex = Sha256.hex(of: Data("abc".utf8))
        try expectEqual(
            hex,
            "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"
        )
    }

    s.test("sha256 of file streams matches Data version") {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpclient-sha256-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let payload = Data("the quick brown fox jumps over the lazy dog\n".utf8)
        try payload.write(to: tmp)
        let fileHex = try Sha256.hex(ofFileAt: tmp)
        let dataHex = Sha256.hex(of: payload)
        try expectEqual(fileHex, dataHex)
    }

    s.test("sha256 of large file streams correctly (multi-chunk)") {
        // Build a 5 MB file from a known repeating pattern so we exercise
        // the streaming path past a single read buffer.
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("rpclient-sha256-large-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let chunk = Data(repeating: 0x41, count: 64 * 1024)  // 64 KB of 'A'
        FileManager.default.createFile(atPath: tmp.path, contents: nil)
        let handle = try FileHandle(forWritingTo: tmp)
        for _ in 0..<80 { try handle.write(contentsOf: chunk) }  // 5 MB
        try handle.close()

        let fileHex = try Sha256.hex(ofFileAt: tmp)
        var fullData = Data()
        for _ in 0..<80 { fullData.append(chunk) }
        let dataHex = Sha256.hex(of: fullData)
        try expectEqual(fileHex, dataHex)
    }

    return s
}
