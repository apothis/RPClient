import Foundation
import OnnxRuntimeBindings

/// Errors thrown by `KokoroEngine`.
public enum KokoroEngineError: Error {
    case sessionOpenFailed(String)
    case unexpectedInputNames([String])
    case unexpectedOutputNames([String])
    case styleBufferWrongLength(expected: Int, got: Int)
    case tokensTooShort(Int)
    case styleSliceOutOfRange(unpaddedCount: Int)
    case inferenceFailed(String)
    case audioOutputMissing
    case audioOutputWrongElementType(Int32)
}

/// Kokoro TTS inference, wrapping a single ONNX Runtime session against the
/// legacy `tokens / style / speed → audio` export. Phase 6 §7.1k3.
///
/// Schema (verified by `KokoroProbe` + matched against
/// [kokoro-onnx Python](https://github.com/thewh1teagle/kokoro-onnx/blob/main/src/kokoro_onnx/__init__.py)):
/// - `tokens: int64[1, N]` — pad-wrapped token ids from `KokoroTokenizer`.
/// - `style: float32[1, 256]` — one slice of the per-voice style file,
///   indexed by `paddedTokens.count - 2` (i.e. the unpadded length).
/// - `speed: float32[1]` — playback rate, 1.0 = default.
/// - Output `audio: float32[N_samples]` at 24 kHz mono.
public final class KokoroEngine {
    public static let sampleRate: Int = 24_000
    public static let styleSlots: Int = 510
    public static let styleEmbedDim: Int = 256
    public static let styleBufferLength: Int = styleSlots * styleEmbedDim   // 130560

    private static let expectedInputs: Set<String> = ["tokens", "style", "speed"]
    private static let expectedOutputs: Set<String> = ["audio"]

    private let env: ORTEnv
    private let session: ORTSession

    public init(modelURL: URL) throws {
        do {
            self.env = try ORTEnv(loggingLevel: .warning)
            let options = try ORTSessionOptions()
            self.session = try ORTSession(
                env: self.env,
                modelPath: modelURL.path,
                sessionOptions: options
            )
        } catch let error as KokoroEngineError {
            throw error
        } catch {
            throw KokoroEngineError.sessionOpenFailed(String(describing: error))
        }

        let inputNames = Set(try session.inputNames())
        guard inputNames == Self.expectedInputs else {
            throw KokoroEngineError.unexpectedInputNames(Array(inputNames).sorted())
        }
        let outputNames = Set(try session.outputNames())
        guard outputNames == Self.expectedOutputs else {
            throw KokoroEngineError.unexpectedOutputNames(Array(outputNames).sorted())
        }
    }

    /// Synthesizes audio from a pad-wrapped token sequence and a full
    /// `[510, 1, 256]` voice style buffer. Returns raw float32 PCM at 24 kHz.
    public func synthesize(tokens: [Int64], style: [Float], speed: Float) throws -> [Float] {
        guard style.count == Self.styleBufferLength else {
            throw KokoroEngineError.styleBufferWrongLength(
                expected: Self.styleBufferLength,
                got: style.count
            )
        }
        guard tokens.count >= 2 else {
            throw KokoroEngineError.tokensTooShort(tokens.count)
        }
        let unpaddedCount = tokens.count - 2
        guard unpaddedCount < Self.styleSlots else {
            throw KokoroEngineError.styleSliceOutOfRange(unpaddedCount: unpaddedCount)
        }

        let sliceStart = unpaddedCount * Self.styleEmbedDim
        let styleSlice = Array(style[sliceStart..<(sliceStart + Self.styleEmbedDim)])

        let tokensValue = try Self.makeTensor(
            int64: tokens,
            shape: [NSNumber(value: 1), NSNumber(value: tokens.count)]
        )
        let styleValue = try Self.makeTensor(
            float32: styleSlice,
            shape: [NSNumber(value: 1), NSNumber(value: Self.styleEmbedDim)]
        )
        let speedValue = try Self.makeTensor(
            float32: [speed],
            shape: [NSNumber(value: 1)]
        )

        let outputs: [String: ORTValue]
        do {
            outputs = try session.run(
                withInputs: [
                    "tokens": tokensValue,
                    "style": styleValue,
                    "speed": speedValue,
                ],
                outputNames: Self.expectedOutputs,
                runOptions: nil
            )
        } catch {
            throw KokoroEngineError.inferenceFailed(String(describing: error))
        }

        guard let audio = outputs["audio"] else {
            throw KokoroEngineError.audioOutputMissing
        }
        let info = try audio.tensorTypeAndShapeInfo()
        guard info.elementType == .float else {
            throw KokoroEngineError.audioOutputWrongElementType(info.elementType.rawValue)
        }
        let data = try audio.tensorData() as Data
        return data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(buf)
        }
    }

    private static func makeTensor(int64 values: [Int64], shape: [NSNumber]) throws -> ORTValue {
        let byteCount = values.count * MemoryLayout<Int64>.size
        let data = NSMutableData(length: byteCount)!
        _ = values.withUnsafeBufferPointer { src in
            memcpy(data.mutableBytes, src.baseAddress, byteCount)
        }
        return try ORTValue(tensorData: data, elementType: .int64, shape: shape)
    }

    private static func makeTensor(float32 values: [Float], shape: [NSNumber]) throws -> ORTValue {
        let byteCount = values.count * MemoryLayout<Float>.size
        let data = NSMutableData(length: byteCount)!
        _ = values.withUnsafeBufferPointer { src in
            memcpy(data.mutableBytes, src.baseAddress, byteCount)
        }
        return try ORTValue(tensorData: data, elementType: .float, shape: shape)
    }
}
